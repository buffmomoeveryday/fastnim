## Typed book metadata and a cover uploaded in one multipart request.
##
## Run with:
##   nim c -r --path:src examples/mixed_multipart.nim
##
## Upload with:
##   curl -X POST http://127.0.0.1:8000/books \
##     -F 'title=The Book' \
##     -F 'category={"name":"Fiction"};type=application/json' \
##     -F 'cover=@cover.png;type=image/png'
##
## OpenAPI is available at http://127.0.0.1:8000/docs

import std/os

import chronos

import fastnim
import fastnim/plugins/openapi

const BookCoverDir = "book-covers"

createDir(BookCoverDir)

type
  CategoryInput = object
    name {.nonEmpty.}: string

  CreateBook = object
    title {.nonEmpty.}: string
    category: CategoryInput
    cover* {.
      upload(
        contentTypes = ["image/jpeg", "image/png"],
        uploadDir = BookCoverDir,
        maxRequestSize = 3.MiB,
        maxFileSize = 2.MiB,
      )
    .}: UploadedFile

  BookCreated = object
    title*: string
    category*: string
    coverPath*: string

let app = initFastNim()

app.installPlugin:
  openApiPlugin(
    initOpenApiSettings(
      title = "Mixed Multipart Example",
      version = "1.0.0",
      description = "Metadata fields and a file in one typed multipart route.",
    )
  )

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

when isMainModule:
  echo "POST multipart fields to http://127.0.0.1:8000/books"
  echo "OpenAPI UI at http://127.0.0.1:8000/docs"
  let server = app.serve(maxRequestBodySize = 6.MB, port = Port(8001))
  waitFor server.join()
