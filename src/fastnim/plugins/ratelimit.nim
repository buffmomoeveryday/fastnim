## Async, replaceable fixed-window rate limiting for FastNim applications.

import std/[json, locks, math, strutils, tables, times]

import chronos

import fastnim/[context/http, context/state, params/extract, plugin, routing/router]

type
  RateLimitKey* = proc(request: Request): string {.closure.}
    ## Derives a bucket key for one request.
  RateLimitClock* = proc(): float {.closure, gcsafe, raises: [].}
    ## Clock used by the in-memory store, primarily for deterministic tests.

  RateLimitResult* = object
    ## Result of one atomic fixed-window increment.
    count*: int ## Counter value after incrementing.
    resetAt*: float ## Unix time at which the bucket expires.

  RateLimitIncrement* = proc(
    key: string, windowSeconds: int
  ): Future[RateLimitResult] {.closure, async: (raises: [CatchableError]).}
    ## Async atomic increment-with-expiry backend operation.

  RateLimitStore* = ref object of RootObj
    ## Store interface shared by all rate-limit middleware instances.
    ##
    ## A custom backend must atomically increment the key, set its expiry only
    ## when opening a new window, and return the resulting count and reset time.
    incrementImpl: RateLimitIncrement

  RateLimitOptions* = object ## Fixed-window rate limit configuration.
    limit*: int ## Allowed requests per window for one bucket key.
    windowSeconds*: int ## Window length in seconds.
    key*: RateLimitKey ## Bucket key derivation; defaults to ``x-forwarded-for``.
    store*: RateLimitStore ## Shared backend; nil selects the in-memory default.

  RateLimitBucket = object
    count: int
    resetAt: float

  InMemoryRateLimitState = ref object
    lock: Lock
    buckets: Table[string, RateLimitBucket]
    clock: RateLimitClock

proc newRateLimitStore*(increment: RateLimitIncrement): RateLimitStore =
  ## Creates a rate-limit store backed by an async atomic increment callback.
  if increment.isNil:
    raise newException(ValueError, "rate limit increment callback cannot be nil")
  RateLimitStore(incrementImpl: increment)

proc newInMemoryRateLimitStore*(clock: RateLimitClock = nil): RateLimitStore =
  ## Creates a process-local rate-limit store for development or one instance.
  var selectedClock: RateLimitClock = clock
  if selectedClock.isNil:
    selectedClock = proc(): float {.gcsafe, raises: [].} = epochTime()
  let state = InMemoryRateLimitState(
    buckets: initTable[string, RateLimitBucket](),
    clock: selectedClock,
  )
  initLock(state.lock)
  let increment: RateLimitIncrement = proc(
      key: string, windowSeconds: int
  ): Future[RateLimitResult] {.async: (raises: [CatchableError]).} =
    let now = state.clock()
    acquire(state.lock)
    try:
      var bucket = state.buckets.getOrDefault(key)
      if bucket.resetAt <= now:
        bucket = RateLimitBucket(resetAt: now + float(windowSeconds))
      inc bucket.count
      state.buckets[key] = bucket
      return RateLimitResult(count: bucket.count, resetAt: bucket.resetAt)
    finally:
      release(state.lock)
  newRateLimitStore(increment)

proc newRateLimitStore*(): RateLimitStore =
  ## Creates the default process-local in-memory rate-limit store.
  newInMemoryRateLimitStore()

proc increment*(
    store: RateLimitStore, key: string, windowSeconds: int
): Future[RateLimitResult] {.async: (raises: [CatchableError, ValueError]).} =
  ## Atomically increments a bucket and applies expiry to a new window.
  if key.len == 0:
    raise newException(ValueError, "rate limit key cannot be empty")
  if windowSeconds <= 0:
    raise newException(ValueError, "rate limit window must be positive")
  return await store.incrementImpl(key, windowSeconds)

proc initRateLimitOptions*(
    limit = 100,
    windowSeconds = 60,
    key: RateLimitKey = nil,
    store: RateLimitStore = nil,
): RateLimitOptions =
  ## Creates rate limit settings. A nil store uses an in-memory backend.
  if limit <= 0:
    raise newException(ValueError, "rate limit must be positive")
  if windowSeconds <= 0:
    raise newException(ValueError, "rate limit window must be positive")
  RateLimitOptions(
    limit: limit, windowSeconds: windowSeconds, key: key, store: store
  )

proc defaultKey(request: Request): string =
  request.header("x-forwarded-for", "anonymous").split(',')[0].strip()

proc rateLimitMiddleware(
    options: RateLimitOptions, store: RateLimitStore
): Middleware =
  result = proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    let key =
      if options.key.isNil:
        defaultKey(request)
      else:
        {.cast(gcsafe), cast(raises: [CatchableError]).}:
          options.key(request)
    let usage = await store.increment(key, options.windowSeconds)
    let remaining = max(0, options.limit - usage.count)
    if usage.count > options.limit:
      result = text(statusTooManyRequests, "Too Many Requests")
      let retryAfter = max(1, ceil(usage.resetAt - epochTime()).int)
      result.setHeader("retry-after", $retryAfter)
      result.setHeader("x-ratelimit-limit", $options.limit)
      result.setHeader("x-ratelimit-remaining", "0")
      return
    result = await next(request)
    result.setHeader("x-ratelimit-limit", $options.limit)
    result.setHeader("x-ratelimit-remaining", $remaining)

proc contributeRateLimit(document: var JsonNode) =
  if "paths" notin document:
    return
  for _, pathItem in document["paths"]:
    for _, operation in pathItem:
      if operation.kind == JObject and "responses" in operation:
        operation["responses"]["429"] = %*{
          "description": "Too Many Requests",
          "headers": {
            "Retry-After": {"schema": {"type": "integer"}},
            "X-RateLimit-Limit": {"schema": {"type": "integer"}},
            "X-RateLimit-Remaining": {"schema": {"type": "integer"}},
          },
        }

proc rateLimitPlugin*(
    options = initRateLimitOptions(), name = "ratelimit", version = "0.1.0"
): Plugin =
  ## Creates a fixed-window rate-limit plugin using the configured store.
  let store =
    if options.store.isNil:
      newInMemoryRateLimitStore()
    else:
      options.store
  initPlugin(
    name,
    version,
    proc(app: Application) =
      app.pluginContext(name).setContext("store", store)
      app.use(rateLimitMiddleware(options, store), priority = -100)
      app.addOpenApiContributor(contributeRateLimit),
  )
