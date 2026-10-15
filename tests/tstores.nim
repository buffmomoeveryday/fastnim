import std/[assertions, tables]

import chronos

import fastnim
import fastnim/plugins/auth
import fastnim/plugins/ratelimit

block inMemorySessionStoreContract:
  var now = 100.0
  let store = newInMemorySessionStore(
    defaultTtlSeconds = 30,
    clock = proc(): float {.gcsafe, raises: [].} = now,
  )
  let data = SessionData(subject: "ada", createdAt: now, expiresAt: 0)
  waitFor store.saveSession("session-1", data, ttlSeconds = 10)
  let loaded = waitFor store.loadSession("session-1")
  doAssert not loaded.isNil
  doAssert loaded.subject == "ada"
  doAssert loaded.expiresAt == 110.0
  now = 111.0
  doAssert (waitFor store.loadSession("session-1")).isNil
  doAssert waitFor(store.sessionCount()) == 0

  now = 200.0
  waitFor store.saveSession("session-2", data, ttlSeconds = 10)
  waitFor store.deleteSession("session-2")
  doAssert (waitFor store.loadSession("session-2")).isNil

block customSessionStoreIsPluggable:
  type FakeState = ref object
    rows: Table[string, SessionData]
    savedTtl: int

  let state = FakeState(rows: initTable[string, SessionData]())
  let load: SessionLoad = proc(id: string): Future[SessionData] {.
      async: (raises: [CatchableError])
  .} =
    {.cast(gcsafe).}:
      return state.rows.getOrDefault(id)
  let save: SessionSave = proc(
      id: string, data: SessionData, ttlSeconds: int
  ): Future[void] {.async: (raises: [CatchableError]).} =
    {.cast(gcsafe).}:
      state.rows[id] = data
      state.savedTtl = ttlSeconds
  let delete: SessionDelete = proc(id: string): Future[void] {.
      async: (raises: [CatchableError])
  .} =
    {.cast(gcsafe).}:
      state.rows.del(id)

  let store = newSessionStore(load, save, delete, defaultTtlSeconds = 45)
  let id = waitFor store.createSession("grace")
  doAssert state.savedTtl == 45
  doAssert waitFor(store.sessionSubject(id)) == "grace"
  waitFor store.destroySession(id)
  doAssert waitFor(store.sessionSubject(id)) == ""

block inMemoryRateLimitCountingAndReset:
  var now = 100.0
  let store = newInMemoryRateLimitStore(
    clock = proc(): float {.gcsafe, raises: [].} = now
  )
  let first = waitFor store.increment("client-a", 5)
  let second = waitFor store.increment("client-a", 5)
  doAssert first.count == 1
  doAssert second.count == 2
  doAssert first.resetAt == 105.0
  doAssert second.resetAt == first.resetAt
  now = 106.0
  let reset = waitFor store.increment("client-a", 5)
  doAssert reset.count == 1
  doAssert reset.resetAt == 111.0

block customRateLimitStoreIsUsedByPlugin:
  type FakeRateState = ref object
    calls: int
    lastWindow: int

  let state = FakeRateState()
  let increment: RateLimitIncrement = proc(
      key: string, windowSeconds: int
  ): Future[RateLimitResult] {.async: (raises: [CatchableError]).} =
    doAssert key == "shared-client"
    {.cast(gcsafe).}:
      inc state.calls
      state.lastWindow = windowSeconds
      return RateLimitResult(count: state.calls, resetAt: 10_000_000_000.0)

  let store = newRateLimitStore(increment)
  let app = initFastNim(logs = false)
  app.installPlugin(
    rateLimitPlugin(
      initRateLimitOptions(
        limit = 1,
        windowSeconds = 20,
        key = proc(request: Request): string = "shared-client",
        store = store,
      )
    )
  )
  app.get("/"):
    text("ok")
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/")).status == 200
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/")).status == 429
  doAssert state.calls == 2
  doAssert state.lastWindow == 20
