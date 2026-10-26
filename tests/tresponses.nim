import std/[assertions, json]

import fastnim

static:
  doAssert not compiles(json(statusUnauthorized, "not a JSON node"))
  doAssert not compiles(response(statusOk, %*{"detail": "bad"}))

type
  Success = object
    id: int

  Failure = object
    detail: string

  CreateItem = object
    name: string

  RenamedProfile = object
    displayName {.jsonName: "display_name".}: string
    age: int

  RenamedEnvelope = object
    profiles: seq[RenamedProfile]

  ValueKind = enum
    vkBool
    vkString

  FilteredMessage = object
    status: string
    case value {.jsonRespIgnore.}: ValueKind
    of vkBool:
      boolVal: bool
    of vkString:
      strVal: string

let app = initFastNim()
app.get("/items", responses = @[ok, Success, badRequest, Failure]):
  ok Success(id: 1)

app.get("/items/named-tuple", responses = @[(ok, Success), (notFound, Failure)]):
  notFound Failure(detail: "missing")

app.get("/items/return", responses = @[(200, Success)]):
  return (ok, Success(id: 2))

app.post("/items", responses = @[(201, Success), (400, Failure)]):
  badRequest Failure(detail: "name is required")

app.post("/items/from-body", body = CreateItem, responses = @[(201, Success)]):
  created Success(id: body.name.len)

block declaredSuccessResponse:
  let response = app.handleSync(initRequest(HttpMethod.Get, "/items"))
  doAssert response.status == 200
  doAssert response.body == "{\"id\":1}"
  let missing = app.handleSync(initRequest(HttpMethod.Get, "/items/named-tuple"))
  doAssert missing.status == 404
  doAssert missing.body == """{"detail":"missing"}"""
  let operation = app.openApiDocument()["paths"]["/items"]["get"]
  doAssert "200" in operation["responses"]
  doAssert "400" in operation["responses"]

block namedHttpStatusCodes:
  doAssert statusCode(statusCreated) == 201
  doAssert statusCode(statusBadRequest) == 400
  doAssert statusCode(statusUnauthorized) == 401
  doAssert statusCode(statusForbidden) == 403
  doAssert statusCode(statusNotFound) == 404
  doAssert statusCode(statusInternalServerError) == 500
  let response = badRequest %*{"detail": "invalid"}
  doAssert response.status == 400
  doAssert response.body == """{"detail":"invalid"}"""

block statusHelpersOutsideTypedRoutes:
  let denied = unauthorized %*{"detail": "missing credentials"}
  let unavailable = serviceUnavailable %*{"detail": "try again"}
  let helper = initFastNim(logs = false)
  helper.get("/hello"):
    ok %*{"message": "hello"}
  let hello = helper.handleSync(initRequest(HttpMethod.Get, "/hello"))
  doAssert denied.status == 401
  doAssert denied.headers["content-type"] == "application/json; charset=utf-8"
  doAssert unavailable.status == 503
  doAssert hello.status == 200
  doAssert hello.body == """{"message":"hello"}"""

block responseHeadersRetainRepeatedValues:
  var response = text("cookies")
  response.addHeader("Set-Cookie", "theme=dark; Path=/")
  response.addHeader("set-cookie", "session=abc; HttpOnly")
  doAssert response.headers["SET-COOKIE"] == "session=abc; HttpOnly"
  doAssert response.getAllHeaders("Set-Cookie") ==
    @["theme=dark; Path=/", "session=abc; HttpOnly"]
  var cookies: seq[string]
  for name, value in response.headers:
    if name == "set-cookie":
      cookies.add(value)
  doAssert cookies == @["theme=dark; Path=/", "session=abc; HttpOnly"]

  response.setHeader("SET-cookie", "consent=yes; Secure")
  doAssert response.getAllHeaders("set-cookie") == @["consent=yes; Secure"]

block requestHeadersRetainRepeatedValues:
  var headers = initHeaders()
  headers.addHeader("Warning", "199 first warning")
  headers.addHeader("warning", "299 second warning")
  let request = initRequest(HttpMethod.Get, "/", headers)
  doAssert request.headers["WARNING"] == "299 second warning"
  doAssert request.getAllHeaders("Warning") ==
    @["199 first warning", "299 second warning"]

block legacyHeaderTablesRemainAccepted:
  var headers = initTable[string, string]()
  headers["X-Trace"] = "abc"
  let request = initRequest(HttpMethod.Get, "/", headers)
  doAssert request.headers["x-trace"] == "abc"

block typedRouteStatusHelpers:
  let helper = initFastNim(logs = false)
  helper.get("/denied", responses = @[(401, Failure)]):
    unauthorized Failure(detail: "missing credentials")
  let denied = helper.handleSync(initRequest(HttpMethod.Get, "/denied"))
  doAssert denied.status == 401
  doAssert denied.body == """{"detail":"missing credentials"}"""

block returnedSuccessResponse:
  let response = app.handleSync(initRequest(HttpMethod.Get, "/items/return"))
  doAssert response.status == 200
  doAssert response.body == "{\"id\":2}"

block declaredErrorResponse:
  let response = app.handleSync(initRequest(HttpMethod.Post, "/items"))
  doAssert response.status == 400
  doAssert response.body == "{\"detail\":\"name is required\"}"

block decodedJsonBody:
  let response = app.handleSync(
    initRequest(HttpMethod.Post, "/items/from-body", body = "{\"name\":\"Ada\"}")
  )
  doAssert response.status == 201
  doAssert response.body == "{\"id\":3}"

block invalidJsonBody:
  let response =
    app.handleSync(initRequest(HttpMethod.Post, "/items/from-body", body = "not json"))
  doAssert response.status == 400
  doAssert parseJson(response.body) ==
    %*{
      "code": "invalid_request_body",
      "message": "invalid JSON request body",
      "fields": {},
    }

block jsonNameEncodesAndDecodesRequestBodies:
  let helper = initFastNim(logs = false)
  helper.post(
    "/profiles", body = RenamedEnvelope, responses = @[(200, RenamedEnvelope)]
  ):
    ok body

  let response = helper.handleSync(
    initRequest(
      HttpMethod.Post,
      "/profiles",
      body = """{"profiles":[{"display_name":"Ada","age":36}]}""",
    )
  )
  let payload = parseJson(response.body)
  doAssert response.status == 200, response.body
  doAssert payload["profiles"][0]["display_name"].getStr == "Ada"
  doAssert "displayName" notin payload["profiles"][0]

block jsonNameAppliesToTypedResponses:
  let response = respondOk(RenamedProfile(displayName: "Lin", age: 28))
  let payload = parseJson(response.body)
  doAssert payload["display_name"].getStr == "Lin"
  doAssert "displayName" notin payload

block jsonNameRejectsAmbiguousInput:
  let helper = initFastNim(logs = false)
  helper.post("/profile", body = RenamedProfile, responses = @[(200, RenamedProfile)]):
    ok body

  let response = helper.handleSync(
    initRequest(
      HttpMethod.Post,
      "/profile",
      body = """{"displayName":"Ada","display_name":"Lin","age":36}""",
    )
  )
  doAssert response.status == 400

block responseFieldsHonorPragmasAndFluentOverrides:
  let message = FilteredMessage(status: "ok", value: vkBool, boolVal: true)

  let defaultPayload = parseJson(respondOk(message).body)
  doAssert "value" notin defaultPayload
  doAssert defaultPayload["boolVal"].getBool

  let included = ok message.include(FilteredMessage.value)
  let includedPayload = parseJson(included.body)
  doAssert includedPayload["value"].getInt == ord(vkBool)

  let overridden = ok message
    .ignore(FilteredMessage.status, FilteredMessage.boolVal)
    .include(FilteredMessage.value, FilteredMessage.status)
  let overriddenPayload = parseJson(overridden.body)
  doAssert overriddenPayload["status"].getStr == "ok"
  doAssert overriddenPayload["value"].getInt == ord(vkBool)
  doAssert "boolVal" notin overriddenPayload

block responseFieldOverridesWorkInTypedRoutes:
  let helper = initFastNim(logs = false)
  helper.get("/filtered", responses = @[(200, FilteredMessage)]):
    let filtered = ok FilteredMessage(status: "ok", value: vkBool, boolVal: true)
      .ignore(FilteredMessage.boolVal)
      .include(FilteredMessage.value)
    return filtered

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/filtered"))
  let payload = parseJson(response.body)
  doAssert response.status == 200
  doAssert payload["value"].getInt == ord(vkBool)
  doAssert "boolVal" notin payload

  let operation = helper.openApiDocument()["paths"]["/filtered"]["get"]
  let schema = operation["responses"]["200"]["content"]["application/json"]["schema"]
  doAssert schema["oneOf"].len == 2
  let boolProperties = schema["oneOf"][0]["properties"]
  doAssert boolProperties["status"]["type"].getStr == "string"
  doAssert boolProperties["value"]["type"].getStr == "integer"
  doAssert "boolVal" notin boolProperties
  doAssert "strVal" notin boolProperties
  let stringProperties = schema["oneOf"][1]["properties"]
  doAssert "boolVal" notin stringProperties
  doAssert stringProperties["strVal"]["type"].getStr == "string"

type Member = object
  name: string
  age: int

block jsonHelperSerializesValues:
  let helper = initFastNim(logs = false)
  helper.get("/members"):
    let users = @[Member(name: "Alice", age: 30), Member(name: "Bob", age: 25)]
    json users

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/members"))
  doAssert response.status == 200
  doAssert response.body == """[{"name":"Alice","age":30},{"name":"Bob","age":25}]"""
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block jsonHelperInTypedRoute:
  let helper = initFastNim(logs = false)
  helper.get("/members", responses = @[(200, seq[Member])]):
    let users = @[Member(name: "Alice", age: 30)]
    json users

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/members"))
  doAssert response.status == 200
  doAssert response.body == """[{"name":"Alice","age":30}]"""

block jsonHelperCustomStatus:
  let helper = initFastNim(logs = false)
  helper.get("/created"):
    json(statusCreated, %*{"name": "Ada", "age": 36})

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/created"))
  doAssert response.status == 201
  doAssert response.body == """{"name":"Ada","age":36}"""

block jsonHelperPairsBecomeObject:
  let helper = initFastNim(logs = false)
  helper.get("/items/{itemId}"):
    let itemId = request.pathParam("itemId")
    let page = request.queryParam("page", "1")
    json {"itemId": itemId, "page": page}

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/items/42?page=3"))
  doAssert response.status == 200
  doAssert response.body == """{"itemId":"42","page":"3"}"""
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block jsonHelperIntPairsBecomeObject:
  let helper = initFastNim(logs = false)
  helper.get("/count"):
    json {"total": 3}

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/count"))
  doAssert response.body == """{"total":3}"""

block jsonHelperTableBecomesObject:
  let helper = initFastNim(logs = false)
  helper.get("/tbl"):
    json {"a": "x"}.toTable

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/tbl"))
  doAssert response.body == """{"a":"x"}"""

block jsonHelperLeavesArraysAlone:
  let helper = initFastNim(logs = false)
  helper.get("/members"):
    let users = @[Member(name: "Alice", age: 30)]
    json users

  let response = helper.handleSync(initRequest(HttpMethod.Get, "/members"))
  doAssert response.body == """[{"name":"Alice","age":30}]"""
