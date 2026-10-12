import std/[assertions, json, tables]

import fastnim
import fastnim/plugins/openapi
import fastnim/plugins/ratelimit

type Marker = ref object of RootObj
  value: string

block installsPluginsAndKeepsStateScoped:
  let app = initFastNim(logs = false)
  let plugin = initPlugin(
    "marker",
    "1.0.0",
    proc(app: Application) =
      app.pluginContext("marker").setContext("value", Marker(value: "installed")),
  )
  app.install(plugin)
  doAssert app.installedPlugins.len == 1
  doAssert app.installedPlugins[0].name == "marker"
  doAssert get[Marker](app.pluginContext("marker"), "value").value == "installed"
  doAssertRaises ValueError:
    app.install(plugin)
  app.load()
  doAssertRaises ValueError:
    app.install(
      initPlugin(
        "late",
        "1.0.0",
        proc(app: Application) =
          discard,
      )
    )

block installsPluginsWithCommandSyntax:
  let app = initFastNim(logs = false)
  app.install:
    rateLimitPlugin(initRateLimitOptions(limit = 5, windowSeconds = 60))
  doAssert app.installedPlugins.len == 1
  doAssert app.installedPlugins[0].name == "ratelimit"

block configuresOpenApiAsPlugin:
  let app = initFastNim(logs = false, openApi = initOpenApiSettings(enabled = false))
  app.install:
    openApiPlugin(initOpenApiSettings(title = "Users API", version = "2.2.0"))
  let document = app.openApiDocument()
  doAssert document["info"]["title"].getStr == "Users API"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/openapi.json")).status == 200

block ordersMiddlewareByPhaseAndPriority:
  let app = initFastNim(logs = false)
  var order: seq[string] = @[]
  middleware defaultOrderMiddleware:
    {.cast(gcsafe).}:
      order.add("default")
    await next(request)
  middleware firstOrderMiddleware:
      {.cast(gcsafe).}:
        order.add("first")
      await next(request)
  app.use(defaultOrderMiddleware)
  app.use(firstOrderMiddleware, priority = -10)
  app.get("/"):
    text("ok")
  discard app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert order == @["first", "default"]

block rateLimitPluginBlocksAndDocuments:
  let app = initFastNim(logs = false)
  app.install(rateLimitPlugin(initRateLimitOptions(limit = 1, windowSeconds = 60)))
  app.get("/items", responses = @[(200, string)]):
    "ok"
  let first = app.handleSync(initRequest(HttpMethod.Get, "/items"))
  let second = app.handleSync(initRequest(HttpMethod.Get, "/items"))
  doAssert first.status == 200
  doAssert first.headers["x-ratelimit-remaining"] == "0"
  doAssert second.status == 429
  doAssert second.headers["retry-after"].len > 0
  let document = app.openApiDocument()
  doAssert document["paths"]["/items"]["get"]["responses"]["429"]["description"].getStr ==
    "Too Many Requests"
