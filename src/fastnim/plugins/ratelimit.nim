## In-memory rate limit plugin for FastNim applications.

## Reference in-memory fixed-window rate limiting plugin.

import std/[json, locks, math, strutils, tables, times]

import fastnim/[context/http, context/state, params/extract, plugin, routing/router]

type
  RateLimitKey* = proc(request: Request): string {.closure.}
    ## Derives a bucket key for one request.
  RateLimitOptions* = object ## Fixed-window rate limit configuration.
    limit*: int ## Allowed requests per window for one bucket key.
    windowSeconds*: int ## Window length in seconds.
    key*: RateLimitKey ## Bucket key derivation; defaults to ``x-forwarded-for``.

  RateLimitBucket = object
    count: int
    startedAt: float

  RateLimitState = ref object of RootObj
    lock: Lock
    buckets: Table[string, RateLimitBucket]

proc initRateLimitOptions*(
    limit = 100, windowSeconds = 60, key: RateLimitKey = nil
): RateLimitOptions =
  ## Creates rate limit settings. Requests without a custom key use
  ## ``x-forwarded-for`` and fall back to a shared anonymous bucket.
  if limit <= 0:
    raise newException(ValueError, "rate limit must be positive")
  if windowSeconds <= 0:
    raise newException(ValueError, "rate limit window must be positive")
  RateLimitOptions(limit: limit, windowSeconds: windowSeconds, key: key)

proc defaultKey(request: Request): string =
  request.header("x-forwarded-for", "anonymous").split(',')[0].strip()

proc newRateLimitState(): RateLimitState =
  new(result)
  initLock(result.lock)
  result.buckets = initTable[string, RateLimitBucket]()

proc rateLimitMiddleware(options: RateLimitOptions, state: RateLimitState): Middleware =
  result = proc(request: Request, next: NextHandler): Response =
    let key =
      if options.key.isNil:
        defaultKey(request)
      else:
        options.key(request)
    let now = epochTime()
    var remaining: int
    var retryAfter = 0
    var blocked = false
    acquire(state.lock)
    try:
      var bucket = state.buckets.getOrDefault(key)
      if now - bucket.startedAt >= float(options.windowSeconds):
        bucket = RateLimitBucket(startedAt: now)
      if bucket.count >= options.limit:
        blocked = true
        retryAfter =
          max(1, ceil(bucket.startedAt + float(options.windowSeconds) - now).int)
      else:
        inc bucket.count
        remaining = options.limit - bucket.count
        state.buckets[key] = bucket
    finally:
      release(state.lock)

    if blocked:
      result = text("Too Many Requests", 429)
      result.setHeader("retry-after", $retryAfter)
      result.setHeader("x-ratelimit-limit", $options.limit)
      result.setHeader("x-ratelimit-remaining", "0")
      return
    result = next(request)
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
  ## Creates an in-memory fixed-window rate-limit plugin.
  let state = newRateLimitState()
  initPlugin(
    name,
    version,
    proc(app: Application) =
      app.pluginContext(name).setContext("state", state)
      app.use(rateLimitMiddleware(options, state), priority = -100)
      app.addOpenApiContributor(contributeRateLimit),
  )
