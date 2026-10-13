import std/[assertions, json, strutils, tables]

import fastnim

var events {.global.}: array[5, int]
var eventCount {.global.}: int
var syncHandlerCalled {.global.}: bool

proc asyncEndpoint(
    request: Request
): Future[Response] {.async: (raises: [CatchableError]).} =
  await sleepAsync(1.milliseconds)
  return text("async ok")

proc outerMiddleware(
    request: Request, next: NextHandler
): Future[Response] {.async: (raises: [CatchableError]).} =
  events[eventCount] = 1
  inc eventCount
  let response = await next(request)
  events[eventCount] = 5
  inc eventCount
  response

proc innerMiddleware(
    request: Request, next: NextHandler
): Future[Response] {.async: (raises: [CatchableError]).} =
  events[eventCount] = 2
  inc eventCount
  let response = await next(request)
  events[eventCount] = 4
  inc eventCount
  response

proc syncEndpoint(request: Request): Response {.raises: [].} =
  syncHandlerCalled = true
  text("sync ok")

proc failingEndpoint(
    request: Request
): Future[Response] {.async: (raises: [CatchableError]).} =
  await sleepAsync(1.milliseconds)
  raise newException(ValueError, "handler failed")

block asyncHandlerReturns200:
  proc asyncTest() {.async.} =
    let app = initFastNim(logs = false)
    app.get("/async", asyncEndpoint)
    let response = await app.handle(initRequest(HttpMethod.Get, "/async"))
    doAssert response.status == 200
    doAssert response.body == "async ok"

  waitFor asyncTest()

block middlewareAwaitsInOrderAndCanShortCircuit:
  proc asyncTest() {.async.} =
    eventCount = 0
    let app = initFastNim(logs = false)
    app.use(outerMiddleware)
    app.use(innerMiddleware)
    app.get("/ordered"):
      events[eventCount] = 3
      inc eventCount
      text("ordered")
    let response = await app.handle(initRequest(HttpMethod.Get, "/ordered"))
    doAssert response.status == 200
    doAssert events[0 ..< eventCount] == [1, 2, 3, 4, 5]

  waitFor asyncTest()

block middlewareCanShortCircuit:
  var reachedHandler = false
  let shortCircuit = initFastNim(logs = false)
  middleware shortCircuitMiddleware:
    return json(statusForbidden, %*{"detail": "denied"})
  shortCircuit.use(shortCircuitMiddleware)
  shortCircuit.get("/private"):
    reachedHandler = true
    text("private")
  let denied = shortCircuit.handleSync(initRequest(HttpMethod.Get, "/private"))
  doAssert denied.status == 403
  doAssert not reachedHandler

block synchronousHandlerUsesRegistrationAdapter:
  proc asyncTest() {.async.} =
    syncHandlerCalled = false
    let app = initFastNim(logs = false)
    app.get("/sync", syncEndpoint)
    let response = await app.handle(initRequest(HttpMethod.Get, "/sync"))
    doAssert response.status == 200
    doAssert response.body == "sync ok"
    doAssert syncHandlerCalled

  waitFor asyncTest()

block uncaughtHandlerExceptionBecomesJson500:
  proc asyncTest() {.async.} =
    let app = initFastNim(logs = false)
    app.get("/fail", failingEndpoint)
    let response = await app.handle(initRequest(HttpMethod.Get, "/fail"))
    doAssert response.status == 500
    doAssert response.headers["content-type"].startsWith("application/json")
    doAssert parseJson(response.body) == %*{
      "code": "internal_server_error",
      "message": "Internal Server Error",
      "fields": {},
    }
    doAssert "handler failed" notin response.body

  waitFor asyncTest()
