## Run with: ``nim c -r --path:src examples/validation.nim``
##
## Demonstrates FastNim's validation layers:
##
## - field constraints declared with pragmas;
## - automatic validation for typed route bodies;
## - nested object and sequence validation;
## - JSON field names in validation locations;
## - custom cross-field validation through ``validator = ...``;
## - explicit query validation; and
## - the same typed-body syntax on POST and PATCH routes.
##
## A malformed or incorrectly shaped JSON body returns 400. Constraint
## failures return 422 with every error preserved:
##
## ```
## {
##   "code": "validation_failed",
##   "message": "validation failed",
##   "errors": [
##     {
##       "location": ["body", "contact", "email"],
##       "code": "email",
##       "message": "must be a valid email address"
##     }
##   ]
## }
## ```
##
# Try:
##
## ```
# curl -X POST http://127.0.0.1:8000/products \
#   -d '{"sku":"W-1","display_name":"Widget","price":9.99,
#        "sale_price":7.99,"quantity":3,"weight":1.2,"tags":["tools"],
#        "contact":{"email":"shop@example.com"},
#        "reviewers":[{"contact":{"email":"ada@example.com"}}]}'
#
## curl -X POST http://127.0.0.1:8000/products \
##   -d '{"sku":"","display_name":"","price":0,"sale_price":10,
##        "quantity":101,"weight":0,"tags":[],
##        "contact":{"email":"bad"},"reviewers":[]}'
##
## curl 'http://127.0.0.1:8000/products?page=0&limit=200&sort=unknown'
##
## curl -X PATCH http://127.0.0.1:8000/orders/42 \
##   -d '{"fromStatus":"pending","toStatus":"shipped"}'
##
## 
## curl -X POST http://127.0.0.1:8000/products -d 'not json'
## ```
##
## Inspect ``http://127.0.0.1:8000/docs`` for generated constraints and the
## automatic 400/422 response schemas.

import strutils

import fastnim

type
  Contact = object
    email* {.email.}: string

  Reviewer = object
    contact*: Contact

  CreateProduct = object
    sku* {.nonEmpty.}: string
    name* {.minLen: 2, maxLen: 80, jsonName: "display_name".}: string
    price* {.gt: 0, lt: 1000000.}: float
    salePrice* {.ge: 0, le: 999999, jsonName: "sale_price".}: float
    quantity* {.ge: 1, le: 100.}: int
    weight* {.positive.}: float
    tags* {.minLen: 1, maxLen: 5.}: seq[string]
    contact*: Contact
    reviewers* {.maxLen: 3.}: seq[Reviewer]

  Product = object
    id*: int
    sku*, name*: string
    price*, salePrice*: float
    quantity*: int

  OrderState {.pure.} = enum
    pending = "pending"
    paid = "paid"
    shipped = "shipped"
    delivered = "delivered"
    cancelled = "cancelled"

  StatusChange = object
    fromStatus*: OrderState
    toStatus*: OrderState

  OrderStatus = object
    id*: string
    status*: OrderState

  ProductOut = object
    page: int
    limit: int
    sort: string
    products: seq[Product]

const AllowedTransitions = transitions(OrderState):
  OrderState.pending.to OrderState.paid
  OrderState.paid.to OrderState.shipped
  OrderState.shipped.to OrderState.delivered
  OrderState.pending.to OrderState.cancelled
  OrderState.paid.to OrderState.cancelled

proc validateCreateProduct(value: CreateProduct): ValidationResult =
  ## Adds a cross-field rule to the field constraints run by the route.
  result = initValidationResult()
  if value.salePrice > value.price:
    result.addError(
      CreateProduct.fieldName(salePrice),
      "invalid_discount",
      "must be less than or equal to price",
    )

proc validateStatusChange(value: StatusChange): ValidationResult =
  ## Validates a domain transition that cannot be expressed by field pragmas.
  result = initValidationResult()
  result.checkTransition(
    StatusChange.fieldName(toStatus),
    value.fromStatus,
    value.toStatus,
    AllowedTransitions,
  )

proc queryInt(
    request: Request, validation: var ValidationResult, name: string, default: int
): int =
  ## Extracts one integer query parameter and records conversion failures.
  let raw = request.queryParam(name, $default)
  try:
    result = raw.parseInt()
  except ValueError:
    validation.addError(name, "integer", "must be an integer")
    result = default

let app = initFastNim()
var productsDb: seq[Product] = @[]

app.post(
  "/products",
  body = CreateProduct,
  validator = validateCreateProduct,
  responses = @[(201, Product)],
  summary = "Create a validated product",
  tags = @["validation"],
):
  let product = Product(
    id: 1,
    sku: body.sku,
    name: body.name,
    price: body.price,
    salePrice: body.salePrice,
    quantity: body.quantity,
  )

  {.gcsafe.}:
    productsDb.add product

  created product

app.get("/products", responses = @[(200, ProductOut)]):
  var validation = initValidationResult()

  let page = request.queryInt(validation, "page", 1)
  let limit = request.queryInt(validation, "limit", 20)
  let sort = request.queryParam("sort", "name")

  validation.mergeErrors(validatePagination(page, limit))
  validation.checkAllowed("sort", sort, ["name", "price"])
  if not validation.isValid():
    return validationResponse(validation, source = "query")

  let product = ProductOut(page: page, limit: limit, sort: sort, products: productsDb)
  ok product

app.patch(
  "/orders/{id}",
  body = StatusChange,
  validator = validateStatusChange,
  responses = @[(200, OrderStatus)],
  summary = "Apply a validated order transition",
  tags = @["validation"],
):
  ok OrderStatus(id: request.pathParam("id"), status: body.toStatus)

when isMainModule:
  let server = app.serve(port = 8000)
  echo "Listening at http://127.0.0.1:8000"
  echo "Swagger UI: http://127.0.0.1:8000/docs"
  waitFor server.join()
