import std/[json, strutils, tables, unittest]

import fastnim
import fastnim/testing

type Item = object
  id: int
  name: string

proc testApp(): TestClient =
  let api = initFastNim(logs = false)
  api.get("/"):
    %*{"msg": "Hello World"}
  api.get("/items/{id}"):
    %*{"id": request.pathParam("id"), "page": request.queryParam("page", "1")}
  api.post("/items", body = Item, responses = @[(201, Item)]):
    created body
  api.put("/items/{id}", proc(request: Request): Response {.raises: [].} =
    json(%*{"updated": request.pathParam("id")}))
  api.patch("/items/{id}", proc(request: Request): Response {.raises: [].} =
    json(%*{"patched": request.pathParam("id")}))
  api.delete("/items/{id}", responses = @[(200, Item)]):
    ok Item(id: 1, name: "deleted")
  initTestClient(api)

suite "TestClient":
  test "reads root as JSON":
    let response = testApp().get("/")
    check response.status == 200
    check response.json() == %*{"msg": "Hello World"}

  test "sends path and query parameters":
    let response = testApp().get("/items/42?page=3")
    check response.json()["id"].getStr() == "42"
    check response.json()["page"].getStr() == "3"

  test "posts a JSON body":
    let response = testApp().post("/items", $ %*{"id": 7, "name": "Widget"})
    check response.status == 201
    check response.json()["name"].getStr() == "Widget"

  test "rejects an invalid JSON body":
    let response = testApp().post("/items", "not json")
    check response.status == 400

  test "puts and patches":
    check testApp().put("/items/1").json()["updated"].getStr() == "1"
    check testApp().patch("/items/2").json()["patched"].getStr() == "2"

  test "deletes":
    let response = testApp().delete("/items/1")
    check response.status == 200
    check response.json()["name"].getStr() == "deleted"

  test "returns 404 for unknown routes":
    let response = testApp().get("/missing")
    check response.status == 404

  test "forwards request headers":
    let api = initFastNim(logs = false)
    api.get("/who"):
      %*{ "agent": request.header("x-agent") }
    let client = initTestClient(api)
    let response = client.get("/who", {"x-agent": "spec"}.toTable)
    check response.json()["agent"].getStr() == "spec"

  test "exposes status, body, and headers":
    let response = testApp().get("/")
    check response.status == 200
    check "Hello World" in response.body
    check response.headers["content-type"].startsWith("application/json")
