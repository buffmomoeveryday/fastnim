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

  let response = app.handle(initRequest(HttpMethod.Get, "/users/ada?page=2"))
  doAssert response.status == 200
  doAssert response.body == "{\"id\":\"ada\",\"page\":\"2\"}"
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block blockRouteRegistration:
  let app = initFastNim()
  app.get("/"):
    %*{"message": "Hello, world!"}
  let response = app.handle(initRequest(HttpMethod.Get, "/"))
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

  let found = app.handle(initRequest(HttpMethod.Get, "/items/42?page=3"))
  doAssert found.status == 200
  doAssert found.body == "{\"itemId\":\"42\",\"page\":\"3\"}"

  let missing = app.handle(initRequest(HttpMethod.Get, "/items/missing"))
  doAssert missing.status == 404
  doAssert missing.body == "{\"detail\":\"item not found\"}"

block implicitStatusTuple:
  let app = initFastNim()
  app.get("/items/{itemId}"):
    let itemId = request.pathParam("itemId")
    (200, %*{"itemId": itemId, "page": request.queryParam("page", "1")})

  let response = app.handle(initRequest(HttpMethod.Get, "/items/7?page=2"))
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
  let response = app.handle(initRequest(HttpMethod.Get, "/headers", headers))
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
  doAssert app.handle(initRequest(HttpMethod.Get, "/items")).status == 404
  doAssert app.handle(initRequest(HttpMethod.Post, "/missing")).status == 404

block customNotFoundHandler:
  let app = initFastNim()
  app.onError(404, proc(request: Request): Response = text("Route not found: " & request.path, 404))
  let response = app.handle(initRequest(HttpMethod.Get, "/missing"))
  doAssert response.status == 404
  doAssert response.body == "Route not found: /missing"

block customInternalServerErrorHandler:
  let app = initFastNim()
  app.errorHandlers[500] = proc(request: Request): Response = text("Oops", 500)
  app.get("/fail", proc(request: Request): Response =
    raise newException(ValueError, "test error")
  )
  let response = app.handle(initRequest(HttpMethod.Get, "/fail"))
  doAssert response.status == 500
  doAssert response.body == "Oops"

block queryMethod:
  let app = initFastNim()
  app.query("/search"):
    json(%*{"query": request.queryParam("q")})
  let response = app.handle(initRequest(HttpMethod.Query, "/search?q=nim"))
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
