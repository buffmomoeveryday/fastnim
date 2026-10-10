import std/assertions

import fastnim

type
  Success = object
    id: int

  Failure = object
    detail: string

  CreateItem = object
    name: string

let app = initFastNim()
app.get("/items", responses = @[(200, Success), (400, Failure)]):
  ok Success(id: 1)

app.get("/items/return", responses = @[(200, Success)]):
  return (ok, Success(id: 2))

app.post("/items", responses = @[(201, Success), (400, Failure)]):
  badRequest Failure(detail: "name is required")

app.post("/items/from-body", body = CreateItem, responses = @[(201, Success)]):
  created Success(id: body.name.len)

block declaredSuccessResponse:
  let response = app.handle(initRequest(HttpMethod.Get, "/items"))
  doAssert response.status == 200
  doAssert response.body == "{\"id\":1}"

block returnedSuccessResponse:
  let response = app.handle(initRequest(HttpMethod.Get, "/items/return"))
  doAssert response.status == 200
  doAssert response.body == "{\"id\":2}"

block declaredErrorResponse:
  let response = app.handle(initRequest(HttpMethod.Post, "/items"))
  doAssert response.status == 400
  doAssert response.body == "{\"detail\":\"name is required\"}"

block decodedJsonBody:
  let response = app.handle(
    initRequest(HttpMethod.Post, "/items/from-body", body = "{\"name\":\"Ada\"}")
  )
  doAssert response.status == 201
  doAssert response.body == "{\"id\":3}"

block invalidJsonBody:
  let response =
    app.handle(initRequest(HttpMethod.Post, "/items/from-body", body = "not json"))
  doAssert response.status == 400
  doAssert response.body == "{\"detail\":\"invalid JSON request body\"}"

type
  Member = object
    name: string
    age: int

block jsonHelperSerializesValues:
  let helper = initFastNim(logs = false)
  helper.get("/members"):
    let users = @[Member(name: "Alice", age: 30), Member(name: "Bob", age: 25)]
    json users

  let response = helper.handle(initRequest(HttpMethod.Get, "/members"))
  doAssert response.status == 200
  doAssert response.body == """[{"name":"Alice","age":30},{"name":"Bob","age":25}]"""
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block jsonHelperInTypedRoute:
  let helper = initFastNim(logs = false)
  helper.get("/members", responses = @[(200, seq[Member])]):
    let users = @[Member(name: "Alice", age: 30)]
    json users

  let response = helper.handle(initRequest(HttpMethod.Get, "/members"))
  doAssert response.status == 200
  doAssert response.body == """[{"name":"Alice","age":30}]"""

block jsonHelperCustomStatus:
  let helper = initFastNim(logs = false)
  helper.get("/created"):
    json(Member(name: "Ada", age: 36), 201)

  let response = helper.handle(initRequest(HttpMethod.Get, "/created"))
  doAssert response.status == 201
  doAssert response.body == """{"name":"Ada","age":36}"""

block jsonHelperPairsBecomeObject:
  let helper = initFastNim(logs = false)
  helper.get("/items/{itemId}"):
    let itemId = request.pathParam("itemId")
    let page = request.queryParam("page", "1")
    json {"itemId": itemId, "page": page}

  let response = helper.handle(initRequest(HttpMethod.Get, "/items/42?page=3"))
  doAssert response.status == 200
  doAssert response.body == """{"itemId":"42","page":"3"}"""
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"

block jsonHelperIntPairsBecomeObject:
  let helper = initFastNim(logs = false)
  helper.get("/count"):
    json {"total": 3}

  let response = helper.handle(initRequest(HttpMethod.Get, "/count"))
  doAssert response.body == """{"total":3}"""

block jsonHelperTableBecomesObject:
  let helper = initFastNim(logs = false)
  helper.get("/tbl"):
    json {"a": "x"}.toTable

  let response = helper.handle(initRequest(HttpMethod.Get, "/tbl"))
  doAssert response.body == """{"a":"x"}"""

block jsonHelperLeavesArraysAlone:
  let helper = initFastNim(logs = false)
  helper.get("/members"):
    let users = @[Member(name: "Alice", age: 30)]
    json users

  let response = helper.handle(initRequest(HttpMethod.Get, "/members"))
  doAssert response.body == """[{"name":"Alice","age":30}]"""
