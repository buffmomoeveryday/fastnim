# Repository Guidelines & AI Agent Context (`AGENTS.md`)

## Project Overview & Architecture

**FastNim** is a high-performance, asynchronous web framework for Nim inspired by Python’s FastAPI. It builds directly on top of the **Chronos** asynchronous engine to deliver type-driven routing, automatic request/response body serialization, dependency injection, and automatic OpenAPI schema generation.

### Key Architectural Concepts
- **Chronos Engine**: All I/O operations are strictly asynchronous using `chronos`. Never import or mix `std/asyncdispatch`.
- **Compile-Time Macro Processing**: Route handlers use Nim macros to inspect parameter types at compile-time, setting up automatic body parsing (`std/json` or `jsony`), path parameter extraction, and validation.
- **Request Context & Transport**: HTTP handling leverages Chronos transport streams, exposing clean `Request` and `Response` interfaces without sacrificing low-level network performance.

---

## Project Structure & Module Organization

Keep public library exports in `src/` and organize modules by distinct framework responsibilities:

```text
fastnim/
├── fastnim.nimble          # Package manifest and dependency specs
├── src/
│   ├── fastnim.nim         # Primary entrypoint (`import fastnim`) exporting user-facing APIs
│   └── fastnim/
│       ├── core/           # Chronos HTTP server setup, connection loop, and lifecycle
│       │   └── server.nim  # Chronos adapter: `serve`, `stop`, `join`, file streaming
│       ├── routing/        # Router macro implementation (`@get`, `@post`, route matching tree)
│       │   └── router.nim  # Application, route registration, dispatch, middleware pipeline
│       ├── context/        # Request, Response, and Context types
│       │   ├── http.nim    # HTTP wire types and response constructors
│       │   └── state.nim   # Application-scoped `Context` values and lifecycle hooks
│       ├── params/         # Query/Path extraction, JSON deserialization, and type checking
│       │   └── extract.nim # `pathParam`, `queryParam`, `header`, `parseJsonBody/FormBody`
│       ├── openapi/        # OpenAPI/Swagger spec generation from compile-time type metadata
│       │   └── spec.nim    # Document, schema, and Swagger UI helpers
│       ├── middleware/     # Dependency injection and middleware pipeline mechanics
│       │   └── builtin.nim # CORS, request-ID, and response-time middleware
│       ├── static/         # Static file serving (`serveStatic`, embedded assets)
│       │   ├── files.nim   # Runtime mounts: disk, single-file, embedded, Range/cache/HEAD
│       │   └── embed.nim   # Compile-time embedding macros and macro utilities
│       ├── plugins/        # Optional extensions (ratelimit, inertia, openapi plugin)
│       ├── plugin.nim      # Public plugin installation API (`initPlugin`, `install`)
│       ├── plugins.nim     # Plugin namespace re-exporting `plugins/*`
│       ├── websocket.nim   # WebSocket connection helpers
│       ├── logging.nim     # Per-application logging configuration
│       ├── cli.nim         # Developer CLI entrypoint
│       └── scaffolder/     # Project scaffolding templates
├── tests/                  # Test suite (`t*.nim`, discovered automatically by Nimble)
│   └── config.nims         # Test runner compiler configurations
└── examples/               # Standalone runnable user applications (e.g., `basic.nim`)

```

* **Module Rule**: Keep submodules small and targeted. Export public API symbols using `*`. Keep internal helpers private within their respective submodules.

---

## Build, Test, and Development Commands

* `nimble build`: Validates compiler compliance and builds package dependencies.
* `nimble test`: Executes the entire test suite against the minimum supported Nim version (2.2.12+).
* `nim c -r tests/test_router.nim`: Compiles and runs a single test file immediately for fast feedback loops during macro or engine development.
* `nim c -r examples/quickstart.nim`: Spins up an example FastNim HTTP server for manual testing and endpoint verification.

---

## Asynchronous & Chronos Guidelines

1. **Chronos Exclusivity**: Use `import chronos` exclusively. Do **not** import `std/asyncdispatch`, `std/asynclines`, or stdlib async modules to prevent runtime event loop conflicts.
2. **Non-Blocking I/O**: Never perform blocking I/O (such as `std/os.sleep` or blocking socket operations) inside handlers or framework internals. Use `await sleepAsync(...)` and Chronos-native primitives.
3. **Async Pragmas & Signature**: Annotate async procedures with `{.async.}` or explicit Chronos pragmas. Ensure return types strictly use `Future[T]`.
4. **Error Handling**: Catch exceptions within handlers or propagate them cleanly through the FastNim middleware stack using custom `CatchableError` types. Uncaught exceptions must be transformed into a standard JSON 500 internal server error.

---

## Coding Style & Naming Conventions

* **Indentation**: Standard 2-space indentation.
* **Naming**:
* `camelCase` for procedures, variables, and field names.
* `PascalCase` for types, objects, and concepts (`Request`, `FastNimApp`, `RouteHandler`).
* `lowercase` for module filenames.


* **Documentation**: Document every exported procedure, type, and macro with `##` doc comments. Explicitly state if a parameter is extracted from path, query, or request body.
* **Macro Hygiene**: Place heavy macro logic and AST manipulations in dedicated macro utility files. Provide clear, human-readable compile-time error messages via `macros.error` when a handler signature violates FastNim requirements.

---

## Testing Guidelines

* **Framework**: Tests use Nim's standard `unittest` module.
* **Naming**: Test files must start with `test_` or `t_` inside `tests/` for automated Nimble discovery.
* **Testing Async Code with Chronos**: Use `waitFor` in test cases to block the test thread until the Chronos event loop completes the HTTP call:

```nim
import unittest, chronos, fastnim

test "Parses JSON payload in POST endpoint":
  proc asyncTest() {.async.} =
    # Setup test app & client request
    let res = await client.post("[http://127.0.0.1:8080/items](http://127.0.0.1:8080/items)", body = """{"name":"Widget"}""")
    check res.status == 200
    check "Widget" in res.body

  waitFor asyncTest()

```

* **Coverage Expectation**: Any new route feature, macro addition, path param extractor, or OpenAPI generation rule must include matching tests for both successful cases and invalid inputs (e.g., 400 Bad Request / 422 Unprocessable Entity).

---

## Commit & PR Guidelines

* **Commit Style**: Use short, imperative commit messages (e.g., `Add async path parameter extractor`, `Fix Chronos transport buffer overflow`).
* **Pull Requests**:
* Describe the architectural rationale for any changes to macros or Chronos transport handling.
* State the exact test command executed (e.g., `nimble test`) and the result.
* Include an update to `examples/` if adding a major user-facing feature (like a new HTTP decorator or dependency injection rule).


