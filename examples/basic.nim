## Run with: nim c -r --path:src examples/basic.nim

import json

import fastnim

type
  CreateItem = object
    displayName {.jsonName: "display_name".}: string

  CreatedItem = object
    id: int
    displayName {.jsonName: "display_name".}: string

  RequestInfo = object
    requestId: int
    path: string

let app = initFastNim()

app.middlewares:
  requestId()

app.get("/"):
  ok (%*{"message": "Hello from FastNim"})

app.get("/async"):
  ok (%*{"message": "Completed without blocking the Chronos event loop"})

app.get("/items/{itemId}"):
  let itemId = request.pathParam("itemId")
  let page = request.queryParam("page", "1")

  ok (%*{"itemId": itemId, "page": page})

app.get("/request-info", responses = @[(200, RequestInfo)]):
  ok RequestInfo(requestId: 1, path: request.path)

app.post("/items", body = CreateItem, responses = @[(201, CreatedItem)]):
  created CreatedItem(id: 1, displayName: body.displayName)

let server = app.serve(port = 8090)
echo "Listening at http://127.0.0.1:8090"
waitFor server.join()
