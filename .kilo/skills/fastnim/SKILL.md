---
name: "fastnim"
description: "Use when writing, reviewing, or debugging FastNim (Nim web framework) code: routes, handlers, path/query/body params, middleware, dependency injection, OpenAPI, static files, plugins, WebSocket/SSE/gRPC, or FastNim tests. Also use when the task mentions FastNim, initFastNim, or the fastnim package."
metadata:
  short-description: "FastNim framework: routing, params, middleware, plugins, OpenAPI, testing."
---

# FastNim

Async HTTP framework for Nim built on Chronos. Import the whole public surface with
`import fastnim`; `src/fastnim.nim` re-exports context, server, router, params, middleware,
OpenAPI, static, plugins, testing, and websocket modules.

## Non-negotiable rules

- **Chronos only.** `import chronos`; never `std/asyncdispatch` or `std/asynclines`. It breaks the event loop.
- **No blocking I/O** in handlers or framework internals. Use `await sleepAsync(...)`, not `os.sleep`.
- **Async signatures** use `Future[T]`; annotate with `{.async.}` or `{.async: (raises: [...]).}`.
- **Errors**: raise `ApiErrorException` subclasses (`newBadRequestError`, `newNotFoundError`,
  `newUnprocessableEntityError`, ...) or return `badRequest`/`notFound` helpers. Uncaught exceptions
  become a sanitized JSON `500`.
- **Style**: 2-space indent, camelCase procs, PascalCase types, lowercase module files. Export public
  symbols with `*` and document them with `##` doc comments stating where each parameter comes from.

## Two route styles

**Untyped (block)** — manual extraction, JSON or `(status, json)` tuple return:

```nim
app.get("/items/{itemId}"):
  let itemId = request.pathParam("itemId")
  let page = request.queryParam("page", "1")
  (ok, %* {"itemId": itemId, "page": page})
```

**Typed (inline OpenAPI)** — models drive parsing, validation, and schema generation:

```nim
app.post(
  "/users",
  body = CreateUser,
  responses = @[(201, User), (400, ErrorResponse)],
  tags = @["users"],
  summary = "Create a user",
):
  if body.name.len == 0:
    badRequest ErrorResponse(detail: "name is required")
  created user
```

Handlers: `get post put patch delete query` (macros on `Application` and `Router`), plus
`websocket` and `sse`. Path params: `{name}` or `{name:type}` segments; a param must occupy a
whole segment.

## Request API

- `request.pathParam("id")`, `request.pathParams["id"]`, `request.queryParam("q", "default")`,
  `request.header("authorization")`, `request.queryParamValues("tag")`
- `parseJsonBody[T](request, value)`, `parseFormBody[T](request, value)` (`params/extract.nim`)
- `validate[T](request, Model)` / `parseAndValidateBody` (`params/validate.nim`)

## Responses

- JSON: `json(model)`, `text(body)`, `html(body)`, `noContent void`
- Status helpers used in typed routes: `ok`, `created`, `badRequest`, `conflict`,
  `unprocessableEntity`, `notFound`, `noContent` — each takes a model and produces
  `responses = @[(status, Model)]` metadata.
- `response(status, model)`, `apiErrorResponse(...)`.

## App & server

```nim
let app = initFastNim()
let server = app.serve(port = 8000)
waitFor server.join()
```

`serve(address = "127.0.0.1", port: uint16 = 8000, maxRequestBodySize = 0)`. Limits come from
`requestLimits` (body size, header count/size, handler timeout, concurrency); violations return
`408`/`413`/`431`/`503`.

## Gotchas

- **`ApiError` is a framework type** (`fastnim/context/http.nim`). Defining a model named
  `ApiError` shadows it and triggers an `IgnoredSymbolInjection` warning — name user models
  `ErrorResponse` or `ErrorBody` instead.
- **`ctx.get[T]("name")` does not compile** — Nim parses `ctx.get` as a field selector.
  In a route use `ctx.get("name")` (after `app.dependencies`); elsewhere use
  `ctx.get("name", Type)` or `get[Type](ctx, "name")`.
- Route paths must start with `/`, and a `{param}` must occupy a complete path segment.
- Typed routes require `responses = @[(status, Model)]`; a missing one is a compile error.
- `app.installPlugin` must run before `app.serve`/`app.load`, and plugin names are unique.
- `app.serve` calls `app.load()` itself — do not call it twice.
- Never shadow the framework's `request`, `body`, `queryParams`, `websocket`, `send`, or `next`
  bindings inside a handler.

## Reference map

Read the reference that matches the task; do not read all of them.

- [Routing, params, typed models](references/routing.md) — route macros, extraction, validation, OpenAPI metadata.
- [Middleware, DI, lifecycle](references/middleware.md) — middleware DSL, phases, `dependencies`, context, limits.
- [Testing](references/testing.md) — `TestClient`, in-process requests, test conventions.
- [Plugins and static files](references/plugins.md) — plugin install, ratelimit/openapi/auth/inertia/s3, `serveStatic`.
- [WebSocket, SSE, gRPC](references/streaming.md) — streaming routes and their separate lifecycles.

## Build & test

- `nimble build` — compile check.
- `nimble test` — full suite (min Nim 2.2.12+).
- `nim c -r tests/trouter.nim` — single test file.
- `nim c -r --path:src examples/basic.nim` — run an example.
- `nimble docs` — HTML API reference.
- `fastnim init --template:api` — scaffold a project (see `src/fastnim/cli.nim`, `src/fastnim/scaffolder/`).

## Where things live

| Area | Path |
| --- | --- |
| Server adapter, limits | `src/fastnim/core/` |
| Routing, macros, dispatch | `src/fastnim/routing/router.nim` |
| Request/Response types | `src/fastnim/context/http.nim` |
| App state, lifecycle | `src/fastnim/context/state.nim` |
| Param extraction, validation | `src/fastnim/params/` |
| Middleware | `src/fastnim/middleware/` |
| OpenAPI | `src/fastnim/openapi/spec.nim` |
| Static / embedded assets | `src/fastnim/static/` |
| Plugins | `src/fastnim/plugins/` |
| Tests | `tests/` (`t*.nim`, `test_*.nim`) |
