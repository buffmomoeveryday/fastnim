import std/json
import fastnim
import fastnim/orm

model Author:
  name: CharField(maxLength: 80)

model Book:
  author: ForeignKey(Author, onDelete: Cascade)
  title: CharField()

let app = initFastNim(logs = false)

app.post("/authors", body = Author.ignore(id), responses = @[(201, Author)]):
  doAssert body.id == 0
  doAssert body.name == "Ada"
  created body

app.post("/books", body = Book.ignore(id), responses = @[(201, Book)]):
  doAssert body.id == 0
  doAssert body.authorId == 4
  doAssert body.title == "Notes"
  created body

block decodesModelWithoutPrimaryKey:
  let response = app.handleSync(
    initRequest(HttpMethod.Post, "/authors", body = """{"name":"Ada"}""")
  )
  doAssert response.status == 201
  let payload = parseJson(response.body)
  doAssert payload["name"].getStr == "Ada"
  doAssert payload["id"].getInt == 0

block decodesForeignKeyAsId:
  let response = app.handleSync(
    initRequest(
      HttpMethod.Post, "/books", body = """{"authorId":4,"title":"Notes"}"""
    )
  )
  doAssert response.status == 201
  let payload = parseJson(response.body)
  doAssert payload["authorId"].getInt == 4
  doAssert payload["title"].getStr == "Notes"
  doAssert payload["id"].getInt == 0

block openApiDocumentsInputWithoutPrimaryKey:
  let document = app.openApiDocument()
  let authorSchema =
    document["paths"]["/authors"]["post"]["requestBody"]["content"][
      "application/json"
    ]["schema"]
  doAssert "name" in authorSchema["properties"]
  doAssert "id" notin authorSchema["properties"]
  let bookSchema =
    document["paths"]["/books"]["post"]["requestBody"]["content"][
      "application/json"
    ]["schema"]
  doAssert "authorId" in bookSchema["properties"]
  doAssert "title" in bookSchema["properties"]
  doAssert "id" notin bookSchema["properties"]
  doAssert "author" notin bookSchema["properties"]
