# Testing FastNim

Source of truth: `src/fastnim/testing.nim`, `tests/`.

## TestClient (preferred)

`TestClient` drives the app in-process — no port, no server, no event loop.

```nim
import std/[json, tables, unittest]

import fastnim
import fastnim/testing

suite "items":
  test "reads root":
    let client = initTestClient(api)
    let response = client.get("/")
    check response.status == 200
    check response.json() == %*{"msg": "Hello World"}
```

Client verbs mirror HTTP: `get`, `post`, `put`, `patch`, `delete`, `query`, plus the generic
`request(method, target, headers, body)`.

- `target` may include a query string: `client.get("/items/42?page=3")`.
- `post`/`put`/`patch` take a raw body string: `client.post("/items", $ %*{"id": 7})`.
- `headers` is a `Headers` table (`initTable[string, string]()`).
- `response.json()` parses the body as JSON and raises on invalid JSON.
- `response.status`, `response.body`, `response.headers` are available.

`initFastNim(logs = false)` keeps test output clean.

## Direct handler form

Routes can also take a plain proc:

```nim
api.put("/items/{id}", proc(request: Request): Response {.raises: [].} =
  json(%*{"updated": request.pathParam("id")}))
```

## Async tests over a real socket

When the transport itself must be exercised, start the server and use `waitFor`:

```nim
import chronos

proc asyncTest() {.async.} =
  let server = app.serve(port = 8080)
  let response = await client.get("http://127.0.0.1:8080/items")
  check response.status == 200

waitFor asyncTest()
```

`waitFor` blocks the test thread until the Chronos loop finishes.

## Conventions

- Files live in `tests/` and must start with `test_` or `t_` for Nimble discovery
  (existing files use the `t` prefix: `ttestclient.nim`, `trouter.nim`, `tvalidation.nim`).
- Use `std/unittest` with `suite`/`test`/`check`.
- Every new route feature, macro, path param extractor, or OpenAPI rule needs both a success
  case and an invalid-input case (`400` / `422`).
- `tests/config.nims` sets `--path:../src` and `--outdir:../bin`.
- `tests/compile_fail/` holds expected compile-error fixtures for macro validation.

## Commands

```sh
nimble test                              # whole suite
nim c -r tests/test_router.nim           # single file, fast loop
nim c -r --path:src examples/typed_post.nim  # run an example
```

`nimble test` runs against the minimum supported Nim version (2.2.12+). Compile-time macro
tests use `nim c --errorMax:0` style fixtures — check `tests/compile_fail/` for the pattern.
