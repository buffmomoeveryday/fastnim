import std/[os, sequtils, tempfiles]
import chronos/unittest2/asynctests
import fastnim/orm

model Author:
  name:
    CharField(maxLength: 80)

model Book:
  title:
    CharField(maxLength: 200)
  authors:
    ManyToManyField(Author, relatedName: "books")

model UuidBase {.abstract.}:
  id:
    UUIDField(primaryKey: true)

model UuidAuthor = ref UuidBase:
  name:
    CharField()

model UuidBook = ref UuidBase:
  title:
    CharField()
  authors:
    ManyToManyField(
      UuidAuthor, relatedName: "books", table: "library_book_authors"
    )

model Person:
  name:
    CharField()
  friends:
    ManyToManyField(Person, relatedName: "friendedBy")

model Tag:
  name:
    CharField()

model Tagged {.abstract.}:
  tags:
    ManyToManyField(Tag, relatedName: "{model}s", table: "{model}_tags")

model Story = ref Tagged:
  title:
    CharField()

proc freshDb(): Future[(Database, string)] {.async.} =
  let dir = createTempDir("fastorm_many_", "_test")
  let db = await openDatabase(dir / "test.sqlite3")
  discard makeMigrations(dir / "migrations")
  discard await db.migrate(dir / "migrations")
  return (db, dir)

proc cleanup(db: Database, dir: string) {.async.} =
  await db.close()
  removeDir(dir)

suite "many-to-many fields":
  test "migration snapshot contains the implicit junction table":
    let snapshot = snapshotOf([modelMeta(Author), modelMeta(Book)])
    let relation = modelMeta(Book).manyToMany[0]
    check relation.name == "authors"
    check relation.target == "Author"
    check relation.table == "book_authors"
    check relation.relatedName == "books"
    let table = snapshot.tables.filterIt(it.name == "book_authors")[0]
    check table.columns.len == 2
    check table.columns[0].name == "book_id"
    check table.columns[0].refTable == "book"
    check table.columns[1].name == "author_id"
    check table.columns[1].refTable == "author"
    check table.indexes.anyIt(it.unique)

  asyncTest "manager adds, reads, removes, and clears both directions":
    let (db, dir) = await freshDb()
    let book = Book(title: "Nim in Action")
    let ada = Author(name: "Ada")
    let grace = Author(name: "Grace")
    await book.save()
    await ada.save()
    await grace.save()

    await book.authors.add(ada, grace)
    await book.authors.add(ada)
    check (await book.authors.count()) == 2
    check await book.authors.contains(ada)
    check (await book.authors.all()).mapIt(it.name) == @["Ada", "Grace"]

    check (await ada.books.count()) == 1
    let reverse = await ada.books.all()
    check reverse.len == 1
    check reverse[0].title == "Nim in Action"

    check (await book.authors.remove(ada)) == 1
    check not (await book.authors.contains(ada))
    check (await book.authors.clear()) == 1
    check (await book.authors.count()) == 0
    await cleanup(db, dir)

  asyncTest "junction rows cascade when either model is deleted":
    let (db, dir) = await freshDb()
    let book = Book(title: "Cascade")
    let author = Author(name: "Ada")
    await book.save()
    await author.save()
    await book.authors.add(author)
    await author.delete()
    check (await book.authors.count()) == 0
    await cleanup(db, dir)

  asyncTest "UUID keys and custom junction tables work":
    let (db, dir) = await freshDb()
    let book = UuidBook(title: "UUIDs")
    let author = UuidAuthor(name: "Ada")
    await book.save()
    await author.save()
    await book.authors.add(author)
    let authors = await book.authors.all()
    let books = await author.books.all()
    check authors[0].id == author.id
    check books[0].id == book.id
    await cleanup(db, dir)

  asyncTest "directional self relations use distinct junction columns":
    let (db, dir) = await freshDb()
    let ada = Person(name: "Ada")
    let grace = Person(name: "Grace")
    await ada.save()
    await grace.save()
    await ada.friends.add(grace)
    let friends = await ada.friends.all()
    let reverseFriends = await grace.friendedBy.all()
    check friends[0].name == "Grace"
    check reverseFriends[0].name == "Ada"
    await cleanup(db, dir)

  asyncTest "abstract models pass relations to concrete children":
    let (db, dir) = await freshDb()
    let story = Story(title: "Inheritance")
    let tag = Tag(name: "Nim")
    await story.save()
    await tag.save()
    await story.tags.add(tag)
    check modelMeta(Story).manyToMany[0].table == "story_tags"
    check (await tag.storys.count()) == 1
    await cleanup(db, dir)

  asyncTest "unsaved models cannot be attached":
    let (db, dir) = await freshDb()
    let saved = Book(title: "Saved")
    await saved.save()
    expect QueryError:
      await saved.authors.add(Author(name: "Unsaved"))
    expect QueryError:
      discard await Book(title: "Unsaved").authors.all()
    await cleanup(db, dir)
