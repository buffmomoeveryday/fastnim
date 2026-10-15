import std/[assertions, json, tables]

import fastnim

var steps {.global.}: array[5, int]
var stepCount {.global.}: int
var endpointCalled {.global.}: bool

middleware requireAuth:
  if request.header("authorization") == "":
    return json(statusUnauthorized, %*{"detail": "missing credentials"})
  await next(request)

proc record(step: int) {.gcsafe, raises: [].} =
  steps[stepCount] = step
  stepCount.inc

middleware firstMiddleware:
  record(1)
  var response = await next(request)
  record(4)
  response.setHeader("x-first", "true")
  response

middleware secondMiddleware:
  record(2)
  let response = await next(request)
  record(3)
  response

proc endpoint(request: Request): Response {.gcsafe, raises: [].} =
  record(5)
  text("ok")

middleware denyMiddleware:
  return text(statusForbidden, "denied")

block wrapsRoutesInRegistrationOrder:
  stepCount = 0
  let app = initFastNim(logs = false)
  app.addMiddleware(firstMiddleware)
  app.addMiddleware(secondMiddleware)
  app.get("/", endpoint)

  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.status == 200
  doAssert response.headers["x-first"] == "true"
  doAssert steps[0..<stepCount] == [1, 2, 5, 3, 4]

block registersMiddlewareWithCommandSyntax:
  stepCount = 0
  let app = initFastNim(logs = false)
  middleware commandStyleMiddleware:
    var response = await next(request)
    response.setHeader("x-command-style", "use")
    response
  middleware pluralCommandStyleMiddleware:
    var response = await next(request)
    response.setHeader("x-command-style-plural", "true")
    response
  app.addMiddleware(commandStyleMiddleware)
  app.middlewares(pluralCommandStyleMiddleware)
  app.get("/", endpoint)

  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.headers["x-command-style"] == "use"
  doAssert response.headers["x-command-style-plural"] == "true"

block registersMiddlewareListInOrder:
  stepCount = 0
  let app = initFastNim(logs = false)
  app.middlewares:
    firstMiddleware
    secondMiddleware
  app.get("/", endpoint)

  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.status == 200
  doAssert steps[0..<stepCount] == [1, 2, 5, 3, 4]

block canShortCircuitRoutes:
  endpointCalled = false
  let app = initFastNim(logs = false)
  app.addMiddleware(denyMiddleware)
  app.get(
    "/private",
    proc(request: Request): Response {.gcsafe, raises: [].} =
      endpointCalled = true
      text("private"),
  )

  let response = app.handleSync(initRequest(HttpMethod.Get, "/private"))
  doAssert response.status == 403
  doAssert response.body == "denied"
  doAssert not endpointCalled

block declaresMiddlewareWithImplicitRequestAndNext:
  let app = initFastNim(logs = false)
  app.addMiddleware(requireAuth)
  app.get("/private"):
    json(%*{"authorized": true})

  let denied = app.handleSync(initRequest(HttpMethod.Get, "/private"))
  doAssert denied.status == 401
  doAssert denied.body == """{"detail":"missing credentials"}"""

  var request = initRequest(HttpMethod.Get, "/private")
  request.headers["authorization"] = "Bearer test"
  let allowed = app.handleSync(request)
  doAssert allowed.status == 200
  doAssert allowed.body == """{"authorized":true}"""
