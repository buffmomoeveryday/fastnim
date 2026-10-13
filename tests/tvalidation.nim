import std/[json, options, strutils, unittest]

import fastnim
import fastnim/testing

type
  Product = object
    name* {.minLen: 1, maxLen: 40.}: string
    price* {.gt: 0.}: float
    qty* {.ge: 1, le: 100.}: int

  Contact = object
    email* {.email.}: string

  Customer = object
    contact*: Contact

  OptionalCustomer = object
    contact*: Option[Contact]

  Team = object
    contacts*: seq[Contact]

  OrderState {.pure.} = enum
    pending = "pending"
    paid = "paid"
    shipped = "shipped"
    delivered = "delivered"
    cancelled = "cancelled"

  StatusChange = object
    fromStatus*: OrderState
    toStatus*: OrderState

  Renamed = object
    emailAddress* {.email, jsonName: "email".}: string

  LargeIdentifier = object
    id* {.ge: 9007199254740993'i64.}: int64

  ReferencedContact = ref object
    emailAddress* {.email, jsonName: "email".}: string

  CustomerWithReference = object
    contact*: ReferencedContact

  BoundedFloat = object
    value* {.gt: 0, lt: 100.}: float

  NarrowInteger = object
    value* {.ge: 1000.}: int8

  UnsignedInteger = object
    value* {.ge: -1.}: uint

const AllowedTransitions = transitions(OrderState):
  OrderState.pending.to OrderState.paid
  OrderState.paid.to OrderState.shipped
  OrderState.shipped.to OrderState.delivered
  OrderState.pending.to OrderState.cancelled
  OrderState.paid.to OrderState.cancelled

proc validateProduct(value: Product): ValidationResult = validateModel(value)
proc validateCustomer(value: Customer): ValidationResult = validateModel(value)

proc validateStatusChange(value: StatusChange): ValidationResult =
  result = initValidationResult()
  checkTransition(
    result,
    StatusChange.fieldName(toStatus),
    value.fromStatus,
    value.toStatus,
    AllowedTransitions,
  )

proc parseQueryInt(raw: string): int =
  try:
    parseInt(raw)
  except ValueError:
    0

proc fieldMessage(response: Response, location: string): string =
  response.json()["fields"][location].getStr()

proc testApp(): TestClient =
  let api = initFastNim(logs = false)
  api.post("/products"):
    var body: Product
    let checked = parseAndValidateBody(request, body, validateProduct)
    if not checked.ok:
      return checked.error.get()
    json(%*{"name": body.name, "price": body.price, "qty": body.qty})
  api.post("/customers"):
    var body: Customer
    let checked = parseAndValidateBody(request, body, validateCustomer)
    if not checked.ok:
      return checked.error.get()
    json(%*{"email": body.contact.email})
  api.get("/orders"):
    let page = parseQueryInt(request.queryParam("page", "1"))
    let limit = parseQueryInt(request.queryParam("limit", "20"))
    let pagination = validatePagination(page, limit)
    if not pagination.isValid():
      return validationResponse(pagination, source = "query")
    json(%*{"page": page, "limit": limit})
  api.get("/search"):
    let sort = request.queryParam("sort", "price")
    var validation = initValidationResult()
    checkAllowed(validation, "sort", sort, ["price", "name"])
    if not validation.isValid():
      return validationResponse(validation, source = "query")
    json(%*{"sort": sort})
  api.patch("/orders/{id}", proc(request: Request): Response =
    var body: StatusChange
    let checked = parseAndValidateBody(request, body, validateStatusChange)
    if not checked.ok:
      return checked.error.get()
    json(%*{"id": request.pathParam("id"), "toStatus": body.toStatus}))
  api.post("/quick-products"):
    let checked = request.validate(Product)
    if not checked.ok:
      return checked.error.get()
    json(%*{"name": checked.value.name, "qty": checked.value.qty})
  api.post(
    "/typed-products",
    body = Product,
    responses = @[(200, Product)],
  ):
    ok body
  api.post(
    "/typed-transitions",
    body = StatusChange,
    validator = validateStatusChange,
    responses = @[(200, StatusChange)],
  ):
    ok body
  api.put(
    "/typed-products/{id}",
    body = Product,
    responses = @[(200, Product)],
  ):
    ok body
  api.patch(
    "/typed-transitions/{id}",
    body = StatusChange,
    validator = validateStatusChange,
    responses = @[(200, StatusChange)],
  ):
    ok body
  api.post(
    "/teams",
    body = Team,
    responses = @[(200, Team)],
  ):
    ok body
  api.post(
    "/optional-customers",
    body = OptionalCustomer,
    responses = @[(200, OptionalCustomer)],
  ):
    ok body
  api.post(
    "/referenced-customers",
    body = CustomerWithReference,
    responses = @[(200, CustomerWithReference)],
  ):
    ok body
  api.post(
    "/bounded-floats",
    body = BoundedFloat,
    responses = @[(200, BoundedFloat)],
  ):
    ok body
  api.put("/plain-put"):
    json(%*{"method": "put"})
  api.patch("/plain-patch"):
    json(%*{"method": "patch"})
  api.delete("/plain-delete"):
    json(%*{"method": "delete"})
  initTestClient(api)

suite "Validation":
  test "builds type-safe enum transitions":
    check AllowedTransitions == [
      (fromState: OrderState.pending, toState: OrderState.paid),
      (fromState: OrderState.paid, toState: OrderState.shipped),
      (fromState: OrderState.shipped, toState: OrderState.delivered),
      (fromState: OrderState.pending, toState: OrderState.cancelled),
      (fromState: OrderState.paid, toState: OrderState.cancelled),
    ]

  test "resolves checked JSON field names":
    check fieldName(Product, qty) == "qty"
    check fieldName(Renamed, emailAddress) == "email"

  test "accepts a valid product":
    let response = testApp().post(
      "/products", """{"name":"Widget","price":9.99,"qty":3}"""
    )
    check response.status == 200
    check response.json() == %*{"name": "Widget", "price": 9.99, "qty": 3}

  test "rejects an empty product name":
    let response = testApp().post(
      "/products", """{"name":"","price":9.99,"qty":3}"""
    )
    check response.status == 422
    check response.fieldMessage("body.name") == "must contain at least 1 character"

  test "rejects a non-positive price":
    let response = testApp().post(
      "/products", """{"name":"Widget","price":0.0,"qty":3}"""
    )
    check response.status == 422
    check response.fieldMessage("body.price") == "must be greater than 0"

  test "rejects both quantity bounds":
    let low = testApp().post(
      "/products", """{"name":"Widget","price":9.99,"qty":0}"""
    )
    check low.status == 422
    check "body.qty" in low.json()["fields"]
    let high = testApp().post(
      "/products", """{"name":"Widget","price":9.99,"qty":101}"""
    )
    check high.status == 422
    check "body.qty" in high.json()["fields"]

  test "reports nested error locations":
    let response = testApp().post(
      "/customers", """{"contact":{"email":"not-an-email"}}"""
    )
    check response.status == 422
    check response.fieldMessage("body.contact.email") ==
      "must be a valid email address"

  test "accepts nested valid input":
    let response = testApp().post(
      "/customers", """{"contact":{"email":"ada@example.com"}}"""
    )
    check response.status == 200
    check response.json() == %*{"email": "ada@example.com"}

  test "skips absent optional models":
    let response = testApp().post("/optional-customers", "{}")
    check response.status == 200

  test "validates present optional models without exposing Option internals":
    let response = testApp().post(
      "/optional-customers", """{"contact":{"email":"bad"}}"""
    )
    check response.status == 422
    check "body.contact.email" in response.json()["fields"]

  test "validates fields inside referenced models":
    let response = testApp().post(
      "/referenced-customers", """{"contact":{"email":"bad"}}"""
    )
    check response.status == 422
    check "body.contact.email" in response.json()["fields"]

  test "rejects non-finite constrained numbers once":
    let response = testApp().post(
      "/bounded-floats", """{"value":"nan"}"""
    )
    check response.status == 422
    check response.json()["fields"].len == 1
    check "body.value" in response.json()["fields"]

  test "reports nested sequence indexes":
    let response = testApp().post(
      "/teams",
      """{"contacts":[{"email":"ada@example.com"},{"email":"bad"}]}""",
    )
    check response.status == 422
    check "body.contacts.1.email" in response.json()["fields"]

  test "rejects malformed JSON with 400":
    let response = testApp().post("/products", "not json")
    check response.status == 400
    check response.json() == %*{
      "code": "invalid_request_body",
      "message": "invalid JSON request body",
      "fields": {},
    }

  test "rejects wrong JSON types with 400":
    let response = testApp().post(
      "/products", """{"name":"Widget","price":"free","qty":3}"""
    )
    check response.status == 400

  test "uses the standard 422 envelope":
    let response = testApp().post(
      "/products", """{"name":"","price":9.99,"qty":3}"""
    )
    check response.status == 422
    check response.json() == %*{
      "code": "validation_failed",
      "message": "validation failed",
      "fields": {"body.name": "must contain at least 1 character"},
    }

  test "enforces pagination bounds with query locations":
    let ok = testApp().get("/orders?page=2&limit=20")
    check ok.status == 200
    check ok.json() == %*{"page": 2, "limit": 20}
    let badPage = testApp().get("/orders?page=0&limit=20")
    check badPage.status == 422
    check "query.page" in badPage.json()["fields"]
    let badLimit = testApp().get("/orders?page=1&limit=200")
    check badLimit.status == 422
    check "query.limit" in badLimit.json()["fields"]

  test "rejects disallowed sort values":
    check testApp().get("/search?sort=price").status == 200
    let response = testApp().get("/search?sort=weight")
    check response.status == 422
    check "query.sort" in response.json()["fields"]

  test "reports wire names for renamed fields":
    let validation = validateModel(Renamed(emailAddress: "bad"))
    check not validation.isValid()
    check validation.errors[0].location == @["email"]
    check validation.errors[0].code == "email"

  test "collects multiple field errors":
    let validation = validateModel(Product(name: "", price: -1.0, qty: 0))
    check not validation.isValid()
    check validation.errors.len == 3

  test "keeps large integer bounds exact":
    let below = validateModel(LargeIdentifier(id: 9007199254740992'i64))
    check not below.isValid()
    let exact = validateModel(LargeIdentifier(id: 9007199254740993'i64))
    check exact.isValid()

  test "handles bounds outside a narrow integer type without defects":
    let validation = validateModel(NarrowInteger(value: 127'i8))
    check not validation.isValid()
    check validation.errors[0].code == "greater_than_or_equal"

  test "compares unsigned values with negative bounds correctly":
    let validation = validateModel(UnsignedInteger(value: 0'u))
    check validation.isValid()

  test "retains the one-call request helper":
    let ok = testApp().post(
      "/quick-products", """{"name":"Widget","price":9.99,"qty":3}"""
    )
    check ok.status == 200
    let bad = testApp().post(
      "/quick-products", """{"name":"","price":9.99,"qty":3}"""
    )
    check bad.status == 422
    check "body.name" in bad.json()["fields"]

  test "automatically validates typed route bodies":
    let ok = testApp().post(
      "/typed-products", """{"name":"Widget","price":9.99,"qty":3}"""
    )
    check ok.status == 200
    let bad = testApp().post(
      "/typed-products", """{"name":"","price":9.99,"qty":3}"""
    )
    check bad.status == 422
    check "body.name" in bad.json()["fields"]

  test "merges a typed route custom validator":
    let ok = testApp().post(
      "/typed-transitions", """{"fromStatus":"paid","toStatus":"shipped"}"""
    )
    check ok.status == 200
    let bad = testApp().post(
      "/typed-transitions",
      """{"fromStatus":"pending","toStatus":"shipped"}""",
    )
    check bad.status == 422
    check "body.toStatus" in bad.json()["fields"]

  test "rejects unknown enum states as an invalid body":
    let response = testApp().post(
      "/typed-transitions",
      """{"fromStatus":"unknown","toStatus":"paid"}""",
    )
    check response.status == 400

  test "validates typed PUT route bodies":
    let ok = testApp().put(
      "/typed-products/1", """{"name":"Widget","price":9.99,"qty":3}"""
    )
    check ok.status == 200
    let bad = testApp().put(
      "/typed-products/1", """{"name":"","price":9.99,"qty":3}"""
    )
    check bad.status == 422
    check "body.name" in bad.json()["fields"]

  test "merges a typed PATCH route custom validator":
    let ok = testApp().patch(
      "/typed-transitions/1",
      """{"fromStatus":"paid","toStatus":"shipped"}""",
    )
    check ok.status == 200
    let bad = testApp().patch(
      "/typed-transitions/1",
      """{"fromStatus":"pending","toStatus":"shipped"}""",
    )
    check bad.status == 422
    check "body.toStatus" in bad.json()["fields"]

  test "supports plain blocks for mutating methods":
    check testApp().put("/plain-put").json() == %*{"method": "put"}
    check testApp().patch("/plain-patch").json() == %*{"method": "patch"}
    check testApp().delete("/plain-delete").json() == %*{"method": "delete"}
