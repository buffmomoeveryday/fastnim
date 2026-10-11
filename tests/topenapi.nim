import std/[assertions, json, strutils, tables]

import fastnim

type
  Item = object
    id: int
    name {.jsonName: "display_name".}: string

  CreateItem = object
    name: string

let app = initFastNim(
  logs = false,
  openApi = initOpenApiSettings(title = "Inventory", version = "2.0.0"),
)

app.get(
  "/items/{itemId}",
  responses = @[(200, Item)],
):
  ok Item(id: 1, name: request.pathParam("itemId"))

app.documentRoute(
  HttpMethod.Get, "/items/{itemId}",
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
  doAssert document["paths"]["/items/{itemId}"]["get"]["summary"].getStr == "Get one item"
  doAssert document["paths"]["/items/{itemId}"]["get"]["parameters"][0]["name"].getStr == "itemId"
  let itemSchema = document["paths"]["/items/{itemId}"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]
  doAssert itemSchema["properties"]["id"]["type"].getStr == "integer"
  doAssert itemSchema["properties"]["display_name"]["type"].getStr == "string"
  doAssert "name" notin itemSchema["properties"]
  let requestSchema = document["paths"]["/items"]["post"]["requestBody"]["content"]["application/json"]["schema"]
  doAssert requestSchema["properties"]["name"]["type"].getStr == "string"
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
  let disabled = initFastNim(logs = false, openApi = initOpenApiSettings(enabled = false))
  doAssert disabled.handleSync(initRequest(HttpMethod.Get, "/openapi.json")).status == 404
