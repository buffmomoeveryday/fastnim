# Validation

FastNim separates input parsing from value validation:

- malformed JSON, incorrect JSON types, and invalid query values are parsing
  failures and return `400`;
- successfully parsed values that violate constraints return `422`;
- validators collect every detected error instead of stopping at the first
  failure.

Import the public API with:

```nim
import std/options

import fastnim
```

## Field constraints

Declare constraints directly on object fields. Typed routes run these
constraints automatically before entering the handler.

```nim
type CreateProduct = object
  sku {.nonEmpty.}: string
  name {.minLen: 2, maxLen: 80.}: string
  email {.email.}: string
  price {.gt: 0, lt: 1_000_000.}: float
  quantity {.ge: 1, le: 100.}: int
  tags {.minLen: 1, maxLen: 5.}: seq[string]
```

The available pragmas are:

| Pragma | Supported fields | Rule | Error code |
| --- | --- | --- | --- |
| `{.nonEmpty.}` | `string` | Length must be greater than zero | `non_empty` |
| `{.email.}` | `string` | Must have FastNim's basic email shape | `email` |
| `{.positive.}` | Numeric | Must be greater than zero | `positive` |
| `{.minValue: n.}` | Integer | Value must be at least `n` | `out_of_range` |
| `{.maxValue: n.}` | Integer | Value must be at most `n` | `out_of_range` |
| `{.minLen: n.}` | `string`, `seq`, `array` | Length must be at least `n` | `min_length` |
| `{.maxLen: n.}` | `string`, `seq`, `array` | Length must be at most `n` | `max_length` |
| `{.gt: n.}` | Numeric | Value must be greater than `n` | `greater_than` |
| `{.ge: n.}` | Numeric | Value must be greater than or equal to `n` | `greater_than_or_equal` |
| `{.lt: n.}` | Numeric | Value must be less than `n` | `less_than` |
| `{.le: n.}` | Numeric | Value must be less than or equal to `n` | `less_than_or_equal` |

Applying a pragma to an incompatible field type produces a compile-time error.
Numeric validation also rejects `NaN` and positive or negative infinity with
the `finite_number` code.

The email check is intentionally practical rather than RFC-complete. It
requires one `@`, non-empty local and domain parts, no spaces, and a dotted
domain without empty labels. Use a dedicated email library when exact mailbox
validation is required.

## Typed request bodies

`POST`, `PUT`, and `PATCH` routes with `body = Model` parse JSON and validate
the model automatically:

```nim
type CreateProduct = object
  name {.nonEmpty, minLen: 2.}: string
  price {.positive.}: float

type Product = object
  id: int
  name: string
  price: float

app.post(
  "/products",
  body = CreateProduct,
  responses = @[(201, Product)],
):
  created Product(id: 1, name: body.name, price: body.price)
```

The handler only runs after parsing and validation succeed. Invalid JSON or a
wrong JSON shape returns:

```json
{
  "code": "invalid_request_body",
  "message": "invalid JSON request body",
  "fields": {}
}
```

with status `400`. Constraint failures return the structured `422` envelope
described below.

## Typed query parameters

A GET route can parse and validate an object declared with `queryParams`:

```nim
type
  SortField = enum
    name = "name"
    price = "price"

  ProductQueryParams = object
    page {.ge: 1.}: int = 1
    limit {.ge: 1, le: 100.}: int = 20
    sort: SortField = SortField.name
    minPrice {.jsonName: "min_price".}: Option[int]
    tags {.jsonName: "tag".}: seq[string]

app.get(
  "/products",
  queryParams = ProductQueryParams,
  responses = @[(200, ProductList)],
):
  ok findProducts(
    page = queryParams.page,
    limit = queryParams.limit,
    sort = queryParams.sort,
    minPrice = queryParams.minPrice,
    tags = queryParams.tags,
  )
```

Query model rules:

- a scalar field without an initializer is required;
- an initializer is the default used when the parameter is absent;
- a missing `Option[T]` becomes `none(T)` unless it has an initializer;
- a missing `seq[T]` becomes an empty sequence unless it has an initializer;
- `jsonName` changes the external parameter name;
- scalar duplicates use the final value;
- sequences consume repeated names in URL order;
- comma-separated values are not split.

Supported query scalar types are `string`, `int`, `bool`, and enums.
`Option[T]` and `seq[T]` wrap those scalar types. Boolean parsing is ASCII
case-insensitive and accepts `true/false`, `1/0`, `yes/no`, `on/off`, and
`y/n`. Enum values match their `$` representation exactly and are
case-sensitive.

Missing required query values and malformed integers, booleans, or enums
return a structured `400`. Field constraints run after parsing and return
`422` when they fail.

For dynamic parameter names or custom control flow, use the lower-level
extractors with a shared parsing result:

```nim
var parsing = initValidationResult()
let page = queryParam[int](request, "page", parsing, default = 1)
let active = queryParam[bool](request, "active", parsing, default = true)
let states = queryParam[seq[OrderState]](request, "state", parsing)

if not parsing.isValid():
  return queryParsingResponse(parsing)
```

The overload without `default` treats scalar values as required. Missing
`Option[T]` and `seq[T]` values still produce `none(T)` and an empty sequence.

## Typed forms

Use `form = Model` for `application/x-www-form-urlencoded` input:

```nim
type LoginForm = object
  email {.email.}: string
  remember: Option[bool]

app.post("/login", form = LoginForm, responses = @[(200, LoginResult)]):
  ok login(form.email, form.remember)
```

Form fields support strings, booleans, numeric types, enums, and optional
forms of those types. `jsonName` controls the external form field name.
Malformed values or missing required fields return `400`; successfully parsed
values that fail constraints return `422` with locations beginning in
`"form"`.

## Typed multipart

Use `multipart = Model` for `multipart/form-data` requests that mix ordinary
fields with file uploads. The decoded model is available as `multipart` and
receives the same field-pragma validation as JSON bodies:

```nim
type
  CategoryInput = object
    name {.nonEmpty.}: string

  CreateBook = object
    title {.nonEmpty.}: string
    category: CategoryInput
    cover* {.
      upload(
        contentTypes = ["image/jpeg", "image/png"],
        maxRequestSize = 6.MB,
        maxFileSize = 5.MB,
      )
    .}: UploadedFile

app.post("/books", multipart = CreateBook, responses = @[(201, Book)]):
  created saveBook(multipart)
```

Size limits accept binary helpers such as `200.KB`, `5.MB`, or `1.GiB`
(`1.MB == 1_048_576`). `KiB` / `MiB` / `GiB` are the IEC names; `KB` / `MB` /
`GB` are aliases for the same values.

Send scalars and enums as ordinary form parts. Send nested objects and
collections as JSON-valued parts. Direct `UploadedFile` fields use their
`upload` pragma for MIME allowlists and size limits. JSON `body = Model`
routes reject models that contain `UploadedFile` fields at compile time; use
`multipart = Model` instead.

Parsing failures return `400` (or `413`/`415` for size and content-type
limits). Constraint failures return `422` with locations beginning in
`"multipart"`. Failed requests remove files already written for that upload.
See `examples/mixed_multipart.nim` for a runnable endpoint.

## Nested values and field names

`validateModel` recursively validates nested objects, non-nil references,
present `Option` values, sequences, and arrays. Sequence and array indexes are
included in error locations:

```nim
type
  Contact = object
    email {.email.}: string

  Reviewer = object
    contact: Contact

  Submission = object
    reviewers {.maxLen: 3.}: seq[Reviewer]
```

An invalid second reviewer email has this location:

```json
["body", "reviewers", "1", "contact", "email"]
```

Use `jsonName` to keep locations aligned with the wire format:

```nim
type Product = object
  displayName {.jsonName: "display_name", nonEmpty.}: string
```

The corresponding body error location is `['body', 'display_name']` in
conceptual notation. `Model.fieldName(field)` returns the effective name for
custom validators without repeating the string:

```nim
result.addError(
  Product.fieldName(displayName),
  "reserved_name",
  "must not use a reserved name",
)
```

## Custom validators

A custom validator receives the parsed model and returns `ValidationResult`.
Pass it with `validator = ...`; FastNim merges its errors with the field-pragmas
errors.

```nim
type Discount = object
  price {.positive.}: float
  salePrice {.ge: 0.}: float

proc validateDiscount(value: Discount): ValidationResult =
  result = initValidationResult()
  if value.salePrice > value.price:
    result.addError(
      Discount.fieldName(salePrice),
      "invalid_discount",
      "must be less than or equal to price",
    )

app.post(
  "/discounts",
  body = Discount,
  validator = validateDiscount,
  responses = @[(201, Discount)],
):
  created body
```

GET query models accept the same option:

```nim
proc validateWindow(value: WindowQuery): ValidationResult =
  result = initValidationResult()
  if value.finish < value.start:
    result.addError("finish", "range", "must not precede start")

app.get(
  "/events",
  queryParams = WindowQuery,
  validator = validateWindow,
  responses = @[(200, EventList)],
):
  ok findEvents(queryParams)
```

## Validation results

Create and compose validation results with:

```nim
var validation = initValidationResult()
validation.addError("name", "reserved", "is reserved")
validation.addError(["items", "2", "sku"], "unknown", "does not exist")
validation.mergeErrors(validateInventory(order))

if not validation.isValid():
  return validationResponse(validation)
```

`ValidationResult` contains a sequence of `FieldError` values. Each
`FieldError` has:

- `location: seq[string]` — the path below the request source;
- `code: string` — a stable machine-readable identifier;
- `message: string` — a human-readable explanation.

`withPrefix` returns a copy with additional leading location components, and
`FieldError.field` returns the final location component.

## Manual checks

The following helpers append an error to an existing `ValidationResult`:

| Helper | Behavior | Error code |
| --- | --- | --- |
| `checkNonEmpty` | Rejects an empty string | `non_empty` |
| `checkEmail` | Applies FastNim's basic email check | `email` |
| `checkPositive` | Requires a finite number greater than zero | `positive` or `finite_number` |
| `checkLengthAtLeast` | Requires a minimum string/sequence/array length | `min_length` |
| `checkLengthAtMost` | Requires a maximum string/sequence/array length | `max_length` |
| `checkGreaterThan` | Applies an exclusive numeric lower bound | `greater_than` |
| `checkGreaterOrEqual` | Applies an inclusive numeric lower bound | `greater_than_or_equal` |
| `checkLessThan` | Applies an exclusive numeric upper bound | `less_than` |
| `checkLessOrEqual` | Applies an inclusive numeric upper bound | `less_than_or_equal` |
| `checkAtLeast` | Applies a same-type inclusive lower bound | `out_of_range` |
| `checkAtMost` | Applies a same-type inclusive upper bound | `out_of_range` |
| `checkRange` | Applies a same-type inclusive range | `out_of_range` |
| `checkAllowed` | Requires exact membership in an allowed list | `not_allowed` |
| `checkTransition` | Requires an allowed `(from, to)` pair | `invalid_transition` |

`isEmailFormat(value)` exposes the email predicate without adding an error.

For decoded pagination values, `validatePagination(page, limit, maxLimit)`
requires `page >= 1` and `1 <= limit <= maxLimit`. Query model pragmas are
usually more concise:

```nim
type Pagination = object
  page {.ge: 1.}: int = 1
  limit {.ge: 1, le: 100.}: int = 20
```

## State transitions

The `transitions` macro creates a compile-time checked list of enum
transitions:

```nim
type OrderState {.pure.} = enum
  pending = "pending"
  paid = "paid"
  shipped = "shipped"
  cancelled = "cancelled"

const AllowedTransitions = transitions(OrderState):
  OrderState.pending.to OrderState.paid
  OrderState.paid.to OrderState.shipped
  OrderState.pending.to OrderState.cancelled

proc validateStatusChange(value: StatusChange): ValidationResult =
  result = initValidationResult()
  result.checkTransition(
    StatusChange.fieldName(toStatus),
    value.fromStatus,
    value.toStatus,
    AllowedTransitions,
  )
```

Both sides of every transition must belong to the declared enum type.

## Error responses

Constraint failures use status `422` by default:

```json
{
  "code": "validation_failed",
  "message": "validation failed",
  "fields": {
    "body.quantity": "must be greater than or equal to 1"
  }
}
```

Automatic source prefixes are:

- `body` for JSON request bodies;
- `form` for URL-encoded forms;
- `query` for query parameters.

Query parsing errors use status `400` with code
`invalid_query_parameters` and message `invalid query parameters`. Repeated
parameter errors include the zero-based value index, for example `query.id.1`.

For manual response construction:

```nim
return validationResponse(
  validation,
  code = "validation_failed",
  message = "validation failed",
  source = "query",
  status = statusUnprocessableContent,
)
```

`toValidationError` builds the typed `ApiError` without
creating an HTTP response. `queryParsingResponse` creates the standard query
parsing `400` response.

## Manual body validation

Untyped routes can parse and validate a body in one call:

```nim
app.post("/products"):
  let checked = request.validate(CreateProduct)
  if not checked.ok:
    return checked.error.get()

  created saveProduct(checked.value)
```

Pass a custom validator as the third argument when needed:

```nim
let checked = request.validate(Discount, validateDiscount)
```

The lower-level `parseAndValidateBody(request, value, validator)` fills an
existing variable and returns `(ok, error)`. `validateModel(value)` validates
an already parsed object and returns its `ValidationResult`.

## OpenAPI

Validation pragmas are reflected in generated OpenAPI schemas and query
parameters. Numeric bounds become `minimum`, `maximum`,
`exclusiveMinimum`, or `exclusiveMaximum`; length bounds become
`minLength`/`maxLength` for strings and `minItems`/`maxItems` for arrays.
Typed routes also document their automatic `400` and `422` responses.

See `examples/validation.nim` for a runnable example containing typed JSON
bodies, query parameters, nested models, custom rules, and state transitions.
See `examples/mixed_multipart.nim` for validated multipart fields plus a file
upload, including generated OpenAPI `multipart/form-data` schemas.
