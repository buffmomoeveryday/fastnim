# Middleware, dependency injection, and lifecycle

Source of truth: `src/fastnim/middleware/`, `src/fastnim/context/state.nim`,
`src/fastnim/routing/router.nim`.

## Middleware signature

```nim
type Middleware = proc(request: Request, next: NextHandler): Future[Response]
                 {.async: (raises: [CatchableError]).}
```

`next(request)` invokes the rest of the stack and returns its `Response`. Returning a
`Response` without calling `next` short-circuits the request.

## Two stacks

- **Application middleware** wraps dispatch — it sees the response as the stack unwinds, and
  also runs for OpenAPI paths and 404s.
- **Router middleware** runs only after a route on that router matched.

SSE and WebSocket routes use their own streaming lifecycles and bypass HTTP middleware and the
ordinary handler timeout.

## Registration

```nim
app.addMiddleware(mw)                              # BeforeRouting phase, default priority 0
app.addMiddleware(mw, MiddlewarePhase.AfterRouting)  # after route match
app.middlewares:                                   # declaration-order block
  requestId()
  responseTime()
```

`app.middlewares:` registers each expression as a separate middleware, in order.
Lower `priority` runs first within a phase; ties break by registration order.

## DSL macro

```nim
middleware addResponseHeadersMiddleware:
  var response = await next(request)
  response.setHeader("x-powered-by", "fastnim")
  response
```

The macro rewrites `request`/`next` to the middleware parameters. `await next(request)` is
required for the response to be produced after the inner stack runs.

## Built-ins (`src/fastnim/middleware/builtin.nim`)

| Middleware | Purpose |
| --- | --- |
| `cors(options = initCorsOptions())` | CORS headers and preflight handling |
| `requestId(...)` | Adds a request ID header/value |
| `responseTime(headerName = "x-response-time-us")` | Adds elapsed-time header |

## Error handling

- `app.onError(status, handler)` overrides the framework response for a status code.
- Known `ApiErrorException` types map to their status; unexpected exceptions become a
  sanitized JSON `500` (never leak internals).

## Dependency injection

```nim
type Deps = object
  db: Database
  cache: Cache

app.dependencies(Deps):
  provide db: openDatabase()
  provide cache: newCache()
  cleanup db: db.close()
```

Every field of the schema needs exactly one `provide`; `cleanup` is optional. Values are
stored in the application `Context` during `load`.

**Reading a dependency — two different forms:**

*Inside a route block* (after `app.dependencies(...)`), `ctx.get` is rewritten at compile
time and the type comes from the schema. The name must be a string literal, and the
`app.dependencies` call must come earlier in the file:

```nim
app.get("/items"):
  let db = ctx.get("db")          # type resolved from Deps
```

An unknown name is a compile-time error
(`ctx.get(name) requires app.dependencies(DependencyType) before this route`).

*Outside a route* (lifecycle hooks, plain procs), use the runtime `Context` API:

```nim
proc unloadDatabase(ctx: Context) =
  ctx.get("db", Database)          # typedesc form
  # or: get[Database](ctx, "db")   # UFCS form
```

> `ctx.get[string]("name")` does **not** compile — Nim parses `ctx.get` as a field selector.
> Use `ctx.get("name", Type)` or `get[Type](ctx, "name")` outside routes.

`app.context` returns the application-scoped `Context`; `setContext(ctx, "name", value)`,
`ctx.get("name", Type)`, `ctx.has("name")` are the primitives. `ctx.get` raises `KeyError`
when the name is missing and `ValueError` when the type does not match.

## Lifecycle hooks

```nim
app.onLoad(proc(ctx: Context) {.nimcall.} = ...)
app.onUnload(proc(ctx: Context) {.nimcall.} = ...)
app.load()   # manual trigger; app.serve calls it for you
app.unload()
```

## Limits and configuration

```nim
let limits = initRequestLimits()
limits.maxBodySize = 1_048_576
limits.handlerTimeout = 5.seconds
app.configureRequestLimits(limits)
```

Limits are enforced by the Chronos adapter and the server: oversized bodies → `413`, header
violations → `431`, header/body stalls → `408`, handler timeout or concurrency overflow →
`503`.

## Logging

`initFastNim(logs = true, logHandler = nil, logLevel = lvlInfo)`. Custom `logHandler` receives
level and message. `app.log(level, message)` and `app.logError(message)` are the framework
entry points. See `src/fastnim/logging.nim`.
