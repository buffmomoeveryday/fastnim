import std/[assertions, json, tables]

import fastnim

block pathAndQueryParameters:
  let app = initFastNim()
  app.get(
    "/users/{userId}",
    proc(request: Request): Response {.raises: [].} =
      json(
        "{\"id\":\"" & request.pathParam("userId") & "\",\"page\":\"" &
          request.queryParam("page") & "\"}"
      ),
  )

  let response = app.handleSync(initRequest(HttpMethod.Get, "/users/ada?page=2"))
  doAssert response.status == 200
  doAssert response.body == "{\"id\":\"ada\",\"page\":\"2\"}"
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block blockRouteRegistration:
  let app = initFastNim()
  app.get("/"):
    %*{"message": "Hello, world!"}
  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.body == "{\"message\":\"Hello, world!\"}"
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block responseReturnSyntax:
  let app = initFastNim()
  app.get("/items/{itemId}"):
    if request.pathParam("itemId") == "missing":
      return (notFound, %*{"detail": "item not found"})
    return (200, %*{
      "itemId": request.pathParam("itemId"), "page": request.queryParam("page", "1"),
    })

  let found = app.handleSync(initRequest(HttpMethod.Get, "/items/42?page=3"))
  doAssert found.status == 200
  doAssert found.body == "{\"itemId\":\"42\",\"page\":\"3\"}"

  let missing = app.handleSync(initRequest(HttpMethod.Get, "/items/missing"))
  doAssert missing.status == 404
  doAssert missing.body == "{\"detail\":\"item not found\"}"

block implicitStatusTuple:
  let app = initFastNim()
  app.get("/items/{itemId}"):
    let itemId = request.pathParam("itemId")
    (200, %*{"itemId": itemId, "page": request.queryParam("page", "1")})

  let response = app.handleSync(initRequest(HttpMethod.Get, "/items/7?page=2"))
  doAssert response.status == 200
  doAssert response.body == "{\"itemId\":\"7\",\"page\":\"2\"}"

block requestAndResponseHelpers:
  let app = initFastNim()
  var headers = initTable[string, string]()
  headers["x-request-id"] = "abc-123"
  app.get("/headers"):
    var response = text(request.header("X-Request-Id"))
    response.setHeader("X-Frame-Options", "DENY")
    response
  let response = app.handleSync(initRequest(HttpMethod.Get, "/headers", headers))
  doAssert response.body == "abc-123"
  doAssert response.headers["x-frame-options"] == "DENY"

block decodedQueryParameters:
  let request = initRequest(HttpMethod.Get, "/search?q=nim%20lang&tag=async+io")
  doAssert request.queryParam("q") == "nim lang"
  doAssert request.queryParam("tag") == "async io"

block methodAndMissingRoute:
  let app = initFastNim()
  app.post(
    "/items",
    proc(request: Request): Response {.raises: [].} =
      text("created", 201),
  )
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/items")).status == 404
  doAssert app.handleSync(initRequest(HttpMethod.Post, "/missing")).status == 404

block routeMacrosDoNotHijackMethodCalls:
  var items = @["a", "b", "c"]
  items.delete(0)
  doAssert items == @["b", "c"]
  let app = initFastNim()
  app.get("/"):
    text("ok")
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/")).body == "ok"

block simplePostBlockBindsRequest:
  let app = initFastNim()
  app.post("/echo/{name}"):
    text(
      request.pathParam("name") & ":" & request.queryParam("q", "none") & ":" &
        request.body
    )
  var headers = initTable[string, string]()
  let response =
    app.handleSync(initRequest(HttpMethod.Post, "/echo/ada?q=1", headers, "payload"))
  doAssert response.status == 200
  doAssert response.body == "ada:1:payload"

block simplePostBlockBindsCtx:
  type Greeting = ref object of RootObj
    message: string
  let app = initFastNim()
  app.context.setContext("greeting", Greeting(message: "hi"))
  app.post("/greet"):
    text(get[Greeting](ctx, "greeting").message)
  doAssert app.handleSync(initRequest(HttpMethod.Post, "/greet")).body == "hi"

block namedTypedPostBody:
  type PItem = object
    name: string
  type PCreated = object
    id: int
    name: string
  let app = initFastNim()
  app.post("/items", body = PItem, responses = @[(201, PCreated)]):
    created PCreated(id: 1, name: body.name)
  var headers = initTable[string, string]()
  let response = app.handleSync(
    initRequest(HttpMethod.Post, "/items", headers, """{"name":"Widget"}""")
  )
  doAssert response.status == 201
  doAssert response.body == "{\"id\":1,\"name\":\"Widget\"}"

block customNotFoundHandler:
  let app = initFastNim()
  app.onError(404, proc(request: Request): Response = text("Route not found: " & request.path, 404))
  let response = app.handleSync(initRequest(HttpMethod.Get, "/missing"))
  doAssert response.status == 404
  doAssert response.body == "Route not found: /missing"

block customInternalServerErrorHandler:
  let app = initFastNim()
  app.errorHandlers[500] = proc(request: Request): Response = text("Oops", 500)
  app.get("/fail", proc(request: Request): Response =
    raise newException(ValueError, "test error")
  )
  let response = app.handleSync(initRequest(HttpMethod.Get, "/fail"))
  doAssert response.status == 500
  doAssert response.body == "Oops"

block queryMethod:
  let app = initFastNim()
  app.query("/search"):
    json(%*{"query": request.queryParam("q")})
  let response = app.handleSync(initRequest(HttpMethod.Query, "/search?q=nim"))
  doAssert response.status == 200
  doAssert response.body == "{\"query\":\"nim\"}"

block invalidRoutePath:
  let app = initFastNim()
  doAssertRaises ValueError:
    app.get(
      "items",
      proc(request: Request): Response {.raises: [].} =
        text("never"),
    )
