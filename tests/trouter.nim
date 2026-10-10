import std/[json, tables]

import fastnim

type
  CreateItem = object
    name: string

  Item = object
    id: int
    name: string

block routerPrefixJoining:
  let router = initRouter(prefix = "/users")
  router.get("/"):
    %*{"ok": true}
  router.get("/{id}"):
    %*{"id": request.pathParam("id")}

  let app = initFastNim(logs = false)
  app.addRouter(router)

  let index = app.handle(initRequest(HttpMethod.Get, "/users/"))
  doAssert index.status == 200
  doAssert index.body == "{\"ok\":true}"

  let item = app.handle(initRequest(HttpMethod.Get, "/users/42"))
  doAssert item.status == 200
  doAssert item.body == "{\"id\":\"42\"}"

  let unprefixed = app.handle(initRequest(HttpMethod.Get, "/"))
  doAssert unprefixed.status == 404

block routerMountPrefix:
  let router = initRouter(prefix = "/users")
  router.get("/"):
    %*{"ok": true}

  let app = initFastNim(logs = false)
  app.addRouter(router, prefix = "/v1")

  let versioned = app.handle(initRequest(HttpMethod.Get, "/v1/users/"))
  doAssert versioned.status == 200

  let bare = app.handle(initRequest(HttpMethod.Get, "/users/"))
  doAssert bare.status == 404

block routerTypedRoutes:
  let router = initRouter(prefix = "/items")
  router.post("/", body = CreateItem, responses = @[(201, Item)]):
    created Item(id: 1, name: body.name)

  let app = initFastNim(logs = false)
  app.addRouter(router)

  var headers = initTable[string, string]()
  headers["content-type"] = "application/json"
  let created =
    app.handle(initRequest(HttpMethod.Post, "/items/", headers, """{"name":"Widget"}"""))
  doAssert created.status == 201
  doAssert created.body == "{\"id\":1,\"name\":\"Widget\"}"

  let invalid =
    app.handle(initRequest(HttpMethod.Post, "/items/", headers, "not json"))
  doAssert invalid.status == 400

block routerMiddlewareIsolation:
  proc tagUsers(request: Request, next: NextHandler): Response =
    var response = next(request)
    response.setHeader("x-router", "users")
    response

  let userRouter = initRouter(prefix = "/users")
  userRouter.get("/"):
    %*{"ok": true}
  userRouter.use(tagUsers)

  let plainRouter = initRouter(prefix = "/plain")
  plainRouter.get("/"):
    %*{"ok": true}

  let app = initFastNim(logs = false)
  app.get("/app"):
    %*{"ok": true}
  app.addRouter(userRouter)
  app.addRouter(plainRouter)

  let scoped = app.handle(initRequest(HttpMethod.Get, "/users/"))
  doAssert scoped.headers.getOrDefault("x-router") == "users"

  let unscoped = app.handle(initRequest(HttpMethod.Get, "/plain/"))
  doAssert unscoped.headers.getOrDefault("x-router") == ""

  let appRoute = app.handle(initRequest(HttpMethod.Get, "/app"))
  doAssert appRoute.headers.getOrDefault("x-router") == ""

block routerTagsMerge:
  let router = initRouter(prefix = "/users", tags = @["users"])
  router.get(
    "/",
    responses = @[(200, Item)],
    tags = @["custom"],
  ):
    ok Item(id: 1, name: "Ada")

  let app = initFastNim(logs = false)
  app.addRouter(router, tags = @["v1"])

  let document = app.openApiDocument()
  var seen: seq[string] = @[]
  for tag in document["paths"]["/users/"]["get"]["tags"]:
    seen.add(tag.getStr())
  doAssert "v1" in seen
  doAssert "users" in seen
  doAssert "custom" in seen

block routerSseAndWebSocketPrefix:
  let router = initRouter(prefix = "/events")
  router.sse("/feed"):
    discard
  router.websocket("/chat"):
    discard

  let app = initFastNim(logs = false)
  app.addRouter(router, prefix = "/v1")

  doAssert app.isSseRoute(initRequest(HttpMethod.Get, "/v1/events/feed"))
  doAssert not app.isSseRoute(initRequest(HttpMethod.Get, "/events/feed"))
  doAssert app.isWebSocketRoute(initRequest(HttpMethod.Get, "/v1/events/chat"))

block routerValidation:
  let app = initFastNim(logs = false)
  let router = initRouter(prefix = "/users")

  var raised = false
  try:
    app.addRouter(router, prefix = "v1")
  except ValueError:
    raised = true
  doAssert raised

  raised = false
  try:
    discard initRouter(prefix = "users")
  except ValueError:
    raised = true
  doAssert raised

  raised = false
  try:
    router.put("nope", proc(request: Request): Response = json("{}"))
  except ValueError:
    raised = true
  doAssert raised
