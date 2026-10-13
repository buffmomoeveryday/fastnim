import std/[assertions, json, strutils, tables]

import fastnim

proc badRequestHandler(request: Request): Response =
  discard request
  raise newBadRequestError("bad input", code = "invalid_input")

proc unauthorizedHandler(request: Request): Response =
  discard request
  raise newUnauthorizedError("sign in required")

proc forbiddenHandler(request: Request): Response =
  discard request
  raise newForbiddenError("access denied")

proc notFoundHandler(request: Request): Response =
  discard request
  raise newNotFoundError("widget not found", code = "widget_not_found")

proc conflictHandler(request: Request): Response =
  discard request
  raise newConflictError("widget already exists")

proc validationHandler(request: Request): Response =
  discard request
  raise newUnprocessableEntityError(
    "validation failed",
    code = "validation_failed",
    fields = {"body.name": "must not be empty"}.toTable,
  )

proc internalFailureHandler(request: Request): Response =
  discard request
  raise newException(ValueError, "secret database password")

proc errorApp(): Application =
  result = initFastNim(logs = false)
  result.get("/400", badRequestHandler)
  result.get("/401", unauthorizedHandler)
  result.get("/403", forbiddenHandler)
  result.get("/404", notFoundHandler)
  result.get("/409", conflictHandler)
  result.get("/422", validationHandler)
  result.get("/500", internalFailureHandler)

block serializesApiError:
  let response = apiErrorResponse(
    statusUnprocessableContent,
    initApiError(
      "validation_failed",
      "validation failed",
      {"body.name": "must not be empty"}.toTable,
    ),
  )
  doAssert response.status == 422
  doAssert parseJson(response.body) == %*{
    "code": "validation_failed",
    "message": "validation failed",
    "fields": {"body.name": "must not be empty"},
  }

block mapsKnownApplicationErrors:
  let app = errorApp()
  for item in [
    ("/400", 400, "invalid_input"),
    ("/401", 401, "unauthorized"),
    ("/403", 403, "forbidden"),
    ("/404", 404, "widget_not_found"),
    ("/409", 409, "conflict"),
    ("/422", 422, "validation_failed"),
  ]:
    let (path, status, code) = item
    let response = app.handleSync(initRequest(HttpMethod.Get, path))
    doAssert response.status == status
    doAssert parseJson(response.body)["code"].getStr() == code
    doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block rendersApplicationErrorFields:
  let response = errorApp().handleSync(initRequest(HttpMethod.Get, "/422"))
  doAssert parseJson(response.body)["fields"]["body.name"].getStr() ==
    "must not be empty"

block sanitizesUnknownCatchableErrors:
  let response = errorApp().handleSync(initRequest(HttpMethod.Get, "/500"))
  doAssert response.status == 500
  doAssert parseJson(response.body) == %*{
    "code": "internal_server_error",
    "message": "Internal Server Error",
    "fields": {},
  }
  doAssert "password" notin response.body

block usesStandardDefaultNotFound:
  let app = initFastNim(logs = false)
  let response = app.handleSync(initRequest(HttpMethod.Get, "/missing"))
  doAssert response.status == 404
  doAssert parseJson(response.body) == %*{
    "code": "not_found", "message": "Not Found", "fields": {}
  }
