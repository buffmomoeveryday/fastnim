import std/[os, tempfiles, sequtils, strutils, times, algorithm, json]
import chronos/unittest2/asynctests
import fastnim
import fastnim/orm

model Timestamped {.abstract.}:
  createdAt:
    DateTimeField(autoNowAdd: true)
  updatedAt:
    DateTimeField(autoNow: true)

model Publisher:
  name:
    CharField()

model Author = ref Timestamped:
  id:
    UUIDField(primaryKey: true)
  name:
    CharField(maxLength: 50)
  email:
    CharField(unique: true, null: true)
  publisher:
    ForeignKey(Publisher, null: true, onDelete: SetNull)

model Noted {.abstract.}:
  owner:
    ForeignKey(Author, relatedName: "{model}s")

model Note = ref Noted:
  body:
    TextField()

model Article = ref Timestamped:
  author:
    ForeignKey(Author, onDelete: Cascade)
  title:
    CharField(maxLength: 200)
  views:
    IntegerField(default: 0)
  published:
    BooleanField(default: false)
  rating:
    FloatField(null: true)

model Comment:
  article:
    ForeignKey(Article, onDelete: SetNull, null: true)
  body:
    TextField()

model Chapter:
  article:
    ForeignKey(Article, onDelete: Cascade, relatedName: "chapters")
  title:
    CharField()

model Node:
  parent:
    ForeignKey(Node, onDelete: SetNull, null: true, relatedName: "children")
  name:
    CharField()

model Shelf:
  owner:
    ForeignKey(Author, onDelete: Restrict)
  label:
    CharField()

model Ranked:
  label:
    CharField()
  rank:
    IntegerField()
  Meta:
    ordering:
      ["rank", "-label"]
    indexes:
      Index(fields: ["rank", "label"], name: "ranked_rank_label")
    uniqueTogether:
      ["label", "rank"]

model Animal:
  name:
    CharField()

model Dog = ref Animal:
  breed:
    CharField()

proc freshDb(): Future[(Database, string)] {.async.} =
  let dir = createTempDir("fastorm_", "_test")
  let db = await openDatabase(dir / "test.sqlite3")
  discard makeMigrations(dir / "migrations")
  discard await db.migrate(dir / "migrations")
  return (db, dir)

proc cleanup(db: Database, dir: string) {.async.} =
  await db.close()
  removeDir(dir)

proc author(name: string, email = ""): Future[Author] {.async.} =
  let a = Author(name: name)
  if email.len > 0:
    a.email = some(email)
  await a.save()
  return a

proc article(
    a: Author, title: string, views = 0, rating = none(float)
): Future[Article] {.async.} =
  let x = newArticle()
  x.author = a
  x.title = title
  x.views = views
  x.rating = rating
  await x.save()
  return x

proc titles(xs: seq[Article]): seq[string] =
  xs.mapIt(it.title)

suite "querying":
  asyncTest "save inserts, assigns keys, and updates":
    let (db, dir) = await freshDb()
    let a = await author("Ada")
    check not a.id.isZero
    let x = await article(a, "First")
    check x.id == 1
    x.title = "Renamed"
    await x.save()
    check (await Article.objects.count()) == 1
    let found72 = await Article.get(id = x.id)
    check found72.get.title == "Renamed"
    await x.delete()
    check (await Article.objects.count()) == 0
    await cleanup(db, dir)

  asyncTest "no-match semantics":
    let (db, dir) = await freshDb()
    check (await Author.objects.all()) == newSeq[Author]()
    check (await Author.get(name = "nobody")).isNone
    check (await Author.objects.first()).isNone
    check not (await Author.objects.exists())
    discard await author("Ada")
    discard await author("Ada")
    expect MultipleObjectsReturned:
      discard await Author.get(name = "Ada")
    await cleanup(db, dir)

  asyncTest "Meta ordering and unique indexes":
    let (db, dir) = await freshDb()
    await Ranked(label: "b", rank: 2).save()
    await Ranked(label: "a", rank: 1).save()
    await Ranked(label: "c", rank: 1).save()
    check (await Ranked.objects.all()).mapIt(it.label) == @["c", "a", "b"]
    check (await Ranked.objects.orderBy("label").all()).mapIt(it.label) ==
      @["a", "b", "c"]
    expect DatabaseError:
      await Ranked(label: "a", rank: 1).save()
    var names: seq[string]
    for row in (await db.query("SELECT name FROM sqlite_master WHERE type = 'index'")).rows:
      names.add row[0].s
    check "ranked_rank_label" in names
    check "ranked_label_rank_uniq" in names
    await cleanup(db, dir)

  asyncTest "query sets are immutable and chainable":
    let (db, dir) = await freshDb()
    let a = await author("Ada")
    for i in 1 .. 5:
      discard await article(a, "Post " & $i, views = i * 10)
    let popular = Article.objects.filter(views >= 20)
    let top = popular.orderBy("-views").limit(2)
    check (await popular.count()) == 4
    check (await top.all()).titles == @["Post 5", "Post 4"]
    check (await top.offset(1).all()).titles == @["Post 4", "Post 3"]
    check (await top.count()) == 2
    check (await popular.filter(views < 40).orderBy("views").all()).titles ==
      @["Post 2", "Post 3"]
    let found102 = await Article.objects.orderBy("title").first()
    check found102.get.title == "Post 1"
    await cleanup(db, dir)

  asyncTest "aggregates use filtered and sliced query sets":
    let (db, dir) = await freshDb()
    let a = await author("Ada")
    discard await article(a, "One", views = 10, rating = some(1.5))
    discard await article(a, "Two", views = 20, rating = some(3.5))
    discard await article(a, "Three", views = 30)
    let stats = await Article.filter(views >= 20).aggregate(
      rows = Count(id),
      totalViews = Sum(views),
      averageViews = Avg(views),
      lowestTitle = Min(title),
      highestRating = Max(rating),
    )
    check stats.aggregateInt("rows") == 2
    check stats.aggregateInt("totalViews") == 50
    check stats.aggregateFloat("averageViews") == 25.0
    check stats.aggregateValue("lowestTitle").s == "Three"
    check stats.aggregateFloat("highestRating") == 3.5
    let page = await Article.objects.orderBy("views").limit(2).aggregate(
      rows = Count(id), totalViews = Sum(views)
    )
    check page.aggregateInt("rows") == 2
    check page.aggregateInt("totalViews") == 30
    let empty =
      await Article.filter(views > 100).aggregate(rows = Count(id), total = Sum(views))
    check empty.aggregateInt("rows") == 0
    check empty.aggregateValue("total").kind == dvNull
    await cleanup(db, dir)

  asyncTest "lookups":
    let (db, dir) = await freshDb()
    let a = await author("Ada", "ada@example.com")
    discard await author("Grace")
    discard await article(a, "Hello World", rating = some(4.5))
    discard await article(a, "hello again")
    discard await article(a, "Goodbye 100%")
    proc q(qs: QuerySet[Article]): Future[seq[string]] {.async.} =
      return (await qs.orderBy("title").all()).titles

    check (await q(Article.filter(title.contains = "Hello"))) == @["Hello World"]
    check (await q(Article.filter(title.icontains = "hello"))) ==
      @["Hello World", "hello again"]
    check (await q(Article.filter(title.startsWith = "hello"))) == @["hello again"]
    check (await q(Article.filter(title.istartsWith = "HELLO"))) ==
      @["Hello World", "hello again"]
    check (await q(Article.filter(title.endsWith = "100%"))) == @["Goodbye 100%"]
    check (await q(Article.filter(title.icontains = "0%"))) == @["Goodbye 100%"]
    check (await q(Article.filter(title.icontains = "_"))) == newSeq[string]()
    check (await q(Article.filter(title.iexact = "HELLO WORLD"))) == @["Hello World"]
    check (await q(Article.filter(title != "Hello World"))) ==
      @["Goodbye 100%", "hello again"]
    check (await q(Article.filter(title in ["hello again", "nope"]))) == @[
      "hello again"
    ]
    check (await q(Article.filter(title notin ["hello again"]))) ==
      @["Goodbye 100%", "Hello World"]
    check (await q(Article.filter(title.isIn = newSeq[string]()))) == newSeq[string]()
    check (await q(Article.filter(rating.isNull = true))) ==
      @["Goodbye 100%", "hello again"]
    check (await q(Article.filter(rating > 4.0))) == @["Hello World"]
    check (await q(Article.filter(rating = none(float)))) ==
      @["Goodbye 100%", "hello again"]
    check (await q(Article.exclude(title.icontains = "hello"))) == @["Goodbye 100%"]
    check (await Author.filter(email = "ada@example.com").count()) == 1
    check (await Author.filter(email.isNull = true).count()) == 1
    await cleanup(db, dir)

  asyncTest "values are bound as parameters":
    let (db, dir) = await freshDb()
    let evil = "Robert'); DROP TABLE author; --"
    discard await author(evil)
    let found139 = await Author.get(name = evil)
    check found139.get.name == evil
    check (await Author.objects.count()) == 1
    await cleanup(db, dir)

  asyncTest "bulk update and delete":
    let (db, dir) = await freshDb()
    let a = await author("Ada")
    for i in 1 .. 4:
      discard await article(a, "Post " & $i, views = i)
    check (await Article.filter(views <= 2).update(published = true, views = 99)) == 2
    check (await Article.filter(published = true).count()) == 2
    check (await Article.filter(views = 99).delete()) == 2
    check (await Article.objects.count()) == 2
    await cleanup(db, dir)

  asyncTest "foreign keys":
    let (db, dir) = await freshDb()
    let a = await author("Ada")
    let b = await author("Grace")
    let x = await article(a, "Mine")
    discard await article(b, "Theirs")
    check x.authorId == a.id
    let found161 = await x.author()
    check found161.get.name == "Ada"
    check (await Article.filter(author = a).all()).titles == @["Mine"]
    check (await Article.filter(author = b.id).all()).titles == @["Theirs"]
    let c = Comment(body: "nice")
    c.article = x
    await c.save()
    let found168 = await c.article()
    check found168.get.title == "Mine"
    # Cascade: deleting the author deletes the article; SetNull clears the comment.
    await a.delete()
    check (await Article.objects.all()).titles == @["Theirs"]
    let orphan = (await Comment.objects.first()).get
    check orphan.articleId.isNone
    check (await orphan.article()).isNone
    # Restrict: an author with a shelf cannot be deleted.
    let s = Shelf(label: "Top")
    s.owner = b
    await s.save()
    expect DatabaseError:
      await b.delete()
    check (await Author.get(id = b.id)).isSome
    await cleanup(db, dir)

  asyncTest "validation runs before saving":
    let (db, dir) = await freshDb()
    let a = Author(name: "x".repeat(51))
    try:
      await a.save()
      check false
    except ValidationError as e:
      check e.errors.len == 1
      check e.errors[0].field == "name"
    check (await Author.objects.count()) == 0
    await cleanup(db, dir)

  asyncTest "unique constraints surface as database errors":
    let (db, dir) = await freshDb()
    discard await author("Ada", "same@example.com")
    expect DatabaseError:
      discard await author("Grace", "same@example.com")
    await cleanup(db, dir)

  asyncTest "timestamps":
    let (db, dir) = await freshDb()
    let a = await author("Ada")
    let created = a.createdAt
    check created > fromUnix(0)
    await sleepAsync(chronos.milliseconds(5))
    a.name = "Ada L."
    await a.save()
    check a.createdAt == created
    check a.updatedAt > created
    let loaded = (await Author.get(id = a.id)).get
    check loaded.createdAt == created
    check loaded.updatedAt == a.updatedAt
    await cleanup(db, dir)

  asyncTest "concrete inheritance keeps separate tables":
    let (db, dir) = await freshDb()
    await Animal(name: "Generic").save()
    let d = Dog(name: "Rex", breed: "Collie")
    await d.save()
    check (await Animal.objects.count()) == 1
    check (await Dog.objects.count()) == 1
    let rex = (await Dog.get(name = "Rex")).get
    check rex.breed == "Collie"
    check rex of Animal
    await cleanup(db, dir)

  asyncTest "concurrent operations are serialized safely":
    let (db, dir) = await freshDb()
    var futs: seq[Future[Author]]
    for i in 0 ..< 50:
      futs.add author("Author " & $i)
    await allFutures(futs)
    for f in futs:
      check f.completed
    check (await Author.objects.count()) == 50
    await cleanup(db, dir)

  asyncTest "explicit databases":
    let (db, dir) = await freshDb()
    let other = await openDatabase(dir / "other.sqlite3", setDefault = false)
    discard await other.migrate(dir / "migrations")
    discard await author("Default")
    let a = Author(name: "Other")
    await a.save(other)
    check (await Author.objects.count()) == 1
    check (await Author.objects.withDb(other).all()).mapIt(it.name) == @["Other"]
    await other.close()
    await cleanup(db, dir)

  asyncTest "or conditions":
    let (db, dir) = await freshDb()
    let a = await author("Ada")
    discard await article(a, "Alpha", views = 1)
    discard await article(a, "Beta", views = 5)
    discard await article(a, "Gamma", views = 9)
    check (await Article.filter(title == "Alpha" or title == "Gamma").count()) == 2
    check (
      await Article.filter(any(title = "Alpha", title = "Gamma"), views > 1).count()
    ) == 1
    check (await Article.filter(all(views >= 5, views < 9) or title == "Alpha").count()) ==
      2
    check (await Article.exclude(title == "Beta" or views < 5).count()) == 1
    check (
      await Article.filter(title.icontains == "beta" or views == 1).orderBy("title").all()
    ).titles == @["Alpha", "Beta"]
    let ada = (await Author.get(name = "Ada")).get
    check (await Article.filter(author == ada or views > 100).count()) == 3
    await cleanup(db, dir)

  asyncTest "filters reach through a relation":
    let (db, dir) = await freshDb()
    let orbit = Publisher(name: "Orbit")
    await orbit.save()
    let other = Publisher(name: "Tor")
    await other.save()
    let ada = await author("Ada")
    ada.publisher = orbit
    await ada.save()
    let grace = await author("Grace")
    grace.publisher = other
    await grace.save()
    discard await article(ada, "Mine", views = 5)
    discard await article(grace, "Theirs", views = 50)

    # Single-level chase, including a lookup suffix.
    check (await Article.filter(author.name = "Ada").all()).titles == @["Mine"]
    check (await Article.filter(author.name.icontains = "ad").all()).titles == @["Mine"]
    check (await Article.filter(author.name = "Ada", views > 1).count()) == 1

    # Multi-level chase.
    check (await Article.filter(author.publisher.name = "Orbit").all()).titles ==
      @["Mine"]
    check (await Article.filter(author.publisher.name.icontains = "bit").all()).titles ==
      @["Mine"]

    # Comparison operator chased through a relation, and combined with or/any/all.
    check (await Author.filter(name = "Grace").count()) == 1
    check (await Article.filter(author.name == "Ada" or author.name == "Grace").count()) ==
      2
    check (await Article.filter(any(author.name = "Ada", views > 1000)).count()) == 1
    check (await Article.filter(all(author.name = "Grace", views > 10)).count()) == 1
    check (await Article.exclude(author.name == "Ada").count()) == 1

    # Self relation.
    let root = Node(name: "root")
    await root.save()
    var child = Node(name: "child")
    child.parent = root
    await child.save()
    check (await Node.filter(parent.name = "root").count()) == 1

    # The join also populates the relation cache, same as `selectRelated`.
    let mark = db.operationCount
    let mine = (await Article.filter(author.name = "Ada").all())[0]
    check db.operationCount == mark + 1
    let a = await mine.author()
    check a.get.name == "Ada"
    check db.operationCount == mark + 1

    # `update`/`delete` through a relation run as a subquery (no JOIN in UPDATE/DELETE).
    check (await Article.filter(author.name = "Ada").update(views = 999)) == 1
    check (await Article.filter(author.name = "Ada", views = 999).count()) == 1
    check (await Article.filter(author.name = "Grace").delete()) == 1
    check (await Article.objects.count()) == 1
    await cleanup(db, dir)

  asyncTest "selectRelated loads foreign keys in one query":
    let (db, dir) = await freshDb()
    let p = Publisher(name: "Orbit")
    await p.save()
    let ada = await author("Ada")
    ada.publisher = p
    await ada.save()
    let grace = await author("Grace")
    discard await article(ada, "Joined")
    discard await article(grace, "Alone")
    let base = Article.objects.selectRelated("author")
    let mark = db.operationCount
    let rows = await base.orderBy("title").all()
    check db.operationCount == mark + 1
    let alone = (await rows[0].author()).get
    let joined = (await rows[1].author()).get
    check alone.name == "Grace"
    check joined.name == "Ada"
    check db.operationCount == mark + 1
    let before = db.operationCount
    let loadedPublisher = await joined.publisher()
    check loadedPublisher.get.name == "Orbit"
    check db.operationCount == before + 1
    let wide = await base.selectRelated("author.publisher").orderBy("title").all()
    let afterJoin = db.operationCount
    let joinedAuthor = (await wide[1].author()).get
    let orbit = await joinedAuthor.publisher()
    check orbit.get.name == "Orbit"
    let aloneAuthor = (await wide[0].author()).get
    let noPublisher = await aloneAuthor.publisher()
    check noPublisher.isNone
    check db.operationCount == afterJoin
    await cleanup(db, dir)

  asyncTest "prefetchRelated batches forward, reverse, and nested relations":
    let (db, dir) = await freshDb()
    let ada = await author("Ada")
    let grace = await author("Grace")
    let one = await article(ada, "One")
    discard await article(ada, "Two")
    discard await article(grace, "Three")
    var chapter = Chapter(title: "Intro")
    chapter.article = one
    await chapter.save()
    let mark = db.operationCount
    let people =
      await Author.objects.orderBy("name").prefetchRelated("articles.chapters").all()
    check db.operationCount == mark + 3
    var adaTitles = (await people[0].articles()).titles
    adaTitles.sort()
    check adaTitles == @["One", "Two"]
    check (await people[1].articles()).titles == @["Three"]
    var chapterCount = 0
    for item in await people[0].articles():
      chapterCount += (await item.chapters()).len
    check chapterCount == 1
    check db.operationCount == mark + 3
    let listed = await Article.objects.prefetchRelated("author").all()
    let after = db.operationCount
    let firstAuthor = await listed[0].author()
    let secondAuthor = await listed[1].author()
    check firstAuthor.isSome
    check secondAuthor.isSome
    check db.operationCount == after
    await cleanup(db, dir)

  asyncTest "relatedName on an abstract base":
    let (db, dir) = await freshDb()
    let ada = await author("Ada")
    var note = Note(body: "hi")
    note.owner = ada
    await note.save()
    let people = await Author.objects.prefetchRelated("notes").all()
    let notes = await people[0].notes()
    check notes.len == 1
    check notes[0].body == "hi"
    await cleanup(db, dir)

  asyncTest "self relations":
    let (db, dir) = await freshDb()
    let root = Node(name: "root")
    await root.save()
    var child = Node(name: "child")
    child.parent = root
    await child.save()
    let mark = db.operationCount
    let loaded =
      (await Node.objects.filter(name = "child").selectRelated("parent").get()).get
    check db.operationCount == mark + 1
    let parent = await loaded.parent()
    check parent.get.name == "root"
    check db.operationCount == mark + 1
    let roots =
      await Node.objects.filter(name = "root").prefetchRelated("children").all()
    let kids = await roots[0].children()
    check kids.len == 1
    check kids[0].name == "child"
    check db.operationCount == mark + 3
    await cleanup(db, dir)

  asyncTest "query errors":
    let (db, dir) = await freshDb()
    expect QueryError:
      discard Author.objects.orderBy("missing")
    await db.close()
    expect DatabaseError:
      discard await Author.objects.all()
    removeDir(dir)

  asyncTest "F() updates columns without a read-modify-write":
    let (db, dir) = await freshDb()
    let ada = await author("Ada")
    let grace = await author("Grace")
    discard await article(ada, "Notes", views = 10, rating = some(1.5))
    discard await article(grace, "Draft", views = 3)
    check (await Article.filter(title = "Notes").update(views = F(views) + 1)) == 1
    var notes = await Article.objects.get(title = "Notes")
    check notes.get.views == 11
    check (await Article.filter(title = "Draft").update(views = F(views) - 1)) == 1
    var draft = await Article.objects.get(title = "Draft")
    check draft.get.views == 2
    let step = 2
    check (await Article.filter(title = "Notes").update(views = F(views) * step)) == 1
    notes = await Article.objects.get(title = "Notes")
    check notes.get.views == 22
    check (await Article.filter(title = "Notes").update(rating = F(views) + 0.5)) == 1
    notes = await Article.objects.get(title = "Notes")
    check notes.get.rating == some(22.5)
    check (await Article.filter(title = "Draft").update(rating = F(views))) == 1
    draft = await Article.objects.get(title = "Draft")
    check draft.get.rating == some(2.0)
    check (await Article.filter(author.name = "Ada").update(views = F(views) + 3)) == 1
    notes = await Article.objects.get(title = "Notes")
    check notes.get.views == 25
    check (await Article.filter(title = "Missing").update(views = F(views) + 1)) == 0
    notes = await Article.objects.filter(title = "Notes").get()
    check notes.get.views == 25
    let conflict = await attempt(Author.objects.update(email = "same@example.com"))
    check conflict.isErr
    check conflict.err.isUniqueViolation
    await cleanup(db, dir)

  asyncTest "only and defer project columns and refuse a save":
    let (db, dir) = await freshDb()
    let ada = await author("Ada")
    discard await article(ada, "Notes", views = 10, rating = some(4.0))
    var params: seq[DbValue]
    let onlySql = Article.objects.only(id, title).selectSql(params)
    check "\"title\"" in onlySql
    check "\"views\"" notin onlySql
    let summaries = await Article.objects.only(title).all()
    check summaries.len == 1
    check summaries[0].id == 1
    check summaries[0].title == "Notes"
    check summaries[0].views == 0
    check summaries[0].rating.isNone
    expect QueryError:
      await summaries[0].save()
    let stored = await Article.objects.get(title = "Notes")
    check stored.get.views == 10
    let slim = await Article.objects.defer(rating).first()
    check slim.get.title == "Notes"
    check slim.get.views == 10
    check slim.get.rating.isNone
    let slimRow = slim.get
    expect QueryError:
      await slimRow.save()
    let dropped = await Article.objects.only(id, title, views).defer(views).first()
    check dropped.get.title == "Notes"
    check dropped.get.views == 0
    check (await Article.objects.only(title).count()) == 1
    check (await Article.objects.only(title).update(views = 5)) == 1
    let full = (await Article.objects.get(title = "Notes")).get
    check full.views == 5
    full.title = "Renamed"
    await full.save()
    let renamed = await Article.objects.get(title = "Renamed")
    check renamed.isSome
    await cleanup(db, dir)

  asyncTest "expand nests eager-loaded relations into JSON":
    let (db, dir) = await freshDb()
    let orbit = Publisher(name: "Orbit")
    await orbit.save()
    let ada = await author("Ada")
    ada.publisher = orbit
    await ada.save()
    let grace = await author("Grace")
    discard await article(ada, "Joined")
    discard await article(grace, "Alone")
    let plain = parseJson((await Article.objects.orderBy("title").all()).serialize())
    check "author" notin plain[0]
    check plain[0]["authorId"].kind == JString
    check plain[0]["authorId"].getStr.len > 0
    let mark = db.operationCount
    let rows = await Article.objects.expand(author.publisher).orderBy("title").all()
    check db.operationCount == mark + 1
    let encoded = parseJson(rows.serialize())
    check encoded.len == 2
    check encoded[0]["title"].getStr == "Alone"
    check encoded[0]["author"]["name"].getStr == "Grace"
    check encoded[0]["author"]["publisher"].kind == JNull
    check encoded[1]["title"].getStr == "Joined"
    check encoded[1]["author"]["name"].getStr == "Ada"
    check encoded[1]["author"]["publisher"]["name"].getStr == "Orbit"
    check encoded[1]["authorId"].getStr == encoded[1]["author"]["id"].getStr
    let omitted = parseJson(rows.omit(authorId).serialize())
    check "authorId" notin omitted[0]
    check omitted[1]["author"]["name"].getStr == "Ada"
    let response = json(rows)
    let body = parseJson(response.body)
    check body[1]["author"]["publisher"]["name"].getStr == "Orbit"
    let cached = await Article.objects.selectRelated("author").orderBy("title").all()
    let stamped = parseJson(cached.expand(author).serialize())
    check stamped[0]["author"]["name"].getStr == "Grace"
    check "publisher" notin stamped[0]["author"]
    await cleanup(db, dir)

  asyncTest "expand prefetches reverse relations as JSON arrays":
    let (db, dir) = await freshDb()
    let ada = await author("Ada")
    discard await article(ada, "First")
    discard await article(ada, "Second")
    let mark = db.operationCount
    let authors = await Author.objects.filter(name = "Ada").expand(articles).all()
    check db.operationCount == mark + 2
    let encoded = parseJson(authors.serialize())
    check encoded.len == 1
    check encoded[0]["articles"].len == 2
    var titles: seq[string]
    for item in encoded[0]["articles"]:
      titles.add item["title"].getStr
      check "author" notin item
    titles.sort()
    check titles == @["First", "Second"]
    await cleanup(db, dir)
