# Library example

A small JSON API that uses [FastNim](https://github.com/buffmomoeveryday/fastnim) for HTTP and FastORM for SQLite. FastNim route handlers run on Chronos, so they can `await` FastORM queries directly.

## Run

From this directory:

```sh
nimble run
```

The API listens on `127.0.0.1:8000`. Interactive docs are at <http://127.0.0.1:8000/docs>.

On startup the app opens `library.sqlite3` beside this folder, writes a Nim migration into `migrations/` when the models changed, and applies any pending migrations compiled into the binary. After a new migration file appears, rebuild so the next launch imports `migrations/all.nim`.

## Routes

```sh
curl -X POST localhost:8000/authors -H 'content-type: application/json' \
  -d '{"name":"Ada"}'

curl localhost:8000/authors

curl -X POST localhost:8000/books -H 'content-type: application/json' \
  -d '{"title":"Notes","authorId":1}'

curl 'localhost:8000/books?authorId=1'
curl -X DELETE localhost:8000/books/1
```

Responses are the model columns: an author is `{"id": 1, "name": "Ada"}` and a book is `{"id": 1, "authorId": 1, "title": "Notes"}`. `.omit(field)` drops a field, including from `created author.omit(id)`.

`POST /authors` returns 422 when the name is empty and 409 when that name already exists. `POST /books` returns 404 when the author does not exist and 409 when that author already has a book with the same title.
