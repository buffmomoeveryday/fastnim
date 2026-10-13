import std/[json, options, unittest]

import fastnim
import fastnim/testing

type
  Category = enum
    books = "books"
    games = "games"

  SortField = enum
    price = "price"
    name = "name"

  SearchQuery = object
    page {.ge: 1.}: int = 1
    limit {.ge: 1, le: 100.}: int = 20
    minPrice {.jsonName: "min_price".}: Option[int]
    category: Category
    sort: SortField
    available: bool = false
    q: string = ""
    tags {.jsonName: "tag".}: seq[string]

  RequiredQuery = object
    value: int

  IdQuery = object
    ids {.jsonName: "id".}: seq[int]

  WindowQuery = object
    start: int = 0
    finish: int = 10
    cursor: Option[int] = some(1)

proc validateWindow(query: WindowQuery): ValidationResult =
  result = initValidationResult()
  if query.finish < query.start:
    result.addError("finish", "range", "must be greater than or equal to start")

proc fieldMessage(response: Response, location: string): string =
  response.json()["fields"][location].getStr()

proc testApp(): TestClient =
  let api = initFastNim(logs = false)
  api.get("/search", queryParams = SearchQuery, responses = @[(200, void)]):
    json(
      %*{
        "page": queryParams.page,
        "limit": queryParams.limit,
        "min_price":
          (if queryParams.minPrice.isSome():
            %queryParams.minPrice.get()
          else:
            newJNull()),
        "category": $queryParams.category,
        "sort": $queryParams.sort,
        "available": queryParams.available,
        "q": queryParams.q,
        "tags": queryParams.tags,
      }
    )
  api.get("/required", queryParams = RequiredQuery, responses = @[(200, void)]):
    json(%*{"value": queryParams.value})
  api.get("/ids", queryParams = IdQuery, responses = @[(200, void)]):
    json(%*{"ids": queryParams.ids})
  api.get(
    "/window",
    queryParams = WindowQuery,
    validator = validateWindow,
    responses = @[(200, void)],
  ):
    json(
      %*{
        "cursor": queryParams.cursor.get(),
        "start": queryParams.start,
        "finish": queryParams.finish,
      }
    )
  initTestClient(api)

suite "Typed query parameters":
  test "parses the complete product search query":
    let response = testApp().get(
      "/search?page=2&limit=20&min_price=1000&category=books&sort=price"
    )
    check response.status == 200
    check response.json() == %*{
      "page": 2,
      "limit": 20,
      "min_price": 1000,
      "category": "books",
      "sort": "price",
      "available": false,
      "q": "",
      "tags": [],
    }

  test "uses defaults and represents missing optional values":
    let response = testApp().get("/search?category=books&sort=name")
    check response.status == 200
    check response.json()["page"].getInt() == 1
    check response.json()["limit"].getInt() == 20
    check response.json()["min_price"].kind == JNull

  test "extracts decoded string values including an explicit empty string":
    let decoded = testApp().get("/search?category=books&sort=name&q=nim+lang")
    check decoded.status == 200
    check decoded.json()["q"].getStr() == "nim lang"

    let empty = testApp().get("/search?category=books&sort=name&q=")
    check empty.status == 200
    check empty.json()["q"].getStr() == ""

  test "parses documented boolean spellings without case sensitivity":
    for spelling in ["true", "YES", "1", "On", "y"]:
      let response = testApp().get(
        "/search?category=books&sort=price&available=" & spelling
      )
      check response.status == 200
      check response.json()["available"].getBool()
    for spelling in ["false", "NO", "0", "Off", "n"]:
      let response = testApp().get(
        "/search?category=books&sort=price&available=" & spelling
      )
      check response.status == 200
      check not response.json()["available"].getBool()

  test "collects repeated parameters in URL order":
    let response = testApp().get(
      "/search?category=books&sort=price&tag=nim&tag=web"
    )
    check response.status == 200
    check response.json()["tags"] == %*["nim", "web"]

  test "does not split comma-separated values":
    let response = testApp().get(
      "/search?category=books&sort=price&tag=nim,web"
    )
    check response.status == 200
    check response.json()["tags"] == %*["nim,web"]

  test "preserves repeated decoded values and legacy last-value lookup":
    let request = initRequest(HttpMethod.Get, "/?tag=nim%20lang&tag=async+io")
    check request.queryParamValues("tag") == @["nim lang", "async io"]
    check request.queryParam("tag") == "async io"

  test "returns a structured 400 for a missing required value":
    let response = testApp().get("/required")
    check response.status == 400
    check response.json()["code"].getStr() == "invalid_query_parameters"
    check response.fieldMessage("query.value") == "is required"

  test "returns structured 400 errors for invalid scalar values":
    let invalidInt = testApp().get("/required?value=two")
    check invalidInt.status == 400
    check invalidInt.fieldMessage("query.value") == "must be an integer"

    let invalidBool = testApp().get(
      "/search?category=books&sort=price&available=sometimes"
    )
    check invalidBool.status == 400
    check invalidBool.fieldMessage("query.available") == "must be a boolean"

    let invalidEnum = testApp().get("/search?category=Books&sort=price")
    check invalidEnum.status == 400
    check invalidEnum.fieldMessage("query.category") == "must be a valid enum value"

    let overflowingInt = testApp().get("/required?value=999999999999999999999999")
    check overflowingInt.status == 400
    check overflowingInt.fieldMessage("query.value") == "must be an integer"

  test "reports the index of an invalid repeated value":
    let response = testApp().get("/ids?id=1&id=bad&id=3")
    check response.status == 400
    check response.fieldMessage("query.id.1") == "must be an integer"

  test "rejects pagination values outside configured bounds":
    let badPage = testApp().get("/search?page=0&category=books&sort=price")
    check badPage.status == 422
    check "query.page" in badPage.json()["fields"]

    let badLimit = testApp().get("/search?limit=101&category=books&sort=price")
    check badLimit.status == 422
    check "query.limit" in badLimit.json()["fields"]

  test "preserves field defaults and runs a custom query validator":
    let defaulted = testApp().get("/window")
    check defaulted.status == 200
    check defaulted.json()["cursor"].getInt() == 1

    let invalid = testApp().get("/window?start=10&finish=5")
    check invalid.status == 422
    check invalid.fieldMessage("query.finish") ==
      "must be greater than or equal to start"

  test "documents query model fields as OpenAPI parameters":
    let api = initFastNim(logs = false)
    api.get("/search", queryParams = SearchQuery, responses = @[(200, void)]):
      json(%*{})
    let parameters = api.openApiDocument()["paths"]["/search"]["get"]["parameters"]
    check parameters.len == 8
    check parameters[0]["name"].getStr() == "page"
    check not parameters[0]["required"].getBool()
    check parameters[1]["schema"]["maximum"].getInt() == 100
    check parameters[2]["name"].getStr() == "min_price"
    check not parameters[2]["required"].getBool()
    check parameters[3]["name"].getStr() == "category"
    check parameters[3]["required"].getBool()
    let errorSchema =
      api.openApiDocument()["paths"]["/search"]["get"]["responses"]["400"][
        "content"
      ]["application/json"]["schema"]
    check errorSchema["properties"]["code"]["type"].getStr() == "string"
    check errorSchema["properties"]["message"]["type"].getStr() == "string"
    check errorSchema["properties"]["fields"]["type"].getStr() == "object"
    check parameters[7]["schema"]["type"].getStr() == "array"
