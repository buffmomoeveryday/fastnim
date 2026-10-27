import std/[json, options, strutils, tables]

import fastnim

const Boundary = "fastnim-mixed-route-boundary"

type
  Condition = enum
    conditionNew = "New"
    conditionUsed = "Used"

  CategoryInput = object
    name {.nonEmpty.}: string

  BookInput = object
    title {.jsonName: "bookTitle", nonEmpty.}: string
    pageCount {.positive.}: int
    condition: Condition
    note: Option[string]
    category: CategoryInput
    coverImage {.
      upload(
        fieldName = "cover",
        contentTypes = ["application/pdf"],
        storage = UploadStorage.Memory,
        memorySizeCap = 1024,
        maxRequestSize = 4096,
        maxFileSize = 1024,
      )
    .}: UploadedFile

  BookOutput = object
    title: string
    category: string
    filename: string
    size: int64

proc fieldPart(name, value: string): string =
  "Content-Disposition: form-data; name=\"" & name & "\"\r\n\r\n" & value & "\r\n"

proc filePart(name, filename, contentType, value: string): string =
  "Content-Disposition: form-data; name=\"" & name & "\"; filename=\"" &
    filename & "\"\r\nContent-Type: " & contentType & "\r\n\r\n" & value & "\r\n"

proc multipartBody(parts: openArray[string]): string =
  for part in parts:
    result.add("--" & Boundary & "\r\n")
    result.add(part)
  result.add("--" & Boundary & "--\r\n")

proc multipartRequest(path: string, parts: openArray[string]): Request =
  var headers = initTable[string, string]()
  headers["content-type"] = "multipart/form-data; boundary=" & Boundary
  initRequest(HttpMethod.Post, path, headers, multipartBody(parts))

let app = initFastNim(logs = false)

static:
  doAssert not compiles(
    block:
      let invalidApp = initFastNim(logs = false)
      invalidApp.post("/invalid", body = BookInput, responses = @[(201, BookOutput)]):
        created BookOutput()
  )

app.post(
  "/books", multipart = BookInput, responses = @[(201, BookOutput)]
):
  created BookOutput(
    title: multipart.title,
    category: multipart.category.name,
    filename: multipart.coverImage.filename,
    size: multipart.coverImage.size,
  )

block parsesMixedMultipartRoute:
  let response = app.handleSync(
    multipartRequest(
      "/books",
      [
        fieldPart("bookTitle", "The Book"),
        fieldPart("pageCount", "240"),
        fieldPart("condition", "New"),
        fieldPart("category", """{"name":"Fiction"}"""),
        filePart("cover", "cover.pdf", "application/pdf", "pdf bytes"),
      ],
    )
  )
  doAssert response.status == 201
  let body = parseJson(response.body)
  doAssert body["title"].getStr == "The Book"
  doAssert body["category"].getStr == "Fiction"
  doAssert body["filename"].getStr == "cover.pdf"
  doAssert body["size"].getInt == 9

block acceptsJsonPartsWithFilename:
  ## Swagger UI attaches filename="blob" to JSON-encoded nested parts.
  let response = app.handleSync(
    multipartRequest(
      "/books",
      [
        fieldPart("bookTitle", "The Book"),
        fieldPart("pageCount", "240"),
        fieldPart("condition", "New"),
        filePart("category", "blob", "application/json", """{"name":"Fiction"}"""),
        filePart("cover", "cover.pdf", "application/pdf", "pdf bytes"),
      ],
    )
  )
  doAssert response.status == 201, response.body
  let body = parseJson(response.body)
  doAssert body["category"].getStr == "Fiction"
  doAssert body["filename"].getStr == "cover.pdf"

block rejectsInvalidNestedJson:
  let response = app.handleSync(
    multipartRequest(
      "/books",
      [
        fieldPart("bookTitle", "The Book"),
        fieldPart("pageCount", "240"),
        fieldPart("condition", "New"),
        fieldPart("category", "not-json"),
        filePart("cover", "cover.pdf", "application/pdf", "pdf bytes"),
      ],
    )
  )
  doAssert response.status == 400

block validatesMultipartModel:
  let response = app.handleSync(
    multipartRequest(
      "/books",
      [
        fieldPart("bookTitle", ""),
        fieldPart("pageCount", "0"),
        fieldPart("condition", "Used"),
        fieldPart("category", """{"name":"Fiction"}"""),
        filePart("cover", "cover.pdf", "application/pdf", "pdf bytes"),
      ],
    )
  )
  doAssert response.status == 422
  doAssert "multipart.bookTitle" in response.body
  doAssert "multipart.pageCount" in response.body

block rejectsWrongFileContentType:
  let response = app.handleSync(
    multipartRequest(
      "/books",
      [
        fieldPart("bookTitle", "The Book"),
        fieldPart("pageCount", "240"),
        fieldPart("condition", "New"),
        fieldPart("category", """{"name":"Fiction"}"""),
        filePart("cover", "cover.png", "image/png", "png bytes"),
      ],
    )
  )
  doAssert response.status == 415

block documentsMultipartRoute:
  let document = app.openApiDocument()
  let content = document["paths"]["/books"]["post"]["requestBody"]["content"]
  doAssert "multipart/form-data" in content
  let multipartContent = content["multipart/form-data"]
  let schema = multipartContent["schema"]
  doAssert schema["properties"]["cover"]["type"].getStr == "string"
  doAssert schema["properties"]["cover"]["format"].getStr == "binary"
  doAssert schema["properties"]["bookTitle"]["minLength"].getInt == 1
  doAssert schema["properties"]["pageCount"]["type"].getStr == "integer"
  doAssert multipartContent["encoding"]["category"]["contentType"].getStr ==
    "application/json"
  var noteRequired = false
  for field in schema["required"]:
    if field.getStr == "note":
      noteRequired = true
  doAssert not noteRequired
