## Run with: nim c -r --path:src examples/openapi.nim
import chronos
import fastnim
import fastnim/plugins/openapi

type
  Item = object
    id: int
    name: string

  CreateItem = object
    name: string

  ApiError = object
    detail: string


let app = initFastNim()
let openApiSettings = initOpenApiSettings(
  title = "FastNim Items API",
  version = "1.0.0",
  description = "Documentation generated from typed FastNim routes.",
)

app.install:
  openApiPlugin(openApiSettings)

app.get(
  "/items/{itemId}",
  responses = @[(200, Item), (404, ApiError)],
  tags = @["items"],
  summary = "Get an item",
):
  if request.pathParam("itemId") == "1":
    ok Item(id: 1, name: "sample")
  else:
    notFound ApiError(detail: "item not found")

app.post("/items", body = CreateItem, responses = @[(201, Item), (400, ApiError)]):
  if body.name.len == 0:
    badRequest ApiError(detail: "name is required")
  else:
    created Item(id: 1, name: body.name)

let server = app.serve(port = 8001)
echo "Swagger UI: http://127.0.0.1:8001/docs"
waitFor server.join()
