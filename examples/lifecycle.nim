## Run with: nim c -r --path:src examples/lifecycle.nim
import fastnim
import db_connector/db_sqlite

import std/strutils

let api = initFastNim()

type Dependencies = object
  db: DbConn
  str: string

proc initDb(): DbConn =
  let db = open(":memory:", "", "", "")
  db.exec(
    sql"""
      CREATE TABLE USERS (
        id INTEGER PRIMARY KEY,
        name TEXT
      )
    """
  )
  let users = ["Alice", "Bob", "Charlie", "Diana", "Eve"]
  for name in users:
    db.exec(sql"INSERT INTO users (name) VALUES (?)", name)

  echo "added 5 users into the database"

  db

api.dependencies(Dependencies):
  # database
  provide db:
    initDb()
  cleanup db:
    db.close()

  # const
  provide str:
    "hello world"
  cleanup str:
    discard

type User = object
  id: int
  name: string

proc getAllUsers(db: DbConn): seq[User] =
  result = @[]
  let dbRows = db.getAllRows sql"SELECT id, name FROM USERS"
  for row in dbRows:
    result.add User(id: parseInt(row[0]), name: row[1])

api.get("/health"):
  let str = ctx.get("str")
  let db = ctx.get("db")

  text str

api.get("/users", responses = @[(200, seq[User])]):
  let db = ctx.get("db")
  ok getAllUsers(db)

let server = api.serve(port = 8009)
echo "Listening at http://127.0.0.1:8000"
try:
  waitFor server.join()
finally:
  waitFor api.stop server
