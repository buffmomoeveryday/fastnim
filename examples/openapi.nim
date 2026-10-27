## Run with: nim c -r --path:src examples/openapi.nim
##
## Docs UI: http://127.0.0.1:8001/docs
##
## Multipart upload:
##   curl -X POST http://127.0.0.1:8001/books \
##     -F 'title=The Book' \
##     -F 'category={"name":"Fiction"};type=application/json' \
##     -F 'cover=@cover.png;type=image/png'

import std/os

import chronos

import fastnim
import fastnim/plugins/openapi

const BookCoverDir = "openapi-book-covers"

createDir(BookCoverDir)

type
  Item = object
    id: int
    name: string

  CreateItem = object
    name: string

  CategoryInput = object
    name {.nonEmpty.}: string

  CreateBook = object
    title {.nonEmpty.}: string
    category: CategoryInput
    cover* {.
      upload(
        contentTypes = ["image/jpeg", "image/png"],
        uploadDir = BookCoverDir,
        maxRequestSize = 6.MB,
        maxFileSize = 5.MB,
      )
    .}: UploadedFile

  BookCreated = object
    title: string
    category: string
    coverPath: string

  ApiError = object
    detail: string

let app = initFastNim()
let openApiSettings = initOpenApiSettings(
  title = "FastNim Items API",
  version = "1.0.0",
  description = "Documentation generated from typed FastNim routes.",
)

app.installPlugin:
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

app.post(
  "/books",
  multipart = CreateBook,
  responses = @[(201, BookCreated)],
  tags = @["books"],
  summary = "Create a book with a cover image",
):
  created BookCreated(
    title: multipart.title,
    category: multipart.category.name,
    coverPath: multipart.cover.path,
  )

let server = app.serve(port = 8001, maxRequestBodySize = 6.MB)
waitFor server.join()