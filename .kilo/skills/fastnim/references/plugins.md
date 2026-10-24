# Plugins and static files

Source of truth: `src/fastnim/plugin.nim`, `src/fastnim/plugins/`, `src/fastnim/static/`.

## Installing a plugin

Plugins must be installed before `app.load` / `app.serve`:

```nim
app.installPlugin:
  rateLimitPlugin(initRateLimitOptions(limit = 5, windowSeconds = 60))
```

The colon block passes the plugin value to `installPlugin(app, plugin)`. Equivalent explicit
form:

```nim
app.installPlugin(initPlugin(name = "ratelimit", version = "1.0.0", install: proc(app: Application) = ...))
```

Installing after the app has loaded raises `ValueError`; installing the same name twice raises
`ValueError` as well.

- `app.installedPlugins` — list of `PluginInfo` in installation order.
- `app.pluginContext("name")` — isolated `Context` scoped to a plugin.

## Available plugins

| Module | Entry point | Purpose |
| --- | --- | --- |
| `fastnim/plugins/ratelimit` | `rateLimitPlugin(initRateLimitOptions(...))` | Request rate limiting; `newInMemoryRateLimitStore()` for the store |
| `fastnim/plugins/openapi` | `openApiPlugin(initOpenApiSettings(...))` | Configure/disable `/openapi.json` and `/docs` |
| `fastnim/plugins/auth` | see `plugins/auth/` | Basic auth, bearer token, JWT, sessions |
| `fastnim/plugins/inertia` | see `plugins/inertia.nim` | Inertia.js SSR |
| `fastnim/plugins/datastar` | see `plugins/datastar.nim` | Datastar reactive UI |
| `fastnim/plugins/s3` | `installPlugin(app, s3Client)` | S3 object storage for uploads |
| `fastnim/plugins/mqtt` | see `plugins/mqtt.nim` | MQTT broker/client integration |
| `fastnim/plugins/grpc` | see `plugins/grpc.nim` | Native gRPC listener |

`import fastnim` already re-exports the `fastnim/plugins` namespace, so plugin symbols are
available without a second import when the whole namespace is wanted. Import the specific
module (`import fastnim/plugins/ratelimit`) when you want a narrow dependency.

## OpenAPI plugin settings

```nim
app.installPlugin:
  openApiPlugin(initOpenApiSettings(
    title = "Items API",
    version = "1.0.0",
    schemaPath = "/internal/openapi.json",
    docsPath = "/internal/docs",
    enabled = false,   # disables both built-in endpoints
  ))
```

## Static files

```nim
app.serveStatic("/static", "public",
  indexFile = "index.html",
  maxAge = 3600,
  allowDotfiles = false,
  spaFallback = "index.html",
  streamThreshold = 1_048_576,
)
```

- Only `GET`/`HEAD` below the prefix are handled; everything else falls through to normal
  routing and custom 404 handlers.
- Directory traversal and dotfiles are rejected unless `allowDotfiles = true`.
- `spaFallback` (relative to the directory) serves unknown subpaths — this is SPA hosting.
- Files at or above `streamThreshold` are streamed in chunks instead of loaded into memory.

Embedded assets use compile-time macros:

```nim
serveStaticEmbedded(app, "/assets", "assets/")     # macro
serveSingleEmbeddedFile(app, "/favicon.ico", "assets/favicon.ico")
```

## Upload sinks

`src/fastnim/params/uploadsink.nim` and `src/fastnim/params/multipart.nim` handle multipart
parsing and pluggable upload destinations (local disk, S3). See
`examples/product_image_upload.nim` and `examples/product_image_upload_s3.nim`.
