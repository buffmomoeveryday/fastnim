import std/[assertions, strutils, tables]

import fastnim

block handlesCorsPreflight:
  let app = initFastNim(logs = false)
  app.addMiddleware(cors(initCorsOptions(allowOrigins = @["https://app.example.com"])))
  let response = app.handleSync(
    initRequest(
      HttpMethod.Options,
      "/items",
      {"origin": "https://app.example.com", "access-control-request-method": "GET"}.toTable,
    )
  )
  doAssert response.status == 204
  doAssert response.headers["access-control-allow-origin"] == "https://app.example.com"
  doAssert "GET" in response.headers["access-control-allow-methods"]

block appliesCorsToMatchingOrigins:
  let app = initFastNim(logs = false)
  app.addMiddleware(cors(initCorsOptions(allowOrigins = @["https://app.example.com"])))
  app.get("/"):
    text("ok")
  let response = app.handleSync(
    initRequest(HttpMethod.Get, "/", {"origin": "https://app.example.com"}.toTable)
  )
  doAssert response.headers["access-control-allow-origin"] == "https://app.example.com"

block propagatesRequestIdsAndAddsResponseTime:
  let app = initFastNim(logs = false)
  app.addMiddleware(requestId())
  app.addMiddleware(responseTime())
  app.get("/"):
    text(request.header("x-request-id"))
  let response = app.handleSync(
    initRequest(HttpMethod.Get, "/", {"x-request-id": "trace-42"}.toTable)
  )
  doAssert response.body == "trace-42"
  doAssert response.headers["x-request-id"] == "trace-42"
  doAssert "x-response-time-us" in response.headers
