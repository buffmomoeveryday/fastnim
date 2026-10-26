## A small library API: FastNim routes over a FastORM SQLite database.
##
## Run from examples/library with `nimble run`.

import std/[options, os, strutils, tables]
import fastnim
import fastnim/orm

const root = currentSourcePath().parentDir().parentDir()

when fileExists(root / "migrations" / "all.nim"):
  import ../migrations/all

model Author:
  name:
    CharField(maxLength: 80, minLength: 1, unique: true)

model Book:
  author:
    ForeignKey(Author, onDelete: Cascade)
  title:
    CharField(maxLength: 200, minLength: 1)
  Meta:
    ordering:
      ["title"]
    uniqueTogether:
      ["author", "title"]

type BookQuery = object
  authorId: Option[int]

proc validationError(issues: seq[FieldIssue]): ApiError =
  var fields = initTable[string, string]()
  for issue in issues:
    fields["body." & issue.field] = issue.message
  initApiError("validation_failed", "validation failed", fields)

proc openLibrary(ctx: Context) =
  let database = waitFor openDatabase(root / "library.sqlite3")
  discard makeMigrations(root / "migrations")
  discard waitFor database.migrate(root / "migrations")
  echo "--------------------------------"
  echo "Database migrated successfully"
  echo "--------------------------------"
  ctx.setContext("database", database)

proc closeLibrary(ctx: Context) =
  waitFor ctx.get("database", Database).close()

let app = initFastNim(
  openApi = initOpenApiSettings(
    title = "Library", description = "Authors and books stored with FastORM"
  )
)

app.onLoad openLibrary
app.onUnload closeLibrary

app.get("/authors", responses = @[(200, seq[Author])], tags = @["authors"]):
  let authors = await Author.objects.orderBy("id").expand(books).all()
  ok authors

app.post(
  "/authors",
  body = Author.ignore(id),
  responses =
    @[(created, Author), (conflict, ApiError), (unprocessableContent, ApiError)],
  tags = @["authors"],
):
  let saved = await body.save().attempt()
  case saved.ok
  of true:
    created body.omit(id)
  of false:
    case saved.err.kind
    of ekUniqueViolation:
      conflict initApiError("author_exists", "an author with that name already exists")
    of ekValidation:
      unprocessableContent validationError(saved.err.issues)
    else:
      raise saved.err.cause

app.get(
  "/authors/{id:int}",
  responses = @[(200, Author), (404, ApiError)],
  tags = @["authors"],
):
  let author = await Author.objects.expand(books).get(id = id)
  if author.isNone:
    notFound initApiError("author_not_found", "author not found")
  else:
    ok author.get

app.get(
  "/books", queryParams = BookQuery, responses = @[(200, seq[Book])], tags = @["books"]
):
  var books = Book.objects.expand(author)

  if queryParams.authorId.isSome:
    books = books.filter(author = queryParams.authorId.get)

  ok (await books.all()).omit(authorId)

app.post(
  "/books",
  body = Book.ignore(id),
  responses = @[(201, Book), (404, ApiError), (409, ApiError), (422, ApiError)],
  tags = @["books"],
):
  let author = await Author.get(id = body.authorId)

  if author.isNone:
    notFound initApiError("author_not_found", "author not found")
  else:
    let saved = await body.save().attempt()
    case saved.ok
    of true:
      created body
    of false:
      case saved.err.kind
      of ekUniqueViolation:
        conflict initApiError(
          "book_exists", "that author already has a book with this title"
        )
      of ekValidation:
        unprocessableContent validationError(saved.err.issues)
      else:
        raise saved.err.cause

app.delete(
  "/books/{id:int}", responses = @[(204, void), (404, ApiError)], tags = @["books"]
):
  let book = await Book.get(id = id)
  if book.isNone:
    notFound initApiError("book_not_found", "book not found")
  else:
    await book.get.delete()
    noContent void

when isMainModule:
  let port = uint16(getEnv("PORT", "8001").parseInt())
  let server = app.serve(port = port)
  waitFor server.join()
