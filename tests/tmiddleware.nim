import std/[assertions, tables]

import fastnim

var steps {.global.}: array[5, int]
var stepCount {.global.}: int
var endpointCalled {.global.}: bool

proc record(step: int) {.gcsafe, raises: [].} =
  steps[stepCount] = step
  stepCount.inc

proc firstMiddleware(
    request: Request, next: NextHandler
): Future[Response] {.async: (raises: [CatchableError]).} =
  record(1)
  result = await next(request)
  record(4)
  result.setHeader("x-first", "true")

proc secondMiddleware(
    request: Request, next: NextHandler
): Future[Response] {.async: (raises: [CatchableError]).} =
  record(2)
  result = await next(request)
  record(3)

proc endpoint(request: Request): Response {.gcsafe, raises: [].} =
  record(5)
  text("ok")

proc denyMiddleware(
    request: Request, next: NextHandler
): Future[Response] {.async: (raises: [CatchableError]).} =
  return text("denied", 403)

block wrapsRoutesInRegistrationOrder:
  stepCount = 0
  let app = initFastNim(logs = false)
  app.use(firstMiddleware)
  app.use(secondMiddleware)
  app.get("/", endpoint)

  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.status == 200
  doAssert response.headers["x-first"] == "true"
  doAssert steps[0..<stepCount] == [1, 2, 5, 3, 4]

block registersMiddlewareWithCommandSyntax:
  stepCount = 0
  let app = initFastNim(logs = false)
  app.use:
    proc(request: Request, next: NextHandler): Future[Response] {.
        async: (raises: [CatchableError])
    .} =
      var response = await next(request)
      response.setHeader("x-command-style", "use")
      response
  app.middlewares:
    proc(request: Request, next: NextHandler): Future[Response] {.
        async: (raises: [CatchableError])
    .} =
      var response = await next(request)
      response.setHeader("x-command-style-plural", "true")
      response
  app.get("/", endpoint)

  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.headers["x-command-style"] == "use"
  doAssert response.headers["x-command-style-plural"] == "true"

block canShortCircuitRoutes:
  endpointCalled = false
  let app = initFastNim(logs = false)
  app.use(denyMiddleware)
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
