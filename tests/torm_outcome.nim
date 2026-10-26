import std/[os, tempfiles, strutils]
import chronos/unittest2/asynctests
import fastnim/orm

model Author:
  name: CharField(maxLength: 50, unique: true)

model Book:
  author: ForeignKey(Author, onDelete: Restrict)
  title: CharField(maxLength: 50, minLength: 1)

proc freshDb(): Future[(Database, string)] {.async.} =
  let dir = createTempDir("fastorm_", "_outcome")
  let db = await openDatabase(dir / "test.sqlite3")
  discard makeMigrations(dir / "migrations")
  discard await db.migrate(dir / "migrations")
  return (db, dir)

proc cleanup(db: Database, dir: string) {.async.} =
  await db.close()
  removeDir(dir)

suite "attempt() and error classification":
  asyncTest "success carries the value":
    let (db, dir) = await freshDb()
    await Author(name: "Ada").save()
    let r = await attempt(Author.objects.orderBy("name").all())
    check r.isOk
    check not r.isErr
    check r.value.len == 1
    check r.get().len == 1
    check r.valueOr(@[]).len == 1
    await cleanup(db, dir)

  asyncTest "unique violations classify without parsing the message":
    let (db, dir) = await freshDb()
    await Author(name: "Ada").save()
    let r = await attempt(Author(name: "Ada").save())
    check r.isErr
    check r.err.isUniqueViolation
    check not r.err.isForeignKeyViolation
    check not r.err.isValidation
    expect DatabaseError:
      r.raiseIfErr()
    await cleanup(db, dir)

  asyncTest "foreign key violations classify distinctly from unique violations":
    let (db, dir) = await freshDb()
    var b = newBook()
    b.authorId = 9999
    b.title = "Nope"
    let r = await attempt(b.save())
    check r.isErr
    check r.err.isForeignKeyViolation
    check not r.err.isUniqueViolation
    await cleanup(db, dir)

  asyncTest "validation errors classify as ekValidation and keep field issues":
    let (db, dir) = await freshDb()
    let r = await attempt(Author(name: "x".repeat(60)).save())
    check r.isErr
    check r.err.isValidation
    check r.err.issues.len == 1
    check r.err.issues[0].field == "name"
    await cleanup(db, dir)

  asyncTest "get() re-raises the original exception on a non-void error result":
    let (db, dir) = await freshDb()
    await db.close()
    let r = await attempt(Author.objects.all())
    check r.isErr
    expect DatabaseError:
      discard r.get()
    removeDir(dir)
