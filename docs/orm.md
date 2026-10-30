# fastorm

A Django-inspired ORM for Nim and SQLite with [Chronos](https://github.com/status-im/nim-chronos)
async APIs, macro-defined models, composable query sets and versioned migrations.

```nim
import fastnim/orm

model BaseModel {.abstract.}:
  id: UUIDField(primaryKey: true)
  createdAt: DateTimeField(autoNowAdd: true)

model User = ref BaseModel:
  name: CharField(maxLength: 19)

model Book:
  user: ForeignKey(User, onDelete: Cascade)
  name: CharField()

proc main() {.async.} =
  discard await openDatabase("app.sqlite3")
  discard await defaultDatabase().migrate("migrations")

  let ada = User(name: "Ada")
  await ada.save()

  let book = newBook()
  book.user = ada
  book.name = "Notes"
  await book.save()

  let books = await Book.objects.filter(name = "Notes").orderBy("-name").limit(10).all()
  let owner = await books[0].user()   # Future[Option[User]]
  echo owner.get.name

waitFor main()
```

## Setup

The ORM ships with FastNim. Import it with `import fastnim/orm`.

Requires Nim 2.2, Chronos 4.4, `db_connector`, and the system SQLite library
(`libsqlite3`).
`import fastnim/orm` also re-exports Chronos, `std/options` and `times.Time`. Use
Chronos only: do not mix it with `std/asyncdispatch`.

## Models

`model` declares a `ref object` type plus compile-time metadata used for SQL,
validation and migrations.

| Field | Nim type | SQLite column |
| --- | --- | --- |
| `UUIDField` | `UUID` | `TEXT` |
| `CharField(maxLength = 255, minLength = 0)` | `string` | `VARCHAR(n)` |
| `TextField(minLength = 0)` | `string` | `TEXT` |
| `IntegerField` | `int` | `INTEGER` |
| `FloatField` | `float` | `REAL` |
| `BooleanField` | `bool` | `INTEGER` (0/1) |
| `DateTimeField(autoNow, autoNowAdd)` | `Time` | `TEXT` (UTC ISO 8601, microseconds) |
| `DateField(autoNow, autoNowAdd)` | `Date` | `TEXT` (`YYYY-MM-DD`) |
| `TimeField(autoNow, autoNowAdd)` | `TimeOfDay` | `TEXT` (`HH:MM:SS.ffffff`) |
| `DurationField` | `TimeSpan` | `INTEGER` (microseconds) |
| `DecimalField(maxDigits, decimalPlaces)` | `Decimal` | `TEXT` |
| `JSONField` | `JsonNode` | `TEXT` |
| `BinaryField(maxLength = 0)` | `seq[byte]` | `BLOB` |
| `EmailField(maxLength = 254)` | `string` | `VARCHAR(n)` |
| `URLField(maxLength = 200)` | `string` | `VARCHAR(n)` |
| `FileField(uploadToDir = "", maxLength = 255)` | `string` | `VARCHAR(n)` |
| `SlugField(maxLength = 50)` | `string` | `VARCHAR(n)` |
| `ForeignKey(Model, onDelete = Cascade)` | key type of `Model` | key column + `REFERENCES` |
| `ManyToManyField(Model, relatedName = "")` | relation manager | implicit junction table |

Common options: `primaryKey`, `null` (the Nim type becomes `Option[T]`),
`unique`, `index`, `column: "name"`, `default: <constant>`, `validator`
and `choices`. Invalid combinations (say `minLength > maxLength`, two primary
keys, a nullable primary key, `onDelete: SetNull` without `null: true`,
`decimalPlaces` above `maxDigits`, unknown field types or options) are
compile errors.

`decimal("12.50")` builds a `Decimal` (`"00.50"` is stored as `"0.50"`).
`initDate`, `initTimeOfDay`, `timeSpan`, `timeSpanMillis` and
`timeSpanSeconds` build the other values. `TimeSpan` is the duration type;
Chronos already exports `Duration`. A `JSONField` default is a JSON string
literal. `null: true` on `JSONField` is SQL NULL, which is distinct from a
JSON `null`. `BinaryField` is base64 text when a model is serialized.
`EmailField`, `URLField` and `SlugField` are `CharField`s with a shape check:
one `@` and a dotted domain, an `http://` or `https://` prefix, or letters,
digits, hyphens and underscores. Build a slug from a title with Django-style
`slugify("Joel is a slug")` (`"joel-is-a-slug"`), also available from
`import fastnim` / `fastnim/orm`.

`FileField` stores a storage-relative key or path rather than requiring an HTTP URL.
`uploadToDir` records the relative destination prefix (for example, `"covers/books"`)
for local or external storage integrations. The multipart layer still owns receiving
the file; assign the retained local path or an external `StoredUpload.key` to the field.

`choices` limits a string, integer or float field to a list of literals.
On `CharField`, `EmailField`, `URLField` or `SlugField` it can instead name
an enum, and the Nim type of that field becomes the enum. The stored value
is the enum's name (`statusPublished`). A value outside `choices` fails
`save` with `ValidationError` and does not touch the database.

- Without a primary key, a model gets `id: IntegerField(primaryKey: true)`
  (auto-increment). UUID primary keys are generated on first save.
- The table name is the snake_cased model name; override with
  `model User {.table: "users".}:` or `Meta.table`.
- Field names map to snake_case columns (`createdAt` becomes `created_at`).
- `default:` values must be compile-time constants. They are used in the
  schema and by the generated `newModel()` constructor (`newBook()` above);
  plain `Book()` leaves fields zeroed.
- Model names must be unique within a program.

### Inheritance

`model Child = ref Parent:` makes `Child` a Nim subtype of `Parent`
(`ref object of Parent`) and gives it all of the parent's fields, followed by
its own. Each concrete model gets its own table with the full set of columns,
so there are no joins between parent and child tables.

```nim
model Timestamped {.abstract.}:
  createdAt: DateTimeField(autoNowAdd: true)
  updatedAt: DateTimeField(autoNow: true)

model Article = ref Timestamped:
  title: CharField(maxLength: 200)

model Animal:                 # concrete: has its own table too
  name: CharField()

model Dog = ref Animal:       # table "dog" has id, name, breed
  breed: CharField()
```

- `{.abstract.}` models have no table, migration entry, `objects` manager,
  or `save`. A child still inherits their fields, indexes, `uniqueTogether`,
  and `ordering`.
- A child can redeclare an inherited field to change its options
  (`title: CharField(maxLength: 10)`) as long as the Nim type stays the same.
  The change applies to the child only.
- Inheritance is single (as in Nim). Multi-table inheritance is not supported.
- Inherited validators are called from the child's module, so validators used
  by a base model in another module must be exported.

### Meta

`Meta:` sets options for the whole model:

```nim
model Story = ref Publishable:
  title: CharField()
  published: BooleanField()
  createdAt: DateTimeField()

  Meta:
    table: "stories"
    ordering: ["-createdAt", "title"]
    indexes:
      Index(fields: ["title", "published"], name: "{model}_title_pub")
      Index(fields: ["-createdAt"])
    uniqueTogether:
      ["title", "published"]
```

| Option | Effect |
| --- | --- |
| `table` or `dbTable` | Table name. A different `{.table.}` pragma is a compile error. Abstract models cannot set it. |
| `ordering` | Default query order, using the same `"-field"` descending prefix as `orderBy`. A later `orderBy` replaces it. `ordering: []` clears an inherited order. |
| `indexes` | Extra indexes. `Index` takes `fields`, and optionally `name` and `unique`. |
| `uniqueTogether` | Unique index on two or more fields. Repeat the list for several groups. |

Prefix a field with `-` (or pass `"-createdAt"`) to index it descending. `{model}` in an index name becomes that concrete model's snake_case name, which keeps an index inherited from an abstract base unique per child. Index names are global in SQLite, so two models cannot share one. A single-column `index: true` is unchanged; an identical `Index` is not emitted a second time.

### Validation

`save` runs `validate(model)` first and raises `ValidationError` (with
`errors: seq[FieldIssue]`) without touching the database if anything fails.
Built-in checks cover `maxLength`/`minLength`. A custom validator takes the
field's value and returns an empty string when it is valid, or an error
message otherwise:

```nim
proc nameValidator(value: string): string =
  if value.len > 0 and value[0].isLowerAscii: "must start with a capital letter" else: ""

model User:
  name: CharField(maxLength: 19, minLength: 2, validator: nameValidator)
```

For `null: true` fields the validator receives the `Option[T]`. Database
constraints (unique, foreign keys) are reported as `DatabaseError`.

### Input objects

`typeFrom` builds a plain object from a model's columns, which is what a
request body needs. `.ignore` drops fields the client does not send, such as
a generated primary key. A foreign key is stored under its key name
(`author` becomes `authorId`). `toModel` copies the object onto a new model;
ignored fields keep the model defaults.

```nim
typeFrom(CreateAuthor, Author.ignore(id))
typeFrom(CreateBook, Book.ignore(id))

let author = body.toModel(Author)
await author.save()
```

`Author.id` means the same thing as `id`. An unknown model or field name is a compile error. `typeFrom` writes an ordinary object type, which is what a JSON decoder reflects.

### Serializers

`serialize` writes a model, a `seq` of models, or an `Option[Model]` as JSON. `.omit` drops further fields, by the field name or the stored foreign-key name. `.expand` nests eager-loaded relations beside the key column. Both accept multiple names, a `[a, b]` list, or chained calls; QuerySet forms apply after `all()` / `get()`.

```nim
echo author.serialize()
echo author.omit(id, createdAt).serialize()
echo author.omit([id, createdAt]).serialize()
echo book.expand(author).serialize()
let authors = await Author.objects.all()
echo authors.omit(createdAt).serialize()
ok await Book.objects.expand(author, publisher).omit(publisherId).all()
ok await Book.objects.expand(author).expand(publisher).omit([publisher, publisherId]).all()
```

FastNim's `ok` and `created` accept the model itself and encode it the same way. `.serialize()` returns a string, which does not match a route declared as `Author`.

```nim
created author
created author.omit(id)
ok authors
```

A foreign key is written as its key (`authorId`). `expand(author)` keeps `authorId` and adds a nested `author` object (or `null` when the key is empty). A reverse `expand(articles)` writes an array. UUIDs and datetimes are strings. Null fields are JSON `null`. `none(Author)` and a nil model are `null`. OpenAPI for `responses = @[(200, seq[Book])]` still describes the columns only.

### Relations

`user: ForeignKey(User)` stores the referenced key in `book.userId` and
generates:

- `book.user = someUser`, which sets `userId`
- `await book.user()`, which returns `Future[Option[User]]` (`none` for a null
  key)

`onDelete` is enforced by SQLite (`PRAGMA foreign_keys` is on for every
connection): `Cascade`, `SetNull`, `Restrict` and `NoAction`. Foreign key
columns are indexed automatically.

The reverse side is an accessor named after the model by default (`Article`
pointing at `Author` gives `author.articles()`). Set `relatedName` when that
collides or when one model has two foreign keys to the same target. On an
abstract base, include `{model}` so each concrete child gets its own name
(`relatedName: "{model}s"`). `relatedName: ""` turns the reverse accessor off.

```nim
let books = await ada.articles()          # Future[seq[Article]]
await Book.objects.selectRelated("author").all()
await Author.objects.prefetchRelated("articles.chapters").all()
ok await Book.objects.expand(author.publisher).all()
```

### Many-to-many relations

`ManyToManyField` creates an implicit junction table and exposes an async
manager on both sides of the relation. It is virtual: it does not add a column
to either model.

```nim
model Author:
  name:
    CharField(maxLength: 80)

model Book:
  title:
    CharField(maxLength: 200)
  authors:
    ManyToManyField(Author, relatedName: "books")
```

Both objects must be saved before changing the relation:

```nim
await book.authors.add(ada, grace)       # duplicate pairs are ignored
let authors = await book.authors.all()
let books = await ada.books.all()        # reverse manager
let count = await book.authors.count()
let hasAda = await book.authors.contains(ada)
discard await book.authors.remove(ada)   # number of links removed
discard await book.authors.clear()       # number of links removed
```

The default junction-table name is `<owner_table>_<field_name>` (for example,
`book_authors`). Override it with `table: "library_book_authors"`. The table
contains foreign keys to both models, a unique constraint on the pair, and
uses `ON DELETE CASCADE`, so deleting either object removes its links. A
self-relation is directional and receives distinct `from_` and `to_` columns.
Set `relatedName: ""` to disable the reverse manager. As with foreign keys,
`{model}` in `relatedName` or `table` is replaced for an inherited relation.

Many-to-many managers currently load through `all()` and are separate from
the `selectRelated`, `prefetchRelated`, and `expand` path APIs.

## Connections

```nim
let db = await openDatabase("app.sqlite3")   # also becomes the default database
let other = await openDatabase(":memory:", setDefault = false)
await user.save(other)
let rows = await User.objects.withDb(other).all()
await other.close()
```

SQLite's C API is blocking, so each connection runs on a dedicated worker
thread and processes requests one at a time. A `Database` is a handle onto a
pool of those connections (`openDatabase(path, maxConnections = 4)`). The
main connection serves every statement that is not inside a transaction;
`atomic` leases another one, up to `maxConnections - 1` transactions at
once. The pool opens in WAL mode, so a reader on the main connection keeps
going while a transaction holds the write lock. Every API returns a Chronos
future and never blocks the event loop. This is non-blocking for the caller,
but SQLite I/O itself is not natively asynchronous.

A `":memory:"` database (and an unnamed temporary one) is private to the
connection that opened it, so that pool stays at one connection and
transactions on it queue instead of running side by side.

Lower level: `db.execute(sql, params)`, `db.query(sql, params)` and
`db.batch(statements)` (one transaction, or a savepoint when `db` is already
inside one) take `seq[DbValue]` parameters (`toDbValue(x)`). Parameters are
always bound, never interpolated.

## Transactions

`atomic` runs a block as one transaction. It commits when the block finishes
and rolls back if the block raises or the task is cancelled. The handle is
injected as `tx`; pass it to every write and read that should take part:

```nim
atomic db:
  let ada = User(name: "Ada")
  await ada.save(tx)
  let book = newBook()
  book.user = ada
  book.name = "Notes"
  await book.save(tx)

atomic:   # the default database
  discard await Book.objects.withDb(tx).filter(name = "Draft").delete()
```

An `atomic tx:` inside the block becomes a savepoint. Rolling the inner
block back leaves the outer transaction open with its own writes intact.

The same handle is available without the template:

```nim
let tx = await db.beginTransaction()
try:
  await user.save(tx)
  await tx.commit()
except CatchableError as e:
  await tx.rollback()
  raise e
```

`commit` on a nested handle releases its savepoint; `rollback` undoes
everything since that savepoint. `rollback` on a handle that already
finished does nothing, so it is safe after a failed `commit`.
`inTransaction` is true while the handle is still open. `close` rolls back
any transaction that is still open.

A statement that omits `tx` (`await user.save()`, `User.objects.all()`) runs
on the main connection, outside the transaction, and under WAL it does not
see the transaction's uncommitted rows. Build with `-d:fastormStrictTx` to
make such a write raise instead.

Two transactions that both want the write lock wait on SQLite's busy
timeout (5 seconds). The loser raises `DatabaseError`; `attempt` classifies
that as `isBusy`, which is the signal to retry the whole block.

`selectForUpdate()` requires the query to run on a transaction handle and
raises `QueryError` otherwise. SQLite has no `FOR UPDATE` clause; FastORM
opens every transaction with `BEGIN IMMEDIATE`, which already holds the
write lock, so the rows a transaction reads stay stable until it commits:

```nim
atomic db:
  let accounts = await Account.objects.withDb(tx).selectForUpdate().all()
  accounts[0].balance += 10
  await accounts[0].save(tx)
```

## Queries

`Model.objects` is an immutable `QuerySet[Model]`. Every method returns a new
query set, and nothing runs until you await an evaluating call.

```nim
let recent = Article.objects.filter(published = true).orderBy("-createdAt")
let page = await recent.offset(20).limit(10).all()
let n = await recent.count()
```

| Call | Result |
| --- | --- |
| `all()` | `Future[seq[T]]`. An empty seq means no match. |
| `get(conditions...)` | `Future[Option[T]]`: `none` for no match; raises `MultipleObjectsReturned` for several |
| `first()` | `Future[Option[T]]` |
| `count()`, `exists()` | `Future[int]`, `Future[bool]` |
| `update(field = value, ...)` | `Future[int]` rows changed (bulk, no validation). `F(field)` assigns or computes from a column |
| `delete()` | `Future[int]` rows deleted |
| `filter(...)`, `exclude(...)` | narrowed `QuerySet[T]` |
| `only(...)`, `defer(...)` | `QuerySet[T]` that selects a subset of columns |
| `selectRelated(...)`, `prefetchRelated(...)` | `QuerySet[T]` with eager loading |
| `selectForUpdate()` | `QuerySet[T]` that raises `QueryError` unless evaluated on a transaction handle |
| `orderBy("field", "-other")`, `limit(n)`, `offset(n)`, `withDb(db)` | `QuerySet[T]`. `orderBy` replaces `Meta.ordering` |

`Model.filter(...)`, `Model.exclude(...)`, `Model.get(...)` and `Model.all()`
are shortcuts for `Model.objects....`; `model.save()` and `model.delete()`
work on instances.

### Bulk updates with `F`

`update` writes every matching row in one statement and skips validation.
A literal assigns a constant; `F(field)` names a column so the database
can compute the new value without a read-modify-write:

```nim
await Article.filter(published = true).update(views = F(views) + 1)
await Article.filter(title = "Draft").update(rating = F(views) / 2)
await Article.objects.update(views = F(views), rating = F(views))
```

`F` is only valid inside `update`. It supports `+`, `-`, `*`, `/`, unary
`-`, and a bare column (`rating = F(views)`). The destination and the `F`
field must be `IntegerField` or `FloatField`. An integer destination
accepts integer fields and values; a float destination also accepts
integers. Division always produces a float, so it cannot be assigned to
an `IntegerField`. One expression may mention only one `F()` field, and
that field must belong to the model being updated — not a related model.
Unknown fields, non-numeric types, and illegal operators are compile
errors.

### Aggregates

Use named Django-style aggregate expressions on any filtered or sliced query
set. `Count`, `Sum`, `Avg`, `Min`, and `Max` are supported. `Sum` and `Avg`
require an integer or float field; `Count` also accepts `Count("*")`.

```nim
let stats = await Article.filter(published = true).aggregate(
  articles = Count(id),
  totalViews = Sum(views),
  averageViews = Avg(views),
  firstTitle = Min(title))

echo stats.aggregateInt("articles")
echo stats.aggregateFloat("averageViews")
```

`aggregate` returns `Future[AggregateResult]`, a mapping of the supplied
aliases to `DbValue`s. `aggregateInt`, `aggregateFloat`, and `aggregateValue`
validate and unpack the result values. `COUNT` is zero on an empty result; the
other aggregates are `dvNull` when no non-null input value exists. Aggregates
retain filters, limits, and offsets, but ignore ordering and eager-loading
directives.

Conditions are checked at compile time against the model's fields, and all
conditions in one call must hold:

```nim
Article.filter(title = "Hi")                  # exact (null-aware for Option values)
Article.filter(views >= 10, views < 100)      # ==  !=  <  <=  >  >=
Article.filter(title in ["a", "b"])           # also: notin, title.isIn = s, title.notIn = s
Article.filter(rating.isNull = true)
Article.filter(title.icontains = "nim")       # contains, icontains, startsWith,
                                              # istartsWith, endsWith, iendsWith, iexact
Article.filter(author = ada)                  # foreign keys accept a model or its key
Article.exclude(title.icontains = "draft")
Article.filter(title == "A" or views > 10)    # OR; `==` because `=` names an argument
Article.filter(any(title = "A", title = "B"), published = true)
Article.filter(all(published = true, views > 10) or featured = true)
Article.filter(author.name = "Ada")           # chase through a foreign key
Article.filter(author.publisher.name.icontains = "orbit")
```

Arguments of one `filter` call are combined with AND. `or` / `any(...)`
match if any condition holds; `and` / `all(...)` group conditions inside an
`or`. `exclude(a or b)` removes rows that match either condition.

Case-insensitive lookups use SQLite's `LIKE`/`NOCASE`, which only fold ASCII
letters.

### Filtering through relations

A dotted field path walks one or more forward foreign keys before applying a
condition to the related model's field, e.g. `author.name = "Ada"` or
`author.publisher.name.icontains = "orbit"`. Lookups, comparison operators,
and `or`/`any`/`all` all work the same way as on the model's own fields.
Only forward (foreign-key) relations can be chased, not reverse ones — same
restriction as `selectRelated`.

```nim
let ada = await Article.filter(author.name = "Ada").first()
await Article.filter(author.name = "Ada").update(published = true)
await Article.filter(author.name = "Grace").delete()
```

Each relation used this way is joined once per query (not once per filter),
and — like `selectRelated` — that join also fills the relation cache, so
`article.author()` on a result from such a query does not run another query.
`update` and `delete` can't contain a `JOIN` in SQLite, so a relation-chasing
filter on either runs as a subquery (`WHERE pk IN (SELECT ...)`) instead.

### Eager loading

`selectRelated` follows foreign keys with a `LEFT JOIN`, so `book.author()`
is already filled in and does not query again. Paths are dotted:
`selectRelated("author.publisher")` or `selectRelated(author.publisher)`.
Reverse relations are not joins; use `prefetchRelated` for those (and for
foreign keys when a separate batched `IN` query is preferable). Each step of
a prefetch path is one query for the whole result:

```nim
let authors = await Author.objects.prefetchRelated("articles.chapters").all()
let books = await authors[0].articles()
let chapters = await books[0].chapters()
```

`expand` does the same load and also nests the cached objects into JSON
(`ok`, `created`, `serialize`, `toJson`). Forward-only paths join;
a reverse hop prefetches. Dotted paths write every prefix, so
`expand(author.publisher)` writes `author` and `author.publisher`.
Remaining suffixes are consumed while walking, so
`expand(author.articles)` serializes those articles as columns only.

```nim
ok await Book.objects.expand(author).all()
ok await Book.objects.expand(author, publisher).all()
ok await Book.objects.expand(author).expand(publisher).all()
ok await Book.objects.expand(author.publisher).all()
ok await Author.objects.expand(articles).all()
```

`db.operationCount` is how many statements the pool has submitted, across
every connection. `BEGIN`, `COMMIT`, `SAVEPOINT`, and `ROLLBACK` are not
counted.

### Projection

`only` and `defer` select fewer columns on the root model. The primary
key is always included, even when omitted, so the instance still has an
identity. `only` replaces any previous projection; `defer` removes fields
from every column, or from an earlier `only`.

```nim
let summaries = await Article.objects.only(id, title).all()
let withoutRating = await Article.objects.defer(rating).all()
let titles = await Article.objects.only(id, title, views).defer(views).all()
```

Public Nim fields cannot intercept reads, so an omitted field keeps its
zero or default value (`0`, `""`, `none`). Saving a projected instance
raises `QueryError` rather than writing those defaults back. Constructed
models and fully selected query results still save as before.
`count`, `exists`, `aggregate`, `update`, and `delete` ignore the
projection and still see every matching row.

`only` and `defer` cannot be combined with `selectRelated`,
`prefetchRelated`, or `expand`; either order is a compile error.

### Handling errors without exceptions

By default every FastORM call that can fail raises: `DatabaseError`,
`ValidationError`, `QueryError`, `MultipleObjectsReturned`, or
`MigrationError`. `attempt(...)` wraps any single call instead, turning that
exception into a classified result:

```nim
let saved = await attempt(author.save())
if saved.isOk:
  created author
elif saved.err.isUniqueViolation:
  conflict initApiError("author_exists", "an author with that name already exists")
elif saved.err.isValidation:
  unprocessableContent validationError(saved.err.issues)
else:
  raise saved.err.cause   # anything else: let it propagate
```

`attempt(fut: Future[T])` returns a `FastormResult[T]` (`FastormVoidResult`
for `Future[void]` calls like `save()`/`delete()`), with `isOk`/`isErr`,
`.value`/`.err`, `get()` (the value, or re-raises on error), and
`valueOr(default)`. The error is a `FastormOutcomeError` with `.kind`,
`.message`, `.cause` (the original exception), `.issues` (the
`seq[FieldIssue]` when `.kind == ekValidation`), and classifier procs:
`isUniqueViolation`, `isForeignKeyViolation`, `isNotNullViolation`,
`isCheckViolation`, `isBusy`, `isValidation`. Unique/foreign-key/not-null/check
violations, and a lock held past the busy timeout (`isBusy`), are classified
from SQLite's extended result code (captured on the connection
automatically), not by pattern-matching the error message.

**Can this force the caller to check the error?** Not fully — no mainstream
language without Rust-style linear types can. Nim's rule that a non-`void`
proc result must be used or explicitly `discard`ed means the whole result of
`attempt(...)` can't be silently dropped, but nothing stops reaching into
`.value` while ignoring `.err` (and even Rust's `Result` is only
`#[must_use]`-*warned* by default, not a hard error — `let _ = result;`
compiles there too). What `FastormResult` gives you instead is a loud
failure on misuse: `value`/`err` are fields of a `case` object, so reading
the wrong one for the current `ok` branch panics immediately — instead of
quietly handing back something that looks like valid-but-wrong data (an
empty `seq` is indistinguishable from "zero rows" vs. "the query failed").

### Catching N+1 queries at compile time

Wrap a block of code in `checkNPlusOne` to statically catch the classic
mistake of calling a relation accessor once per loop iteration instead of
eager-loading it:

```nim
checkNPlusOne:
  for article in await Article.objects.all():
    let author = await article.author()   # one query per article!
```

By itself `checkNPlusOne` always compiles the block unchanged — it's a
no-op unless you build with `-d:raiseNPlusOne`, in which case any findings
fail the build and list every offending call site:

```sh
nim c -d:raiseNPlusOne myapp.nim
```

```
myapp.nim(5, 5) Error: fastorm: possible N+1 queries (-d:raiseNPlusOne):
  myapp.nim(6): `article.author()` inside a loop may run one query per row.
  Add `.selectRelated("author")` or `.prefetchRelated("author")` to the
  query that produced `article`.
```

Eager-loading the relation on the query that produced the loop variable
silences the finding, and nested prefetch paths are understood too — a loop
over `author.articles()` is covered by `prefetchRelated("articles.chapters")`
on the query that produced `author`:

```nim
checkNPlusOne:
  for article in await Article.objects.selectRelated("author").all():
    let author = await article.author()    # fine: joined already

  for author in await Author.objects.prefetchRelated("articles.chapters").all():
    for article in await author.articles():      # fine: prefetched
      for chapter in await article.chapters():   # fine: prefetched
        discard chapter.title
```

This is a syntactic, best-effort scan (it has no type information): it only
recognizes `for v in <query>:` loops and relation calls written directly as
`v.relationName(...)` or `await v.relationName(...)`. It can miss a loop
variable aliased through an intermediate `let`, and — rarely — flag an
unrelated method that happens to share a relation's name. Leave
`-d:raiseNPlusOne` off in normal builds and turn it on in CI or a pre-commit
check if you want it enforced.

## Migrations

`makemigrations` writes a Nim module, `migrations/m0001_initial.nim`, with
an `up` section, a `down` section, and a snapshot of the schema afterwards.
Importing `migrations/all` compiles those modules into the binary.
`migrate` applies the compiled migrations and does not read migration files
at startup, so a deploy can ship the binary alone.

```nim
import fastnim/orm

migration "0001_initial", "Create the post table":
  up:
    createTable "post":
      column "id", "INTEGER", primaryKey = true, notNull = true
      column "title", "VARCHAR(100)", notNull = true
  down:
    dropTable "post"
  snapshot:
    table "post":
      column "id", "INTEGER", primaryKey = true, notNull = true
      column "title", "VARCHAR(100)", notNull = true
```

`makemigrations` needs the models, and every later command needs the
migrations, compiled into the same program. Projects created by `fastnim init`
already have `src/manage.nim`, `src/settings.nim`, and an empty
`src/migrations/all.nim`, so use the main CLI directly:

```sh
nimble setup
nimble bootstrap
fastnim makemigrations --name:add_slug
nimble migrate
fastnim showmigrations
fastnim sqlmigrate 0002
```

The generated `.nimble` file provides `nimble bootstrap` for first-time
generation and application, plus separate `nimble makemigrations` and
`nimble migrate` tasks. `nimble setup` remains Nimble's built-in command for
creating `nimble.paths`.

Migration application is deliberately separate from server startup. Running
the application never modifies its schema automatically.

For a hand-built project, the equivalent management entrypoint is:

```nim
import fastnim/orm
import myapp/models          # every module that declares models
import myapp/migrations/all  # after the first makemigrations creates it

when isMainModule:
  quit runCli()
```

Create `migrations/all.nim` containing `discard` before the first command.
`makemigrations` rewrites that index with imports for every migration. A
migration file that is not imported is refused: `migrate` would otherwise skip
it.

```sh
nim c -r manage.nim makemigrations                 # writes the next migration
nim c -r manage.nim makemigrations --name:add_slug
nim c -r manage.nim migrate --db:app.sqlite3       # or: FASTORM_DB=app.sqlite3
nim c -r manage.nim showmigrations
nim c -r manage.nim sqlmigrate 0002                # print the SQL
```

From code, use `makeMigrations("migrations")` and
`await db.migrate("migrations")`. Rebuild after adding or editing a
migration so the binary contains the copy `migrate` will run. From code in
the same process, `makeMigrations` also registers the new module, and
`migrate` can apply it before that rebuild.

- `makemigrations` diffs the models against the latest compiled snapshot.
  It generates new tables, new columns (a unique column becomes an added
  column plus a unique index) and index changes. New tables and columns
  produce a matching `down`.
- Destructive or ambiguous changes (removed tables or columns, changed column
  definitions, new `NOT NULL` columns without a default) are refused with a
  list of what changed. Run `makemigrations --empty`, then edit `up` and
  `down` by hand (`runSql`, `dropColumn`, `renameColumn`, `dropTable`,
  `renameTable`, `dropIndex`, `createIndex`, `addColumn`, `createTable`).
  Keep `snapshot` equal to the schema `up` leaves behind, or the next diff
  repeats the same change.
- `migrate` runs each pending migration's `up` in its own transaction and
  records it in `fastorm_migrations` with a checksum of that SQL and the
  snapshot. A migration that fails is rolled back entirely. Rebuilding with
  a changed `up` or snapshot, or running a binary that no longer contains an
  applied migration, is rejected with `MigrationError`. Editing `down` does
  not change the checksum. `migrate` does not run `down`.

## Tests

```sh
nimble test
```

The tests use temporary SQLite files and cover metadata, inheritance, CRUD,
chaining, lookups, `OR` conditions, relation-chasing filters, `selectRelated`,
`prefetchRelated`, `expand`, `only`/`defer`, `F()` updates, field types
(`Decimal`, `Date`, `TimeOfDay`, `TimeSpan`, JSON, binary, email, URL,
slug, choices), `checkNPlusOne`,
`attempt`/error classification, validation, relations, concurrency,
transactions (commit, rollback, savepoints, cancellation, `selectForUpdate`),
migration planning and application, checksums, rollbacks, the CLI and
compile-time errors.

## MVP limitations

- SQLite only. Each connection has one worker thread. A file database pools
  up to `maxConnections` of them (default 4) in WAL mode; a `":memory:"`
  database stays on one connection and serializes its transactions.
- Automatic migrations are additive only (see above).
- `DateTimeField` stores microsecond precision in UTC.
