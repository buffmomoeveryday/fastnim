import std/[assertions, json, options, strutils, tables]

import fastnim
import fastnim/orm

type
  Item = object
    id: int
    name {.jsonName: "display_name".}: string

  CreateItem = object
    name {.minLen: 2, maxLen: 80, nonEmpty.}: string

  OptionalItem = object
    note: Option[string]

  ItemDetails = ref object
    label {.jsonName: "display_label", minLen: 1.}: string

  ReferencedItem = object
    details: ItemDetails

  BookRef = object
    authorId: UUID
    publisherId: Option[UUID]

let app = initFastNim(
  logs = false, openApi = initOpenApiSettings(title = "Inventory", version = "2.0.0")
)

app.get("/items/{itemId}", responses = @[(200, Item)]):
  ok Item(id: 1, name: request.pathParam("itemId"))

app.documentRoute(
  HttpMethod.Get,
  "/items/{itemId}",
  initOpenApiRoute(summary = "Get one item", tags = @["items"]),
)

app.post(
  "/items",
  body = CreateItem,
  responses = @[(201, Item)],
  tags = @["items"],
  summary = "Create an item",
):
  created Item(id: 1, name: body.name)

app.put("/items/{itemId}", body = CreateItem, responses = @[(200, Item)]):
  ok Item(id: 1, name: body.name)

app.patch("/items/{itemId}", body = CreateItem, responses = @[(200, Item)]):
  ok Item(id: 1, name: body.name)

app.get(
  "/tagged",
  responses = @[(200, Item)],
  tags = @["items", "admin"],
  description = "Returns a tagged item.",
  summary = "Tagged item",
  operationId = "getTaggedItem",
):
  ok Item(id: 1, name: "tagged")

block generatedDocument:
  let document = app.openApiDocument()
  doAssert document["openapi"].getStr == "3.1.0"
  doAssert document["info"]["title"].getStr == "Inventory"
  doAssert document["paths"]["/items/{itemId}"]["get"]["summary"].getStr ==
    "Get one item"
  doAssert document["paths"]["/items/{itemId}"]["get"]["parameters"][0]["name"].getStr ==
    "itemId"
  let itemResponse = document["paths"]["/items/{itemId}"]["get"]["responses"]["200"]
  let itemSchema = itemResponse["content"]["application/json"]["schema"]
  doAssert itemSchema["properties"]["id"]["type"].getStr == "integer"
  doAssert itemSchema["properties"]["display_name"]["type"].getStr == "string"
  doAssert "name" notin itemSchema["properties"]
  let requestContent = document["paths"]["/items"]["post"]["requestBody"]["content"]
  let requestSchema = requestContent["application/json"]["schema"]
  doAssert requestSchema["properties"]["name"]["type"].getStr == "string"
  doAssert requestSchema["properties"]["name"]["minLength"].getInt == 2
  doAssert requestSchema["properties"]["name"]["maxLength"].getInt == 80
  let optionalSchema = openApiSchema(OptionalItem)
  doAssert optionalSchema["properties"]["note"]["nullable"].getBool()
  doAssert optionalSchema["required"].len == 0
  let referencedSchema = openApiSchema(ReferencedItem)
  let detailsSchema = referencedSchema["properties"]["details"]
  doAssert detailsSchema["type"].getStr == "object"
  doAssert detailsSchema["properties"]["display_label"]["minLength"].getInt == 1
  let bookSchema = openApiSchema(BookRef)
  doAssert bookSchema["properties"]["authorId"]["type"].getStr == "string"
  doAssert bookSchema["properties"]["authorId"]["format"].getStr == "uuid"
  doAssert bookSchema["properties"]["publisherId"]["type"].getStr == "string"
  doAssert bookSchema["properties"]["publisherId"]["format"].getStr == "uuid"
  doAssert bookSchema["properties"]["publisherId"]["nullable"].getBool()
  doAssert "bytes" notin bookSchema["properties"]
  doAssert "400" in document["paths"]["/items"]["post"]["responses"]
  doAssert "422" in document["paths"]["/items"]["post"]["responses"]
  doAssert "put" in document["paths"]["/items/{itemId}"]
  doAssert "patch" in document["paths"]["/items/{itemId}"]
  let patchOperation = document["paths"]["/items/{itemId}"]["patch"]
  let patchSchema =
    patchOperation["requestBody"]["content"]["application/json"]["schema"]
  doAssert patchSchema["properties"]["name"]["minLength"].getInt == 2
  doAssert "422" in patchOperation["responses"]
  doAssert document["paths"]["/items"]["post"]["tags"][0].getStr == "items"
  let tagged = document["paths"]["/tagged"]["get"]
  doAssert tagged["tags"][0].getStr == "items"
  doAssert tagged["tags"][1].getStr == "admin"
  doAssert tagged["description"].getStr == "Returns a tagged item."
  doAssert tagged["operationId"].getStr == "getTaggedItem"

block builtInEndpoints:
  let schema = app.handleSync(initRequest(HttpMethod.Get, "/openapi.json"))
  doAssert schema.status == 200
  doAssert schema.headers["content-type"] == "application/json; charset=utf-8"
  let docs = app.handleSync(initRequest(HttpMethod.Get, "/docs"))
  doAssert docs.status == 200
  doAssert docs.headers["content-type"] == "text/html; charset=utf-8"
  doAssert "swagger-ui" in docs.body

block disabledEndpoints:
  let disabled =
    initFastNim(logs = false, openApi = initOpenApiSettings(enabled = false))
  doAssert disabled.handleSync(initRequest(HttpMethod.Get, "/openapi.json")).status ==
    404
