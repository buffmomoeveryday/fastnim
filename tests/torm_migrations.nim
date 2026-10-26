import std/[os, osproc, tempfiles, strutils, options]
import chronos/unittest2/asynctests
import fastnim/orm

# Successive versions of one table, used to simulate editing a model.
model Post:
  title:
    CharField(maxLength: 100)

model PostV2 {.table: "post".}:
  title:
    CharField(maxLength: 100)
  summary:
    TextField(null: true)
  slug:
    CharField(unique: true, null: true)
  score:
    IntegerField(default: 0, index: true)

model PostV3 {.table: "post".}:
  body:
    TextField()

model Owned {.abstract.}:
  id:
    UUIDField(primaryKey: true)
  owner:
    CharField()

model Doc = ref Owned:
  post:
    ForeignKey(Post, onDelete: Cascade)

model Labeled:
  name:
    CharField()
  score:
    IntegerField()
  Meta:
    indexes:
      Index(fields: ["-score", "name"], name: "labeled_score")
    uniqueTogether:
      ["name", "score"]

proc v1(): Snapshot =
  snapshotOf([modelMeta(Post)])

proc v2(): Snapshot =
  snapshotOf([modelMeta(PostV2)])

proc v3(): Snapshot =
  snapshotOf([modelMeta(PostV3)])

proc tempDir(): string =
  createTempDir("fastorm_", "_migrations")

proc kindsOf(ops: seq[Operation]): seq[OperationKind] =
  for op in ops:
    result.add op.kind

proc nimLiteral(s: string): string =
  result = "\""
  for c in s:
    if c == '\\':
      result.add "\\\\"
    elif c == '"':
      result.add "\\\""
    else:
      result.add c
  result.add "\""

proc compileMigrations(dir, project: string): tuple[output: string, exitCode: int] =
  ## Compiles the generated modules and prints the checksums they register.
  let runner = dir / "roundtrip.nim"
  var reports = ""
  for folder in ["post", "labeled", "docs"]:
    reports.add "report(" & nimLiteral(dir / folder) & ")\n"
  writeFile(
    runner,
    """
import std/strutils
import fastnim/orm
import ./post/all
import ./labeled/all
import ./docs/all

proc report(dir: string) =
  for m in loadMigrations(dir):
    stdout.writeLine "CHECK ", m.checksum
    for sql in sqlDown(m):
      stdout.writeLine "DOWN ", m.name, " ", sql.replace("\n", " ")

""" &
      reports,
  )
  var cmd =
    "nim c --colors:off --hints:off --warnings:off --nimcache:" &
    quoteShell(dir / "nimcache") & " --outdir:" & quoteShell(dir)
  for line in readFile(project / "nimble.paths").splitLines:
    if line.len > 0:
      cmd.add " "
      cmd.add line
  cmd.add " -r "
  cmd.add quoteShell(runner)
  execCmdEx(cmd)

suite "migration planning":
  test "initial migration and no-op detection":
    let dir = tempDir()
    let path = makeMigrations(dir, snapshot = v1())
    check path.isSome
    check path.get.extractFilename == "m0001_initial.nim"
    let ops = loadMigrations(dir)[0].operations
    check ops.len == 1
    check ops[0].kind == opCreateTable
    check ops[0].table == "post"
    let source = readFile(path.get)
    check "migration \"0001_initial\", \"Create the post table\":" in source
    check "createTable \"post\":" in source
    check "dropTable \"post\"" in source
    check "import ./m0001_initial" in readFile(dir / "all.nim")
    check sqlDown(loadMigrations(dir)[0]).join("\n").contains("DROP TABLE \"post\"")
    check makeMigrations(dir, snapshot = v1()).isNone
    removeDir(dir)

  test "additive changes are generated":
    let dir = tempDir()
    discard makeMigrations(dir, snapshot = v1())
    let path = makeMigrations(dir, snapshot = v2()).get
    check path.extractFilename == "m0002_auto.nim"
    check kindsOf(loadMigrations(dir)[1].operations) ==
      @[opAddColumn, opAddColumn, opCreateIndex, opAddColumn, opCreateIndex]
    let sql = sqlFor(loadMigrations(dir)[1]).join("\n")
    check "ADD COLUMN \"score\" INTEGER NOT NULL DEFAULT 0" in sql
    check "CREATE UNIQUE INDEX \"post_slug_uniq\"" in sql
    removeDir(dir)

  test "destructive changes need a hand-written migration":
    let dir = tempDir()
    discard makeMigrations(dir, snapshot = v1())
    try:
      discard makeMigrations(dir, snapshot = v3())
      check false
    except MigrationError as e:
      check "post.title was removed" in e.msg
      check "post.body is NOT NULL without a default" in e.msg
    check loadMigrations(dir).len == 1
    let manual =
      makeMigrations(dir, name = "Rework post", empty = true, snapshot = v3())
    check manual.get.extractFilename == "m0002_rework_post.nim"
    check loadMigrations(dir)[1].operations.len == 0
    check "Hand-written migration" in readFile(manual.get)
    check makeMigrations(dir, snapshot = v3()).isNone
    removeDir(dir)

  test "generated source keeps index direction":
    let dir = tempDir()
    let path = makeMigrations(dir, snapshot = snapshotOf([modelMeta(Labeled)])).get
    let source = readFile(path)
    check "createIndex \"labeled_score\", \"labeled\", @[\"score\", \"name\"], descending = @[true, false]" in
      source
    check "index \"labeled_score\", @[\"score\", \"name\"], descending = @[true, false]" in
      source
    removeDir(dir)

  test "generated modules compile and register the same migration":
    let dir = tempDir()
    let project = currentSourcePath().parentDir.parentDir
    discard makeMigrations(dir / "post", snapshot = v1())
    discard makeMigrations(dir / "post", snapshot = v2())
    discard makeMigrations(dir / "post", empty = true, snapshot = v2())
    discard makeMigrations(dir / "labeled", snapshot = snapshotOf([modelMeta(Labeled)]))
    discard makeMigrations(
      dir / "docs", snapshot = snapshotOf([modelMeta(Post), modelMeta(Doc)])
    )
    let (output, code) = compileMigrations(dir, project)
    if code != 0 or "CHECK " notin output:
      echo output
    check code == 0
    for folder in ["post", "labeled", "docs"]:
      for m in loadMigrations(dir / folder):
        check ("CHECK " & m.checksum) in output
        for sql in sqlDown(m):
          check ("DOWN " & m.name & " " & sql.replace("\n", " ")) in output
    removeDir(dir)

  test "migrations on disk must be compiled in":
    let dir = tempDir()
    discard makeMigrations(dir, snapshot = v1())
    forgetMigrations(dir)
    expect MigrationError:
      discard loadMigrations(dir)
    removeDir(dir)

  test "Meta indexes become SQL":
    let planned = diff(Snapshot(), snapshotOf([modelMeta(Labeled)]))
    check planned.unsupported.len == 0
    var sql: seq[string]
    for op in planned.ops:
      for statement in sqlFor(op):
        sql.add statement
    let text = sql.join("\n")
    check "CREATE INDEX \"labeled_score\" ON \"labeled\" (\"score\" DESC, \"name\")" in
      text
    check "CREATE UNIQUE INDEX \"labeled_name_score_uniq\" ON \"labeled\" (\"name\", \"score\")" in
      text

  test "snapshots flatten inheritance and record foreign keys":
    let snap = snapshotOf([modelMeta(Post), modelMeta(Doc)])
    check snap.tables.len == 2
    let doc = snap.tables[0]
    check doc.name == "doc"
    var cols: seq[string]
    for c in doc.columns:
      cols.add c.name
    check cols == @["id", "owner", "post_id"]
    check doc.columns[2].refTable == "post"
    check doc.columns[2].onDelete == "CASCADE"
    check doc.indexes[0].name == "doc_post_id_idx"

suite "applying migrations":
  asyncTest "migrate applies pending migrations once":
    let dir = tempDir()
    let db = await openDatabase(dir / "db.sqlite3")
    discard makeMigrations(dir / "m", snapshot = v1())
    check (await db.migrate(dir / "m")) == @["0001_initial"]
    check (await db.migrate(dir / "m")).len == 0
    await Post(title: "kept").save()
    discard makeMigrations(dir / "m", snapshot = v2())
    check (await db.migrate(dir / "m")) == @["0002_auto"]
    let posts = await PostV2.objects.all()
    check posts.len == 1
    check posts[0].title == "kept"
    check posts[0].score == 0
    check posts[0].summary.isNone
    let statuses = await db.showMigrations(dir / "m")
    check statuses.len == 2
    check statuses[0].applied and statuses[1].applied
    await db.close()
    removeDir(dir)

  asyncTest "hand-written operations":
    let dir = tempDir()
    let db = await openDatabase(dir / "db.sqlite3")
    discard makeMigrations(dir / "m", snapshot = v1())
    discard makeMigrations(dir / "m", empty = true, snapshot = v1())
    var m = loadMigrations(dir / "m")[^1]
    m.operations = @[
      runSql("CREATE TABLE extra (x INTEGER)", "INSERT INTO extra VALUES (7)"),
      renameColumn("extra", "x", "y"),
    ]
    registerMigration(m, dir / "m")
    discard await db.migrate(dir / "m")
    let res = await db.query("SELECT y FROM extra")
    check res.rows[0][0].i == 7
    await db.close()
    removeDir(dir)

  asyncTest "failed migrations roll back":
    let dir = tempDir()
    let db = await openDatabase(dir / "db.sqlite3")
    discard makeMigrations(dir / "m", empty = true, snapshot = v1())
    var m = loadMigrations(dir / "m")[0]
    m.operations = @[runSql("CREATE TABLE a (x INTEGER)", "NOT SQL")]
    registerMigration(m, dir / "m")
    expect MigrationError:
      discard await db.migrate(dir / "m")
    let tables = await db.query("SELECT name FROM sqlite_master WHERE name = 'a'")
    check tables.rows.len == 0
    let statuses = await db.showMigrations(dir / "m")
    check not statuses[0].applied
    await db.close()
    removeDir(dir)

  asyncTest "edited or missing applied migrations are rejected":
    let dir = tempDir()
    let db = await openDatabase(dir / "db.sqlite3")
    discard makeMigrations(dir / "m", snapshot = v1())
    discard await db.migrate(dir / "m")
    # Re-registering the same operations leaves the checksum alone.
    registerMigration(loadMigrations(dir / "m")[0], dir / "m")
    check (await db.migrate(dir / "m")).len == 0
    var edited = loadMigrations(dir / "m")[0]
    edited.operations = @(edited.operations)
    edited.operations[0].table = "renamed"
    registerMigration(edited, dir / "m")
    try:
      discard await db.migrate(dir / "m")
      check false
    except MigrationError as e:
      check "modified after it was applied" in e.msg
    forgetMigrations(dir / "m")
    expect MigrationError:
      discard await db.migrate(dir / "m")
    await db.close()
    removeDir(dir)

suite "command line":
  test "makemigrations, migrate, showmigrations and sqlmigrate":
    let dir = tempDir()
    discard makeMigrations(dir / "m", snapshot = v1())
    let db = "--db:" & dir / "db.sqlite3"
    let mdir = "--dir:" & dir / "m"
    check runCli(@["showmigrations", db, mdir]) == 0
    check runCli(@["migrate", db, mdir]) == 0
    check runCli(@["sqlmigrate", "0001", mdir]) == 0
    check runCli(@["sqlmigrate", "9999", mdir]) == 1
    check runCli(@["bogus"]) == 2
    removeDir(dir)
