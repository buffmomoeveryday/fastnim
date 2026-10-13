# FastNim

`fastnim` is a small, FastNim API-inspired HTTP framework built on Chronos.

```nim
import chronos
import std/json
import fastnim

let app = initFastNim()

app.get("/items/{itemId}"):
  let itemId = request.pathParam("itemId")
  let page = request.queryParam("page", "1")
  %* {"itemId": itemId, "page": page}

let server = app.serve(port = 8000)
waitFor server.join()
```

Route blocks may end with a status and JSON value tuple. Status aliases such
as `ok`, `created`, and `notFound` are also accepted. Nim requires tuple
syntax, so wrap the pair in parentheses:

```nim
app.get("/items/{itemId}"):
  let itemId = request.pathParam("itemId")
  if itemId == "missing":
    return (notFound, %*{"detail": "item not found"})
  (ok, %*{"itemId": itemId})
```

The current foundation includes route registration for `GET`, `POST`, `PUT`,
`PATCH`, `DELETE`, and `QUERY`, path templates such as `/items/{itemId}`, decoded query
parameters, request bodies and headers, text/JSON/HTML responses, 404 handling, and
the Chronos HTTP server adapter.

## Async handlers

Route blocks run asynchronously on the Chronos event loop, so they can await
Chronos futures directly:

```nim
app.get("/inventory"):
  await sleepAsync(10.milliseconds)
  %*{"available": true}
```

Use Chronos-native asynchronous operations such as `sleepAsync` in handlers
and middleware. Do not use `os.sleep`, blocking sockets, or
`std/asyncdispatch`; blocking work stalls every request sharing the event-loop
thread. Existing synchronous handler procedures remain supported through a
registration adapter.

`app.query` supports in-process routing and testing. The installed Chronos HTTP
parser does not recognize the `QUERY` method yet, so serving `QUERY` requests
requires a Chronos version with `MethodQuery` support.

## Request limits

`initRequestLimits` caps body size, header name, value, and count, the raw
header block, how long a client may take to send headers, and how long one
HTTP handler may run:

```nim
let app = initFastNim(
  limits = initRequestLimits(
    maxBodySize = 1024 * 1024,
    maxHeaderCount = 40,
    handlerTimeout = 5.seconds,
  )
)
```

`serve` copies `maxBodySize`, `maxHeadersSize`, and `headersTimeout` into
Chronos. A positive `serve(maxRequestBodySize = ...)` overrides `maxBodySize`
for that server. Header name, value, and count limits, and `handlerTimeout`,
are read on each request. `InfiniteDuration` disables a timeout.
`handlerTimeout` does not apply to server-sent events or WebSocket routes.
Handlers must await Chronos operations; `os.sleep` cannot be cancelled.

| Condition | Status |
| --- | --- |
| Body or upload above its limit | `413` |
| Header name, value, count, or raw header block above its limit | `431` |
| Malformed request | `400` |
| Client stalls while sending headers | `408` |
| HTTP handler exceeds `handlerTimeout` | `503` |

Limit responses are JSON `{"detail": ...}`. `onError` can replace that body.
A handler deadline cancels the handler and is still logged with its status and
elapsed time. The connection stays open for later requests.

## Typed query parameters

Declare query parameters as an object and pass its type to the route. FastNim
parses it before the handler, exposes it as `queryParams`, validates field pragmas,
and documents each field as an OpenAPI query parameter:

```nim
import std/options

type
  SortField = enum
    name = "name"
    price = "price"

  ProductQuery = object
    page {.ge: 1.}: int = 1
    limit {.ge: 1, le: 100.}: int = 20
    available: bool = false
    sort: SortField
    minPrice {.jsonName: "min_price".}: Option[int]
    tags {.jsonName: "tag".}: seq[string]

app.get(
  "/products", queryParams = ProductQuery, responses = @[(200, ProductOut)]
):
  ok ProductOut(
    page: queryParams.page,
    limit: queryParams.limit,
    sort: queryParams.sort,
  )
```

A scalar field without an initializer is required. An initializer supplies its
missing-value default. Missing `Option[T]` and `seq[T]` fields become `none(T)`
and an empty sequence. Use `jsonName` when the query name differs from the Nim
field name. For cross-field rules, pass `validator = validateProductQuery`; it
has the same `ValidationResult` contract as typed request-body validators.

The supported scalar types are `string`, `int`, `bool`, and enums. Booleans
accept `true/false`, `1/0`, `yes/no`, `on/off`, and `y/n` without regard to
ASCII letter case. Enums match their `$` representation exactly and are
case-sensitive, so explicitly named enum strings make a stable wire format.

`Option[T]` returns `none(T)` when absent. `seq[T]` consumes repeated names in
URL order (`?tag=nim&tag=web`); commas are ordinary characters and are not
split. Scalars retain the existing last-value-wins behavior. Missing required
scalars and malformed values return structured 400 errors through
`queryParsingResponse`; successfully parsed values that fail constraints such
as pagination bounds return 422 through `validationResponse`.

The lower-level `queryParam[T](request, name, parsing)` overloads remain
available when a handler needs dynamic parameter names or custom control flow.

## Scaffolding

Install the `fastnim` binary (`nimble install`) and generate a project:

```sh
fastnim init myapp --template:inertiajs
```

Omitted choices prompt interactively (framework, package manager, CSS); piped
or CI runs fall back to Svelte, pnpm, and Tailwind. Every choice also has a
flag, so runs stay scriptable:

```sh
fastnim init shop --template:inertiajs --frontend:react --pkgmanager:bun --css:none
```

Available templates:

- `api` (default) — versioned JSON API: typed models, a users router with
  list/get/create/delete routes, and an in-process test suite.
  ```sh
  fastnim init myapp
  nim c -r --path:src src/main.nim   # inside myapp/
  ```
- `karax_ssr` — server-rendered Karax pages served as HTML.
  ```sh
  fastnim init site --template:karax_ssr
  ```
- `karax_csr` — Karax client compiled with `nim js`, served statically
  alongside a JSON API.
  ```sh
  fastnim init app --template:karax_csr
  nimble client                      # inside app/
  nim c -r --path:src src/main.nim
  ```
- `inertiajs` — FastNim + Inertia server with a Vite client (Svelte or React,
  Tailwind v4 or plain CSS). After scaffolding, the CLI can run the client
  install for you, then:
  ```sh
  cd shop/client && pnpm dev          # Vite on http://localhost:5173
  INERTIA_DEV=1 nim c -r --path:src src/main.nim   # Nim server on :8000
  ```
  For production, build the client and serve `client/dist` from Nim:
  ```sh
  cd shop/client && pnpm build
  APP_VERSION=$(date +%s) nim c -r --path:src src/main.nim
  ```

## Application lifecycle and context

Use load and unload hooks for application-scoped resources such as a database
connection pool. The shared context is available as `ctx` inside route blocks:

```nim
type Database = ref object of RootObj

proc loadDatabase(ctx: Context) =
  ctx.setContext("db", Database())

proc unloadDatabase(ctx: Context) =
  ## Close ctx.db here.
  discard

let app = initFastNim()
app.onLoad(loadDatabase)
app.onUnload(unloadDatabase)

app.get("/health"):
  if ctx.db == nil: "database unavailable" else: "ok"

let server = app.serve()
waitFor server.join()
app.stop(server)
```

`serve` runs load hooks once. `app.stop(server)` stops the server and runs
unload hooks in reverse registration order. `Context.setContext` and
`Context.get` can be used for additional reference-typed dependencies, such
as `ctx.setContext("redis", pool)`.

## Logging

Applications log request completion, status, elapsed microseconds, and
unhandled request errors to a colorized console logger by default. Disable
framework logs with `logs = false`:

```nim
let app = initFastNim(logs = false)
```

## Middleware

Register HTTP middleware with `app.use`. Middleware runs in registration order;
each layer receives the request and `next`, and can modify the downstream
response or return early to short-circuit it.

Declare a named middleware with the `middleware` macro; it supplies `request`
and `next` and creates a `Middleware` value. Explicit status responses put the
status first, and JSON status responses require a `JsonNode` (for example,
`%*{...}`):

```nim
middleware requireAuth:
  if request.header("authorization") == "":
    return json(statusUnauthorized, %*{"detail": "missing credentials"})
  await next(request)

app.use(requireAuth)
```

Run the complete authorization and response-header example with
`nim c -r --path:src examples/middleware.nim`.

```nim
app.use(proc(
    request: Request, next: NextHandler
): Future[Response] {.async: (raises: [CatchableError]).} =
  var response = await next(request)
  response.setHeader("x-request-path", request.path)
  response
)
```

The command style (`app.use:`) accepts one middleware. The plural alias
(`app.middlewares:`) accepts a list and registers each middleware in order:

```nim
app.use:
  proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    var response = await next(request)
    response.setHeader("x-request-path", request.path)
    response

app.middlewares:
  requestId()
  responseTime()
```

FastNim includes dependency-free CORS, request-ID, and response-time middleware:

```nim
app.use(cors(initCorsOptions(allowOrigins = @["https://app.example.com"])))
app.use(requestId())
app.use(responseTime())
```

For a custom destination, adapt any `std/logging.Logger` without changing the
process-wide Nim logging handlers:

```nim
import std/logging

let fileLogger = newFileLogger("api.log", levelThreshold = lvlInfo)
let app = initFastNim(logHandler = nimLogHandler(fileLogger))
```

## Forms

Typed form routes decode ``application/x-www-form-urlencoded`` fields into the
implicit ``form`` value:

```nim
type LoginForm = object
  username: string
  remember: bool

app.post("/login", form = LoginForm, responses = @[(200, LoginForm)]):
  respondOk(form)
```

Fields support strings, booleans, numeric types, and enums. Malformed typed
values return `400 {"detail":"invalid form request body"}`. Run the complete
example with `nim c -r --path:src examples/forms.nim`.

## Multipart uploads

Multipart files stream to server-generated files by default, so file size does
not determine parser memory usage. Parse them from an async handler:

```nim
type ProductImageForm = object
  image* {.upload(
    contentTypes = ["image/jpeg", "image/png"],
    uploadDir = "product-images",
    maxRequestSize = 6 * 1024 * 1024,
    maxFileSize = 5 * 1024 * 1024,
  ).}: UploadedFile

app.post("/products/{id}/image"):
  let form = await request.parseUpload(ProductImageForm)
  let image = form.image
  json %*{
    "filename": image.filename,
    "contentType": image.contentType,
    "size": image.size,
    "path": image.path,
  }
```

Declare multiple file fields in the same object. A metadata-aware S3 key
builder can route each field to a different prefix:

```nim
type ProductAssetsForm = object
  image* {.upload(contentTypes = ["image/jpeg", "image/png"]).}: UploadedFile
  manual* {.upload(contentTypes = ["application/pdf"]).}: UploadedFile

app.post("/products/{id}/assets"):
  let productId = request.pathParam("id")
  let assets = await s3.upload(
    request,
    ProductAssetsForm,
    key = proc(file: UploadMetadata): string =
      case file.fieldName
      of "image": "products/" & productId & "/images/primary"
      of "manual": "products/" & productId & "/manuals/spec.pdf"
      else: raise newException(ValueError, "unexpected upload field"),
  )
  json %*{
    "image": assets.image.stored.location,
    "manual": assets.manual.stored.location,
  }
```

Single-file S3 schemas return an `UploadedFile` directly. Multi-file schemas
return the populated typed form so each uploaded file remains addressable by
its declared field.

Successful disk uploads belong to the application; move or delete them when
they are no longer needed. Partial files are deleted after malformed input,
limit failures, or cancellation. Client filenames are metadata only and are
never used as filesystem paths. Use the lower-level `parseMultipart` API when
you need multiple files, repeated fields, or a custom validation hook.

In-memory files require explicit opt-in and a mandatory aggregate cap:

```nim
let options = initMultipartOptions(
  storage = UploadStorage.Memory,
  memorySizeCap = 1024 * 1024,
)
```

Malformed multipart input returns JSON `400`, size and file-count violations
return `413`, and rejected content types return `415`. `maxBodySize` is the
outer cap: a `Content-Length` or buffered body above it returns `413` before
`parseMultipart` runs. Keep it at least as large as the endpoint's multipart
`maxRequestSize`. `serve(maxRequestBodySize = ...)` overrides that cap for the
server. A handler timeout cancels parsing and deletes partial uploads. See
[`examples/product_image_upload.nim`](examples/product_image_upload.nim) for a
complete product-image endpoint and `curl -F` command.

### External and S3 storage

Storage integrations implement the small `UploadStore`/`UploadSink` contract.
The multipart parser still owns request, file-count, file-size, and content-type
limits, and aborts or rolls back the store when parsing fails or is cancelled:

```nim
let form = await request.parseUpload(ProductImageForm, objectStore)
let imageUrl = form.image.stored.location
```

The optional [`fastnim/plugins/s3`](src/fastnim/plugins/s3.nim) module
implements bounded S3 multipart uploads with Chronos HTTP and built-in SigV4
signing. Configure the destination and credentials once, install the returned
handle, then stream a configured upload directly from the request:

```nim
let s3 = s3Plugin(initS3Config(
  bucket = "product-assets",
  region = getEnv("AWS_REGION", "us-east-1"),
  accessKey = getEnv("AWS_ACCESS_KEY_ID"),
  secretKey = getEnv("AWS_SECRET_ACCESS_KEY"),
  sessionToken = getEnv("AWS_SESSION_TOKEN"), # optional
  endpoint = getEnv("S3_ENDPOINT"),           # optional; e.g. MinIO
))
app.install(s3)

app.post("/products/{id}/image"):
  let productId = request.pathParam("id")
  let image = await s3.upload(
    request,
    ProductImageForm,
    key = "products/" & productId & "/primary",
  )
  json %*{"location": image.stored.location}
```

See
[`examples/product_image_upload_s3.nim`](examples/product_image_upload_s3.nim)
for a complete product-image endpoint.

## HTML responses

Return HTML pages with the `html` helper, which sets
`text/html; charset=utf-8`:

```nim
app.get("/"):
  html "<h1>Hello from FastNim</h1>"
```

Run [`examples/html.nim`](examples/html.nim) with
`nim c -r --path:src examples/html.nim`.

Template libraries such as [Karax](https://github.com/karaxnim/karax)
render server-side markup to a plain string; stringify the node with `$` and
pass it to `html`. Karax also exports a `text` routine that collides with
FastNim's, so exclude FastNim's from the import when mixing both in one
module (requires `karax` in your own package):

```nim
import fastnim except text
import karax/[karaxdsl, vdom]

app.get("/"):
  let node = buildHtml(tdiv):
    h1:
      text "Hello from FastNim"
  html("<!doctype html>" & $node)
```

Server-side Karax rendering produces static markup only; event handlers do
not survive. For interactive pages, build the Karax app for the browser and
serve the bundle with `serveStatic` instead.

## Static files

Serve a directory at a URL prefix with `serveStatic`, or one file with
`serveSingleFile`. Only `GET` and `HEAD` are handled; misses, traversal
attempts, and dotfiles fall through to normal routing and custom 404
handlers. Responses include a MIME type, `ETag`/`Last-Modified` with `304`
support, single-range `206` responses, and `Cache-Control`. Files above
`streamThreshold` stream in chunks instead of loading into memory:

```nim
let app = initFastNim()
app.serveStatic("/static", directory = "static")
app.serveSingleFile("/favicon.ico", "static/favicon.ico")
```

Bake small assets into the binary with `serveStaticEmbedded` (paths resolve
against the calling file, like `staticRead`) so deployments are a single
file. Files larger than `maxEmbedBytes` (default 1 MiB) or with a media
extension in `denyExts` are rejected at compile time; serve those from disk
with `serveStatic`:

```nim
app.serveStaticEmbedded("/static", "static", maxAge = 86400)
app.serveSingleEmbeddedFile("/robots.txt", "static/robots.txt")
```

Run [`examples/static.nim`](examples/static.nim) with
`nim c -r --path:src examples/static.nim`.

## OpenAPI and Swagger UI

FastNim exposes generated OpenAPI 3.1 JSON at `/openapi.json` and Swagger UI at
`/docs` by default. Typed response and request models produce inline schemas;
path templates produce required path parameters. Configure or disable the
built-in endpoints with the OpenAPI plugin:

```nim
import fastnim/plugins/openapi

let app = initFastNim()
app.install:
  openApiPlugin(initOpenApiSettings(title = "Items API", version = "1.0.0"))

app.get(
  "/items/{itemId}",
  responses = @[(200, Item)],
  tags = @["items"],
  summary = "Get an item",
  description = "Returns an item by its identifier.",
):
  ok Item(id: 1, name: request.pathParam("itemId"))
```

Change their URLs or turn both endpoints off when installing the plugin:

```nim
let app = initFastNim()
app.install:
  openApiPlugin(initOpenApiSettings(
    schemaPath = "/internal/openapi.json",
    docsPath = "/internal/docs",
  ))

# Or disable both built-ins:
let privateApp = initFastNim()
privateApp.install:
  openApiPlugin(initOpenApiSettings(enabled = false))
```

The legacy `openApi` argument to `FastNim` is still supported.

Documentation endpoints go through normal middleware, so protect them with the
same authentication policy as any other route:

```nim
proc restrictDocs(request: Request, next: NextHandler): Response =
  if request.path in ["/docs", "/openapi.json"] and
      request.header("authorization") != "Bearer secret":
    return text("Unauthorized", 401)
  next(request)

app.use(restrictDocs)
```

Run [`examples/openapi.nim`](examples/openapi.nim) with
`nim c -r --path:src examples/openapi.nim`.

An untyped route such as `app.get("/health"):` has no model information, so it
is documented only as a generic `200 Successful Response`. Declare
`responses = @[(200, Model)]` (and `body = Model` for JSON input) to generate
the request and response schemas automatically.

## Plugins

FastNim plugins are ordinary Nim packages installed explicitly on an app. A
plugin has a unique name, an install callback, isolated plugin state, ordered
middleware, lifecycle hooks, and optional OpenAPI contributions.

```nim
import fastnim
import fastnim/plugins/ratelimit

let app = initFastNim()
app.install(rateLimitPlugin(initRateLimitOptions(limit = 100, windowSeconds = 60)))
```

The command style (`app.install:`) is an equivalent alternative. Each block
takes a single plugin, so repeat it for additional plugins:

```nim
import fastnim/plugins/openapi
import fastnim/plugins/ratelimit

let app = initFastNim()
app.install:
  openApiPlugin(initOpenApiSettings(
    title = "My Users API",
    version = "2.2.0",
    description = "Internal usermanagement",
  ))
app.install:
  rateLimitPlugin(initRateLimitOptions(limit = 5, windowSeconds = 60))
```

The plugin is available independently as `fastnim/plugins/ratelimit`; the
`fastnim/plugins` namespace also re-exports its public API.

The built-in reference rate limiter uses in-memory fixed windows keyed by
`x-forwarded-for`, returns `429` with `Retry-After` and `X-RateLimit-*` headers,
and adds `429` to generated OpenAPI operations. Session and rate-limit stores
are async, replaceable interfaces; use a shared Redis/database driver for
limits and sessions across multiple processes. The driver contract, atomic
Redis integration pattern, and session cookie/key-rotation guidance are in
[`docs/stores.md`](docs/stores.md). See
[`examples/ratelimit.nim`](examples/ratelimit.nim).

Third-party packages can define a plugin with `initPlugin(name, version,
installCallback)` and install middleware via `app.use`, scoped state through
`app.pluginContext(name)`, and documentation changes through
`app.addOpenApiContributor`.

### Inertia.js

The Inertia plugin turns normal FastNim routes into Inertia page responses. It
serves the initial HTML shell, returns protocol JSON for `X-Inertia` requests,
supports shared and partial props, checks asset versions, and converts `302`
responses after non-GET Inertia requests to `303`.

```nim
import std/json
import fastnim
import fastnim/plugins/inertia

let app = initFastNim()
app.install:
  inertiaPlugin(initInertiaOptions(
    version = "assets-v1",
    sharedProps = %*{"appName": "FastNim"},
  ))

app.get("/users"):
  inertia("Users/Index", %*{"users": ["Ada", "Linus"]})
```

The default HTML shell loads `/assets/app.js`. Pass a custom `rootTemplate`
to `initInertiaOptions` when using another asset path or additional head tags.
Use `inertiaLocation(url)` when an Inertia request must trigger a full-page
visit. See [`examples/inertia.nim`](examples/inertia.nim) for a runnable server.

## Server-Sent Events

Register an SSE endpoint with `sse`. Its async block sends `ServerSentEvent`
values using `send`; the Chronos adapter writes them with the
`text/event-stream` media type.

Run [`examples/sse.nim`](examples/sse.nim) with
`nim c -r --path:src examples/sse.nim`, then connect a browser `EventSource`
or `curl -N http://127.0.0.1:8000/events`.

[`examples/ticker.nim`](examples/ticker.nim) shows a parameterized ticker
endpoint that sends JSON price-update events.

```nim
app.sse("/events"):
  await send(sseEvent("connected", event = "status", id = "1"))
  await send(sseEvent("ready"))
```

## WebSockets

WebSocket routes use the same block syntax as HTTP and SSE routes. The
connection is upgraded by the Chronos adapter before the block starts; call
`accept` to make the connection available, then use `receiveText`, `sendText`,
`receiveBytes`, `sendBytes`, `receiveJson`, or `sendJson`.

```nim
app.websocket("/echo"):
  await websocket.accept()
  while true:
    await websocket.sendText(await websocket.receiveText())
```

Run [`examples/websocket_echo.nim`](examples/websocket_echo.nim) with
`nim c -r --path:src examples/websocket_echo.nim`, then connect to
`ws://127.0.0.1:8000/echo`.

The adapter uses [nim-websock](https://github.com/status-im/nim-websock) and
retains Chronos as the HTTP server. WebSocket upgrades currently require the
small `HttpRequestRef.upgradeStream` Chronos extension in
[`patches/chronos-upgrade-stream.patch`](patches/chronos-upgrade-stream.patch).
Apply it to Chronos 4.4.x until that API is available in the installed Chronos
release.

## MQTT

Install the MQTT plugin to register publication handlers with the same block
syntax as HTTP routes. Successful completion is acknowledged automatically;
explicit rejection is only needed for exceptional outcomes:

```nim
let app = initFastNim()

app.install:
  mqttPlugin(initMqttOptions(address = "0.0.0.0", port = 1883))

app.mqtt("/devices/{deviceId}/telemetry"):
  let deviceId = message.topicParam("deviceId")
  echo deviceId, ": ", message.payloadString

app.mqtt("/private"):
  if connection.username.len == 0:
    return mqttReject(MqttReasonCode.NotAuthorized)

let server = app.serveMqtt()
waitFor server.join()
```

The broker transport supports MQTT 3.1, 3.1.1, and 5.0 over TCP with CONNECT,
QoS 0/1 inbound PUBLISH, SUBSCRIBE, UNSUBSCRIBE, retained messages, PING, and
DISCONNECT. Named route parameters match one topic level. Native `+` and
terminal `#` filters are also accepted. Subscription delivery currently grants
QoS 0. QoS 2, outbound QoS 1 state, persistent sessions, TLS, and MQTT over
WebSocket require later protocol phases.

Run [`examples/mqtt.nim`](examples/mqtt.nim) with
`nim c -r --path:src examples/mqtt.nim` for a complete listener example.

## Typed responses

Declare every status and JSON model a route may return. Within that route,
status helpers such as `ok`, `created`, `accepted`, `badRequest`,
`unauthorized`, `forbidden`, `notFound`, `conflict`, `unprocessableContent`,
`tooManyRequests`, and `internalServerError` are checked at compile time against
the declared status/model pair. The same helpers work in untyped routes and
return JSON responses, including when passed a `%*` JSON node. `noContent void`
is the special empty 204 response.

```nim
type
  Item = object
    id: int

  ApiError = object
    detail: string

app.get("/items/{itemId}", responses = @[(200, Item), (404, ApiError)]):
  if request.pathParam("itemId") == "1":
    ok Item(id: 1)
  else:
    notFound ApiError(detail: "item not found")
```

## Typed JSON bodies

For `POST` routes, declare `body = ModelType`; the route receives the decoded
model as `body` and retains the raw HTTP request as `request`. Invalid JSON
returns `400 {"detail":"invalid JSON request body"}`.

```nim
type
  CreateItem = object
    name: string

app.post("/items", body = CreateItem, responses = @[(201, Item)]):
  created Item(id: 1)
```

For an untyped route, the same helpers accept `%*` values directly:

```nim
app.post("/login"):
  if not authenticated:
    unauthorized %*{"detail": "invalid credentials"}
  else:
    ok %*{"message": "hello"}
```

Rename a model field in request JSON, response JSON, and generated OpenAPI with
the `jsonName` pragma:

```nim
type User = object
  displayName {.jsonName: "display_name".}: string
```

The Nim field remains `user.displayName`, while its JSON property is
`display_name`. Empty names and names that collide with another field are
rejected at compile time.

## Testing

`TestClient` drives your app in-process — no ports, no server — FastAPI
`TestClient` style. The client exposes `get/post/put/patch/delete/query` and
every call returns a `Response` with `status`, `body`, and `headers`; the
`json` helper parses the body:

```nim
import std/unittest
import fastnim
import fastnim/testing

let client = initTestClient(api)

suite "main":
  test "reads root":
    let response = client.get("/")
    check response.status == 200
    check response.json() == %*{"msg": "Hello World"}
```

`fastnim init --template:api` scaffolds a `tests/` suite in exactly this
style. See [`tests/ttestclient.nim`](tests/ttestclient.nim) for per-verb
examples, including headers and query strings.


## API documentation

Every exported symbol is documented with `##` doc comments. Render the full
HTML API reference with `nim doc`:

```sh
nimble docs
```

This generates one page per module under `htmldocs/` (open
`htmldocs/fastnim.html` to start). To render a single module while editing
its docs:

```sh
nim doc --outdir:htmldocs --path:src src/fastnim/routing/router.nim
```
