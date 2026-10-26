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

middleware helloMiddleware:
  echo "hello brefore request"
  var response = await next(request)
  echo "hello brefore request"
  response

app.middlewares:
  requestId()
  helloMiddleware()

app.get("/"):
  ok %*{"message": "Hello from FastNim"}

app.get("/async"):
  ok (%*{"message": "Completed without blocking the Chronos event loop"})

app.get("/items/{itemId}"):
  let itemId = request.pathParam("itemId")
  let page = request.queryParam("page", "1")

  ok (%*{"itemId": itemId, "page": page})

app.get("/request-info", responses = @[ok, RequestInfo]):
  ok RequestInfo(requestId: 1, path: request.path)

app.post("/items", body = CreateItem, responses = @[created, CreatedItem]):
  created CreatedItem(id: 1, displayName: body.displayName)

let server = app.serve(port = Port(8090))
waitFor server.join()
