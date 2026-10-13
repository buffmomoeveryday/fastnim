## Async, replaceable cookie session stores for the FastNim auth plugin.
##
## ``newSessionStore()`` uses a process-local in-memory backend. Distributed
## deployments can pass async load/save/delete callbacks to the other
## ``newSessionStore`` overload; callbacks must use a non-blocking Chronos-
## compatible database client.

import std/[locks, strutils, sysrand, tables, times]

import chronos

import fastnim/[context/http, params/extract]

import fastnim/plugins/auth/schemes

type
  SessionData* = ref object of RootObj ## Server-side record for one login.
    subject*: string ## Who owns the session.
    createdAt*: float ## Unix time the session was created.
    expiresAt*: float ## Unix time the session stops being valid.

  SessionLoad* =
    proc(id: string): Future[SessionData] {.closure, async: (raises: [CatchableError]).}
    ## Async backend operation that returns nil for missing or expired ids.
  SessionSave* = proc(id: string, data: SessionData, ttlSeconds: int): Future[void] {.
    closure, async: (raises: [CatchableError])
  .} ## Async backend operation that saves data with the supplied TTL.
  SessionDelete* =
    proc(id: string): Future[void] {.closure, async: (raises: [CatchableError]).}
    ## Async backend operation that deletes an id if it exists.
  SessionClock* = proc(): float {.closure, gcsafe, raises: [].}
    ## Clock used by the in-memory store, primarily for deterministic tests.

  SessionStore* = ref object of RootObj
    ## Async session-store interface used by authentication middleware.
    ##
    ## Custom callbacks must be safe to call concurrently from multiple
    ## requests. The load callback must treat expired records as missing.
    defaultTtlSeconds*: int ## Lifetime used when no per-session TTL is given.
    loadImpl: SessionLoad
    saveImpl: SessionSave
    deleteImpl: SessionDelete
    countImpl: proc(): Future[int] {.closure, async: (raises: [CatchableError]).}
    sweepImpl: proc(): Future[void] {.closure, async: (raises: [CatchableError]).}

  InMemorySessionState = ref object
    lock: Lock
    sessions: Table[string, SessionData]
    clock: SessionClock

proc validateTtl(defaultTtlSeconds: int) =
  if defaultTtlSeconds <= 0:
    raise newException(ValueError, "session ttl must be positive")

proc newSessionStore*(
    load: SessionLoad,
    save: SessionSave,
    delete: SessionDelete,
    defaultTtlSeconds = 86400,
): SessionStore =
  ## Creates a session store backed by async driver callbacks.
  ##
  ## ``save`` must apply ``ttlSeconds`` in the database, and ``load`` must not
  ## return expired data. None of the callbacks may perform blocking I/O.
  validateTtl(defaultTtlSeconds)
  if load.isNil or save.isNil or delete.isNil:
    raise newException(ValueError, "session store callbacks cannot be nil")
  SessionStore(
    defaultTtlSeconds: defaultTtlSeconds,
    loadImpl: load,
    saveImpl: save,
    deleteImpl: delete,
  )

proc newInMemorySessionStore*(
    defaultTtlSeconds = 86400, clock: SessionClock = nil
): SessionStore =
  ## Creates a process-local session store for development or one instance.
  validateTtl(defaultTtlSeconds)
  var selectedClock: SessionClock = clock
  if selectedClock.isNil:
    selectedClock = proc(): float {.gcsafe, raises: [].} =
      epochTime()
  let state = InMemorySessionState(
    sessions: initTable[string, SessionData](), clock: selectedClock
  )
  initLock(state.lock)

  let load: SessionLoad = proc(
      id: string
  ): Future[SessionData] {.async: (raises: [CatchableError]).} =
    if id.len == 0:
      return nil
    acquire(state.lock)
    try:
      let data = state.sessions.getOrDefault(id)
      if data.isNil:
        return nil
      if state.clock() >= data.expiresAt:
        state.sessions.del(id)
        return nil
      return SessionData(
        subject: data.subject, createdAt: data.createdAt, expiresAt: data.expiresAt
      )
    finally:
      release(state.lock)

  let save: SessionSave = proc(
      id: string, data: SessionData, ttlSeconds: int
  ): Future[void] {.async: (raises: [CatchableError]).} =
    acquire(state.lock)
    try:
      state.sessions[id] = SessionData(
        subject: data.subject,
        createdAt: data.createdAt,
        expiresAt: state.clock() + float(ttlSeconds),
      )
    finally:
      release(state.lock)

  let delete: SessionDelete = proc(
      id: string
  ): Future[void] {.async: (raises: [CatchableError]).} =
    acquire(state.lock)
    try:
      state.sessions.del(id)
    finally:
      release(state.lock)

  result = newSessionStore(load, save, delete, defaultTtlSeconds)
  result.countImpl = proc(): Future[int] {.async: (raises: [CatchableError]).} =
    acquire(state.lock)
    try:
      return state.sessions.len
    finally:
      release(state.lock)
  result.sweepImpl = proc(): Future[void] {.async: (raises: [CatchableError]).} =
    acquire(state.lock)
    try:
      let now = state.clock()
      var expired: seq[string] = @[]
      for id, data in state.sessions:
        if now >= data.expiresAt:
          expired.add(id)
      for id in expired:
        state.sessions.del(id)
    finally:
      release(state.lock)

proc newSessionStore*(defaultTtlSeconds = 86400): SessionStore =
  ## Creates the default process-local in-memory session store.
  newInMemorySessionStore(defaultTtlSeconds)

proc loadSession*(
    store: SessionStore, id: string
): Future[SessionData] {.async: (raises: [CatchableError]).} =
  ## Loads an unexpired session, or nil when the id is absent or expired.
  if id.len == 0:
    return nil
  return await store.loadImpl(id)

proc saveSession*(
    store: SessionStore, id: string, data: SessionData, ttlSeconds = 0
): Future[void] {.async: (raises: [CatchableError, ValueError]).} =
  ## Saves a session and applies its expiry in the backend.
  ##
  ## A zero TTL uses ``defaultTtlSeconds``. Negative TTLs are allowed for
  ## immediate expiry, matching cookie ``Max-Age`` semantics.
  if id.len == 0 or data.isNil or data.subject.len == 0:
    raise newException(ValueError, "session id, data, and subject cannot be empty")
  let ttl = if ttlSeconds == 0: store.defaultTtlSeconds else: ttlSeconds
  if ttl < 0:
    await store.deleteImpl(id)
    return
  await store.saveImpl(id, data, ttl)

proc deleteSession*(
    store: SessionStore, id: string
): Future[void] {.async: (raises: [CatchableError]).} =
  ## Deletes a session if it exists.
  if id.len > 0:
    await store.deleteImpl(id)

proc newSessionId*(): string {.raises: [ValueError].} =
  ## Generates an unguessable 32-byte session id as unpadded base64url.
  var raw: seq[byte]
  try:
    raw = urandom(32)
  except CatchableError:
    raise newException(ValueError, "could not read random session id")
  if raw.len != 32:
    raise newException(ValueError, "could not read random session id")
  var text = newString(32)
  copyMem(addr text[0], addr raw[0], 32)
  base64UrlEncode(text)

proc createSession*(
    store: SessionStore, subject: string, ttlSeconds = 0
): Future[string] {.async: (raises: [CatchableError, ValueError]).} =
  ## Creates a session for ``subject`` and returns its fresh random id.
  if subject.len == 0:
    raise newException(ValueError, "session subject cannot be empty")
  let ttl = if ttlSeconds == 0: store.defaultTtlSeconds else: ttlSeconds
  let id = newSessionId()
  let now = epochTime()
  let data = SessionData(subject: subject, createdAt: now, expiresAt: now + float(ttl))
  await store.saveSession(id, data, ttl)
  return id

proc sessionSubject*(
    store: SessionStore, id: string
): Future[string] {.async: (raises: [CatchableError]).} =
  ## Returns the owner of an unexpired session, or "" when absent.
  let data = await store.loadSession(id)
  if data.isNil:
    return ""
  return data.subject

proc destroySession*(
    store: SessionStore, id: string
): Future[void] {.async: (raises: [CatchableError]).} =
  ## Deletes ``id`` if present. Logging out must always call this.
  await store.deleteSession(id)

proc sweepExpiredSessions*(
    store: SessionStore
): Future[void] {.async: (raises: [CatchableError]).} =
  ## Drops expired entries from the in-memory store.
  ##
  ## External stores should enforce TTL themselves, so this is a no-op for a
  ## custom driver.
  if not store.sweepImpl.isNil:
    await store.sweepImpl()

proc sessionCount*(
    store: SessionStore
): Future[int] {.async: (raises: [CatchableError]).} =
  ## Returns the in-memory entry count, or -1 for a custom driver.
  if store.countImpl.isNil:
    return -1
  return await store.countImpl()

proc parseCookies*(request: Request): Table[string, string] {.raises: [].} =
  ## Splits the ``Cookie`` header into name/value pairs.
  result = initTable[string, string]()
  try:
    for chunk in request.header("cookie").split(';'):
      let pair = chunk.strip()
      if pair.len > 0:
        let separator = pair.find('=')
        if separator > 0:
          var value = pair[separator + 1 ..^ 1].strip()
          if value.len >= 2 and value[0] == '"' and value[^1] == '"':
            value = value[1 ..^ 2]
          result[pair[0 ..< separator].strip()] = value
  except CatchableError:
    discard

proc sessionIdCookie*(
    request: Request, name = "session_id"
): string {.inline, raises: [].} =
  ## Returns the session id from the ``name`` cookie, or "" when absent.
  parseCookies(request).getOrDefault(name, "")

proc setSessionCookie*(
    response: var Response,
    name, id: string,
    maxAge = -1,
    path = "/",
    httpOnly = true,
    sameSite = "Lax",
    secure = false,
) {.raises: [ValueError].} =
  ## Sets a session cookie with explicit browser security controls.
  if name.len == 0 or id.len == 0:
    raise newException(ValueError, "session cookie name and id cannot be empty")
  var cookie = name & "=" & id & "; Path=" & path
  if maxAge >= 0:
    cookie.add("; Max-Age=" & $maxAge)
  if httpOnly:
    cookie.add("; HttpOnly")
  if sameSite.len > 0:
    cookie.add("; SameSite=" & sameSite)
  if secure:
    cookie.add("; Secure")
  response.setHeader("set-cookie", cookie)

proc clearSessionCookie*(
    response: var Response, name: string, path = "/"
) {.raises: [ValueError].} =
  ## Expires the session cookie immediately.
  if name.len == 0:
    raise newException(ValueError, "session cookie name cannot be empty")
  response.setHeader(
    "set-cookie", name & "=; Path=" & path & "; Max-Age=0; HttpOnly; SameSite=Lax"
  )

proc saveLogin(
    store: SessionStore, id: string, data: SessionData, ttl: int
): Future[string] {.async: (raises: [CatchableError, ValueError]).} =
  await store.saveSession(id, data, ttl)
  return id

proc loginSession*(
    store: SessionStore,
    response: var Response,
    subject: string,
    ttlSeconds = 0,
    cookieName = "session_id",
    secure = false,
): Future[string].Raising([CatchableError, ValueError]) =
  ## Creates a fresh session and sets its cookie, returning the new id.
  if subject.len == 0:
    raise newException(ValueError, "session subject cannot be empty")
  let ttl = if ttlSeconds == 0: store.defaultTtlSeconds else: ttlSeconds
  let id = newSessionId()
  let maxAge = if ttlSeconds > 0: ttlSeconds else: store.defaultTtlSeconds
  setSessionCookie(response, cookieName, id, maxAge = maxAge, secure = secure)
  let now = epochTime()
  let data = SessionData(subject: subject, createdAt: now, expiresAt: now + float(ttl))
  saveLogin(store, id, data, ttl)

proc finishLogout(
    store: SessionStore, id: string
): Future[void] {.async: (raises: [CatchableError, ValueError]).} =
  await destroySession(store, id)

proc logoutSession*(
    store: SessionStore,
    request: Request,
    response: var Response,
    cookieName = "session_id",
): Future[void].Raising([CatchableError, ValueError]) =
  ## Destroys the request's session, if any, and clears its cookie.
  let id = sessionIdCookie(request, cookieName)
  clearSessionCookie(response, cookieName)
  finishLogout(store, id)
