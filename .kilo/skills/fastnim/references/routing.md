# Routing, params, and typed models

Source of truth: `src/fastnim/routing/router.nim`, `src/fastnim/params/extract.nim`,
`src/fastnim/params/validate.nim`.

## Route registration

| Form | Signature |
| --- | --- |
| Block | `app.get(path): <stmts>` |
| Typed GET | `app.get(path, responses = @[(200, Model)], queryParams = Q, ...): <stmts>` |
| Typed others | `app.post(path, body = Model, responses = @[(201, User)], ...): <stmts>` |
| Programmatic | `app.addRoute(HttpMethod.Get, "/x", handler, openApi)` |

Supported methods: `GET POST PUT PATCH DELETE QUERY` plus `websocket` and `sse`.
Macros exist for both `Application` and `Router` (`initRouter(prefix, tags)`, mounted with
`app.addRouter(router)`).

Path parameters: `{name}` or `{name:type}`. A `{...}` must occupy a complete segment
(`/items/{itemId}` is valid, `/items/{id}.json` is not). Duplicate names are rejected at
registration time.

## Untyped handler returns

A block handler may end with:

- a `JsonNode` → `200` with JSON body
- a `(status, json)` tuple → that status. Nim requires parentheses around the pair.
- a `Response` value → used as-is
- `return (notFound, %*{"detail": "item not found"})` for early exit

Status aliases accepted in tuples: `ok`, `created`, `notFound` (and the other helpers).

## Typed route options

| Option | Applies to | Meaning |
| --- | --- | --- |
| `responses` | all | `@[(status, Model)]` — drives OpenAPI schemas and response typing |
| `body` | post/put/patch | Model deserialized from the JSON body into a `body` variable |
| `queryParams` / `query` | get | Model built from the query string into a `queryParams` variable |
| `validator` | get | Custom validator for the query model |
| `tags`, `summary`, `description`, `operationId`, `deprecated` | all | OpenAPI metadata |

`responses` is required for typed routes; a missing one is a compile-time error.

Typed handlers return model values, not JSON:

```nim
app.delete("/users/{id}", responses = @[(204, void), (404, ErrorResponse)]):
  if index == -1:
    notFound ErrorResponse(detail: "User not found")
  else:
    users.del index
    noContent void
```

Status helpers available in typed handlers: `ok`, `created`, `badRequest`, `conflict`,
`unprocessableEntity`, `notFound`, `noContent`.

> Naming: the framework already exports an `ApiError` type. A user model named `ApiError`
> shadows it and produces an `IgnoredSymbolInjection` warning — prefer `ErrorResponse`.

## Extraction (untyped routes)

```nim
request.pathParam("itemId")          # path segment, URL-decoded
request.pathParams["itemId"]         # table access
request.queryParam("page", "1")      # query string, default optional
request.queryParamValues("tag")      # repeated query keys
request.header("authorization")      # header lookup
parseJsonBody[Model](request, value) # bool success
parseFormBody[Model](request, value) # urlencoded form
```

## Validation

`params/validate.nim`:

- `validate[T](value)` → `ValidationResult` for a plain value
- `validate[T](request, Model)` → `ValidatedBody[T]` for a request body
- `parseAndValidateBody[T](request, Model)`
- Field checks: `checkNonEmpty`, `checkEmail`, `checkLengthAtLeast`, `checkLengthAtMost`,
  `checkPositive`, `checkGreaterThan`, `checkLessThan`, `checkRange`, `checkAllowed`
- `toValidationError(result)`, `validationResponse(...)`, `queryParsingResponse(...)`

Invalid input yields `400` or `422` with a JSON error body.

## Path params with types

`{id:int}` declares a typed path parameter; the route adapter converts and rejects malformed
values with `400`. See `examples/typed_path_params.nim`.

## OpenAPI generation

- `app.openApiDocument()` returns the generated `JsonNode`.
- Built-ins serve `/openapi.json` and `/docs` (Swagger UI) by default; configure via the
  OpenAPI plugin (`references/plugins.md`).
- Typed models produce inline schemas; path templates produce required path parameters.
- Untyped routes are documented only as a generic `200` unless `responses` is declared.
- `app.configureOpenApi(settings)` and `app.addOpenApiContributor(contributor)` for extensions.

## Routers

```nim
let api = initRouter("/api", @["api"])
api.get("/items", responses = @[(200, seq[Item])]):
  ok items
app.addRouter(api)
```

Router middleware applies only to that router's HTTP routes. SSE and WebSocket routes bypass
middleware on both applications and routers.
