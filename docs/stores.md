# Session and rate-limit stores

FastNim's session and rate-limit plugins use async store handles. Their default
implementations are process-local tables intended for development and
single-instance deployments:

```nim
let sessions = newSessionStore()
let limits = newRateLimitStore()
```

All public store operations return Chronos `Future`s. A custom driver must use a
Chronos-compatible, non-blocking client; do not call a synchronous Redis or SQL
client from these callbacks.

## Session driver contract

Construct a `SessionStore` from `SessionLoad`, `SessionSave`, and
`SessionDelete` callbacks. `save` receives a positive TTL in seconds and must
persist the record and expiry together; FastNim translates a negative TTL into
an immediate delete. `load` returns `nil` for missing or expired records.
`delete` is idempotent. All three operations must tolerate concurrent requests
from different application instances.

```nim
let load: SessionLoad = proc(id: string): Future[SessionData] {.
    async: (raises: [CatchableError])
.} =
  # Await a Chronos-compatible Redis GET and decode the record.
  # Return nil when the key does not exist.
  return await redisLoadSession("fastnim:session:" & id)

let save: SessionSave = proc(
    id: string, data: SessionData, ttlSeconds: int
): Future[void] {.async: (raises: [CatchableError]).} =
  # One Redis SET with EX atomically stores the value and its TTL.
  await redisSetSession("fastnim:session:" & id, data, ttlSeconds)

let delete: SessionDelete = proc(id: string): Future[void] {.
    async: (raises: [CatchableError])
.} =
  await redisDelete("fastnim:session:" & id)

let sessions = newSessionStore(load, save, delete)
```

The placeholder Redis procedures above deliberately leave client selection and
serialization to the application. A database implementation should store an
indexed `expires_at` value in the same transaction as the session data, filter
expired rows during load, and run periodic cleanup separately.

## Rate-limit driver contract

`RateLimitIncrement` is one atomic operation. It increments a fixed-window key,
sets expiry only when opening a new window, and returns the post-increment count
plus the absolute Unix reset time. A Redis driver can implement this with a Lua
script or a transactional equivalent of `INCR` followed by `EXPIRE` only when
the returned count is one. Do not issue an unconditional `EXPIRE`, because that
turns a fixed window into a sliding window; do not split the operation without
a transaction/script, because concurrent application instances can lose the
TTL.

```nim
let limits = newRateLimitStore(
  proc(key: string, windowSeconds: int): Future[RateLimitResult] {.
      async: (raises: [CatchableError])
  .} =
    # The server-side script performs INCR + first-write expiry atomically and
    # returns both the count and the key's absolute expiry time.
    return await redisFixedWindow("fastnim:limit:" & key, windowSeconds)
)

let options = initRateLimitOptions(
  limit = 100, windowSeconds = 60, store = limits
)
app.installPlugin(rateLimitPlugin(options))
```

A SQL driver needs the same guarantee: use a transaction and row-level locking,
or one database-native upsert expression, to reset expired windows and increment
the counter without lost updates.

## Session security checklist

- Keep `HttpOnly` enabled. Set `secure = true` for HTTPS production traffic and
  choose `SameSite=Strict` or `Lax` according to the login flow. Restrict
  `Path`, and avoid a broad `Domain` attribute unless subdomain sharing is
  required.
- Match the cookie `Max-Age` to the backend TTL. Treat backend expiry as
  authoritative; a cookie can outlive a deleted or expired server record.
- Rotate the session id after login and privilege changes. `loginSession`
  always creates a fresh 256-bit OS-random id. Delete the old id explicitly if
  upgrading an existing session, and delete the active id on logout.
- Opaque FastNim session ids do not require a signing key. If a driver encrypts
  records or replaces ids with signed tokens, inject its key provider through
  the load/save callbacks, keep keys outside source control, version ciphertext
  with a key id, accept the current and previous keys during rotation, and
  re-encrypt or invalidate old records on a bounded schedule.
- Namespace keys by application/environment, protect Redis or database
  credentials with the deployment secret manager, use TLS to the store, and
  grant only the commands/tables required by the driver.

