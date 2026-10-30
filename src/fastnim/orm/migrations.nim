## Versioned schema migrations.
##
## `makeMigrations` writes a Nim module (`migrations/m0001_initial.nim`) with
## an `up` and a `down` section. Importing `migrations/all` compiles those
## modules into the binary and registers them; `migrate` applies the
## registered migrations and does not read migration files at startup.
## Each applied migration is recorded with a checksum of its operations, so
## editing one after it was applied is rejected.

import std/[os, strutils, algorithm, options, times, tables, macros]
import chronos
import ./[values, fields, sqlite]

const historyTable* = "fastorm_migrations"

type
  ColumnDef* = object
    name*: string
    sqlType*: string
    primaryKey*: bool
    notNull*: bool
    unique*: bool
    default*: string ## SQL literal; empty means no default
    refTable*: string
    refColumn*: string
    onDelete*: string

  IndexDef* = object
    name*: string
    table*: string
    columns*: seq[string]
    descending*: seq[bool] ## parallel to columns; empty means all ascending
    unique*: bool

  TableDef* = object
    name*: string
    columns*: seq[ColumnDef]
    indexes*: seq[IndexDef]

  Snapshot* = object
    tables*: seq[TableDef]

  OperationKind* = enum
    opCreateTable = "CreateTable"
    opAddColumn = "AddColumn"
    opCreateIndex = "CreateIndex"
    opDropIndex = "DropIndex"
    opDropTable = "DropTable"
    opDropColumn = "DropColumn"
    opRenameTable = "RenameTable"
    opRenameColumn = "RenameColumn"
    opRunSQL = "RunSQL"

  Operation* = object
    kind*: OperationKind
    table*: string
    columns*: seq[ColumnDef] ## CreateTable
    column*: ColumnDef ## AddColumn
    index*: IndexDef ## CreateIndex
    name*: string ## DropIndex, DropColumn, RenameColumn (old name)
    newName*: string ## RenameTable, RenameColumn
    sql*: seq[string] ## RunSQL

  Migration* = object
    name*: string
    description*: string
    sourceDir*: string ## absolute directory this migration was registered for
    folder*: string ## last path component of `sourceDir`
    portable*: bool ## also match a directory with the same folder name
    operations*: seq[Operation]
    reverses*: seq[Operation] ## generated or hand-written `down`
    snapshot*: Snapshot
    checksum*: string

  MigrationStatus* = object
    name*: string
    applied*: bool

# -- snapshots from models ---------------------------------------------------

proc sqlType(kind: FieldKind, maxLength: int): string =
  case kind
  of fkChar, fkFile:
    (if maxLength > 0: "VARCHAR(" & $maxLength & ")" else: "TEXT")
  of fkUUID, fkText, fkDateTime, fkDate, fkTime, fkDecimal, fkJson:
    "TEXT"
  of fkInteger, fkBoolean, fkDuration:
    "INTEGER"
  of fkFloat:
    "REAL"
  of fkBinary:
    "BLOB"
  of fkForeignKey:
    "INTEGER"

proc sqlLiteral*(v: DbValue): string =
  case v.kind
  of dvNull:
    "NULL"
  of dvInt:
    $v.i
  of dvFloat:
    $v.f
  of dvText:
    "'" & v.s.replace("'", "''") & "'"
  of dvBlob:
    var hex = ""
    for b in v.b:
      hex.add toHex(b.int, 2)
    "X'" & hex & "'"

proc keptDescending(values: seq[bool]): seq[bool] =
  ## Drops an all-ascending direction list so it compares equal to an omitted one.
  for v in values:
    if v:
      return values

proc onDeleteSql(o: OnDelete): string =
  case o
  of Cascade: "CASCADE"
  of SetNull: "SET NULL"
  of Restrict: "RESTRICT"
  of NoAction: "NO ACTION"

proc tableFor(m: ModelMeta): TableDef =
  result.name = m.table
  for f in m.fields:
    var c = ColumnDef(
      name: f.column,
      primaryKey: f.primaryKey,
      notNull: not f.null,
      unique: f.unique and not f.primaryKey,
    )
    c.sqlType =
      if f.kind == fkForeignKey:
        sqlType(f.targetKind, 0)
      else:
        sqlType(f.kind, f.maxLength)
    if f.hasDefault:
      c.default = sqlLiteral(f.default)
    if f.kind == fkForeignKey:
      c.refTable = f.targetTable
      c.refColumn = f.targetColumn
      c.onDelete = onDeleteSql(f.onDelete)
    result.columns.add c
    if f.index and not f.unique and not f.primaryKey:
      result.indexes.add IndexDef(
        name: m.table & "_" & f.column & "_idx", table: m.table, columns: @[f.column]
      )
  for ix in m.indexes:
    result.indexes.add IndexDef(
      name: ix.name,
      table: m.table,
      columns: ix.columns,
      descending: keptDescending(ix.descending),
      unique: ix.unique,
    )

proc tableForMany(m: ManyToManyDef): TableDef =
  result.name = m.table
  result.columns = @[
    ColumnDef(
      name: m.ownerColumn,
      sqlType: sqlType(m.ownerKind, 0),
      notNull: true,
      refTable: m.ownerTable,
      refColumn: m.ownerKeyColumn,
      onDelete: "CASCADE",
    ),
    ColumnDef(
      name: m.targetColumn,
      sqlType: sqlType(m.targetKind, 0),
      notNull: true,
      refTable: m.targetTable,
      refColumn: m.targetKeyColumn,
      onDelete: "CASCADE",
    ),
  ]
  result.indexes = @[
    IndexDef(
      name: m.table & "_" & m.ownerColumn & "_" & m.targetColumn & "_uniq",
      table: m.table,
      columns: @[m.ownerColumn, m.targetColumn],
      unique: true,
    ),
    IndexDef(
      name: m.table & "_" & m.targetColumn & "_idx",
      table: m.table,
      columns: @[m.targetColumn],
    ),
  ]

proc snapshotOf*(models: openArray[ModelMeta]): Snapshot =
  ## Deterministic schema snapshot: tables sorted by name, columns in
  ## declaration order.
  var seen: Table[string, string]
  for m in models:
    if m.table in seen:
      raise newException(
        MigrationError,
        "models " & seen[m.table] & " and " & m.name & " both use table " & m.table,
      )
    seen[m.table] = m.name
    result.tables.add tableFor(m)
  for model in models:
    for relation in model.manyToMany:
      if relation.table in seen:
        raise newException(
          MigrationError,
          "many-to-many relation " & model.name & "." & relation.name &
            " and " & seen[relation.table] & " both use table " & relation.table,
        )
      seen[relation.table] = model.name & "." & relation.name
      result.tables.add tableForMany(relation)
  result.tables.sort(
    proc(a, b: TableDef): int =
      cmp(a.name, b.name)
  )

proc currentSnapshot*(): Snapshot =
  snapshotOf(registeredModels())

# -- SQL for operations ------------------------------------------------------

proc columnSql*(c: ColumnDef): string =
  result = quoteIdent(c.name) & " " & c.sqlType
  if c.primaryKey:
    result.add " PRIMARY KEY"
  if c.notNull:
    result.add " NOT NULL"
  if c.unique:
    result.add " UNIQUE"
  if c.default.len > 0:
    result.add " DEFAULT " & c.default
  if c.refTable.len > 0:
    result.add " REFERENCES " & quoteIdent(c.refTable) & " (" & quoteIdent(c.refColumn) &
      ") ON DELETE " & c.onDelete

proc indexSql(i: IndexDef): string =
  var cols: seq[string]
  for n, c in i.columns:
    var part = quoteIdent(c)
    if n < i.descending.len and i.descending[n]:
      part.add " DESC"
    cols.add part
  (if i.unique: "CREATE UNIQUE INDEX " else: "CREATE INDEX ") & quoteIdent(i.name) &
    " ON " & quoteIdent(i.table) & " (" & cols.join(", ") & ")"

proc sqlFor*(op: Operation): seq[string] =
  case op.kind
  of opCreateTable:
    var cols: seq[string]
    for c in op.columns:
      cols.add "  " & columnSql(c)
    @["CREATE TABLE " & quoteIdent(op.table) & " (\n" & cols.join(",\n") & "\n)"]
  of opAddColumn:
    @["ALTER TABLE " & quoteIdent(op.table) & " ADD COLUMN " & columnSql(op.column)]
  of opCreateIndex:
    @[indexSql(op.index)]
  of opDropIndex:
    @["DROP INDEX " & quoteIdent(op.name)]
  of opDropTable:
    @["DROP TABLE " & quoteIdent(op.table)]
  of opDropColumn:
    @["ALTER TABLE " & quoteIdent(op.table) & " DROP COLUMN " & quoteIdent(op.name)]
  of opRenameTable:
    @["ALTER TABLE " & quoteIdent(op.table) & " RENAME TO " & quoteIdent(op.newName)]
  of opRenameColumn:
    @[
      "ALTER TABLE " & quoteIdent(op.table) & " RENAME COLUMN " & quoteIdent(op.name) &
        " TO " & quoteIdent(op.newName)
    ]
  of opRunSQL:
    op.sql

proc sqlFor*(m: Migration): seq[string] =
  for op in m.operations:
    result.add sqlFor(op)

proc sqlDown*(m: Migration): seq[string] =
  ## SQL for the migration's `down` section.
  for op in m.reverses:
    result.add sqlFor(op)

# -- operation constructors --------------------------------------------------

proc column*(
    name, sqlType: string,
    primaryKey = false,
    notNull = false,
    unique = false,
    default = "",
    refTable = "",
    refColumn = "",
    onDelete = "",
): ColumnDef =
  ## One column of a `createTable`, `addColumn`, or snapshot `table`.
  ColumnDef(
    name: name,
    sqlType: sqlType,
    primaryKey: primaryKey,
    notNull: notNull,
    unique: unique,
    default: default,
    refTable: refTable,
    refColumn: refColumn,
    onDelete: onDelete,
  )

proc index*(
    name: string,
    columns: openArray[string],
    unique = false,
    descending: seq[bool] = @[],
): IndexDef =
  ## An index inside a snapshot `table` block. `withIndexes` fills in the table name.
  IndexDef(
    name: name,
    columns: @columns,
    descending: keptDescending(descending),
    unique: unique,
  )

proc table*(name: string, columns: varargs[ColumnDef]): TableDef =
  ## A snapshot table. Pass indexes with `withIndexes`.
  TableDef(name: name, columns: @columns)

proc withIndexes*(t: TableDef, indexes: varargs[IndexDef]): TableDef =
  result = t
  for i in indexes:
    var ix = i
    ix.table = result.name
    ix.descending = keptDescending(ix.descending)
    result.indexes.add ix

proc snapshot*(tables: varargs[TableDef]): Snapshot =
  ## Schema after the migration's `up` section has run.
  Snapshot(tables: @tables)

proc createTable*(table: string, columns: varargs[ColumnDef]): Operation =
  ## `CREATE TABLE` for the `up` or `down` section.
  Operation(kind: opCreateTable, table: table, columns: @columns)

proc addColumn*(table: string, column: ColumnDef): Operation =
  ## `ALTER TABLE ... ADD COLUMN`.
  Operation(kind: opAddColumn, table: table, column: column)

proc createIndex*(
    name, table: string,
    columns: openArray[string],
    unique = false,
    descending: seq[bool] = @[],
): Operation =
  ## `CREATE INDEX`.
  Operation(
    kind: opCreateIndex,
    index: IndexDef(
      name: name,
      table: table,
      columns: @columns,
      descending: keptDescending(descending),
      unique: unique,
    ),
  )

proc dropTable*(table: string): Operation =
  ## `DROP TABLE`.
  Operation(kind: opDropTable, table: table)

proc dropColumn*(table, column: string): Operation =
  ## `ALTER TABLE ... DROP COLUMN`.
  Operation(kind: opDropColumn, table: table, name: column)

proc dropIndex*(name: string): Operation =
  ## `DROP INDEX`.
  Operation(kind: opDropIndex, name: name)

proc renameTable*(table, newName: string): Operation =
  ## `ALTER TABLE ... RENAME TO`.
  Operation(kind: opRenameTable, table: table, newName: newName)

proc renameColumn*(table, column, newName: string): Operation =
  ## `ALTER TABLE ... RENAME COLUMN`.
  Operation(kind: opRenameColumn, table: table, name: column, newName: newName)

proc runSql*(statements: varargs[string]): Operation =
  ## Runs raw SQL statements in order.
  Operation(kind: opRunSQL, sql: @statements)

# -- registry ----------------------------------------------------------------

var compiled: seq[Migration]
# Written at startup, or from the thread that calls makeMigrations, before a
# worker thread can observe it. Reads from async code are marked gcsafe below.

proc migrationDir(dir: string): string =
  result = absolutePath(dir)
  while result.len > 1 and result.endsWith(DirSep):
    result.setLen(result.len - 1)

proc fnv1a(s: string): string =
  var h = 0xcbf29ce484222325'u64
  for c in s:
    h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  toHex(h).toLowerAscii

proc checksumOf(m: Migration): string =
  ## Stable identity of the upward operations and the resulting schema.
  ## Editing `down` does not change it.
  var parts: seq[string]
  for op in m.operations:
    for sql in sqlFor(op):
      parts.add sql
  parts.add "--"
  for t in m.snapshot.tables:
    parts.add t.name
    for c in t.columns:
      parts.add columnSql(c)
    for i in t.indexes:
      parts.add indexSql(i)
  fnv1a(parts.join("\n"))

proc registerMigration*(m: Migration, dir: string, portable = false) =
  ## Stores `m` for `dir`, replacing a previous migration with the same name.
  ##
  ## `portable` migrations also match a later `migrate` whose directory has
  ## the same folder name, so a binary built on another machine still finds
  ## `migrate("migrations")`.
  var stored = m
  stored.sourceDir = migrationDir(dir)
  stored.folder = stored.sourceDir.lastPathPart
  stored.portable = portable
  stored.checksum = checksumOf(stored)
  {.cast(gcsafe).}:
    for i, existing in compiled:
      if existing.name == stored.name and existing.sourceDir == stored.sourceDir:
        compiled[i] = stored
        return
    compiled.add stored

proc forgetMigrations*(dir: string) =
  ## Drops migrations registered for `dir`.
  ##
  ## Tests use this to stand in for a binary that no longer contains a
  ## migration the database has already applied.
  let abs = migrationDir(dir)
  {.cast(gcsafe).}:
    var kept: seq[Migration]
    for m in compiled:
      if m.sourceDir != abs:
        kept.add m
    compiled = kept

proc isMigrationModule(filename: string): bool =
  if filename.len < 12 or not filename.startsWith("m") or not filename.endsWith(".nim"):
    return false
  let stem = filename.changeFileExt("")
  stem.len > 5 and stem[1 .. 4].allCharsInSet(Digits) and stem[5] == '_'

proc migrationName(filename: string): string =
  filename.changeFileExt("")[1 .. ^1]

proc diskMigrationNames(dir: string): seq[string] =
  if not dirExists(dir):
    return
  for kind, path in walkDir(dir):
    let filename = path.extractFilename
    if kind == pcFile and isMigrationModule(filename):
      result.add migrationName(filename)
  result.sort()

proc registered(dir: string): seq[Migration] {.gcsafe.} =
  let abs = migrationDir(dir)
  let folder = abs.lastPathPart
  var exact, fallback: seq[Migration]
  {.cast(gcsafe).}:
    for m in compiled:
      if m.sourceDir == abs:
        exact.add m
      elif m.portable and m.folder == folder:
        fallback.add m
  result = if exact.len > 0: exact else: fallback
  result.sort(
    proc(a, b: Migration): int =
      cmp(a.name, b.name)
  )

proc loadMigrations*(dir: string): seq[Migration] {.gcsafe.} =
  ## Migrations compiled for `dir`, oldest first.
  ##
  ## A file in `dir` that was not compiled into this program is an error:
  ## `migrate` would otherwise skip it. Compiled migrations whose files are
  ## absent (a deployed binary) are kept.
  result = registered(dir)
  var known: seq[string]
  for m in result:
    known.add m.name
  var missing: seq[string]
  for name in diskMigrationNames(dir):
    if name notin known:
      missing.add name
  if missing.len > 0:
    raise newException(
      MigrationError,
      "migrations " & missing.join(", ") & " in " & dir &
        " are not compiled in. Import `" & (dir / "all") & "` and rebuild.",
    )

# -- rendering ---------------------------------------------------------------

proc nimStr(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"':
      result.add "\\\""
    of '\\':
      result.add "\\\\"
    of '\n':
      result.add "\\n"
    of '\r':
      result.add "\\r"
    of '\t':
      result.add "\\t"
    else:
      if ord(c) < 32:
        result.add "\\x" & toHex(ord(c), 2)
      else:
        result.add c
  result.add '"'

proc renderStrList(values: seq[string]): string =
  var parts: seq[string]
  for v in values:
    parts.add nimStr(v)
  "@[" & parts.join(", ") & "]"

proc renderBoolList(values: seq[bool]): string =
  var parts: seq[string]
  for v in values:
    parts.add (if v: "true" else: "false")
  "@[" & parts.join(", ") & "]"

proc renderColumn(c: ColumnDef, indent: string): string =
  result = indent & "column " & nimStr(c.name) & ", " & nimStr(c.sqlType)
  if c.primaryKey:
    result.add ", primaryKey = true"
  if c.notNull:
    result.add ", notNull = true"
  if c.unique:
    result.add ", unique = true"
  if c.default.len > 0:
    result.add ", default = " & nimStr(c.default)
  if c.refTable.len > 0:
    result.add ", refTable = " & nimStr(c.refTable)
    result.add ", refColumn = " & nimStr(c.refColumn)
    if c.onDelete.len > 0:
      result.add ", onDelete = " & nimStr(c.onDelete)

proc renderIndexFlags(unique: bool, descending: seq[bool]): string =
  if unique:
    result.add ", unique = true"
  if descending.len > 0:
    result.add ", descending = " & renderBoolList(descending)

proc renderOp(op: Operation, indent: string): string =
  case op.kind
  of opCreateTable:
    result = indent & "createTable " & nimStr(op.table) & ":\n"
    for c in op.columns:
      result.add renderColumn(c, indent & "  ") & "\n"
  of opAddColumn:
    result = indent & "addColumn " & nimStr(op.table) & ":\n"
    result.add renderColumn(op.column, indent & "  ") & "\n"
  of opCreateIndex:
    result =
      indent & "createIndex " & nimStr(op.index.name) & ", " & nimStr(op.index.table) &
      ", " & renderStrList(op.index.columns) &
      renderIndexFlags(op.index.unique, op.index.descending) & "\n"
  of opDropIndex:
    result = indent & "dropIndex " & nimStr(op.name) & "\n"
  of opDropTable:
    result = indent & "dropTable " & nimStr(op.table) & "\n"
  of opDropColumn:
    result = indent & "dropColumn " & nimStr(op.table) & ", " & nimStr(op.name) & "\n"
  of opRenameTable:
    result =
      indent & "renameTable " & nimStr(op.table) & ", " & nimStr(op.newName) & "\n"
  of opRenameColumn:
    result =
      indent & "renameColumn " & nimStr(op.table) & ", " & nimStr(op.name) & ", " &
      nimStr(op.newName) & "\n"
  of opRunSQL:
    result = indent & "runSql"
    for i, sql in op.sql:
      if i > 0:
        result.add ","
      result.add " " & nimStr(sql)
    result.add "\n"

proc renderOps(ops: seq[Operation], indent: string): string =
  if ops.len == 0:
    return indent & "discard\n"
  for op in ops:
    result.add renderOp(op, indent)

proc renderSnapshot(s: Snapshot, indent: string): string =
  if s.tables.len == 0:
    return indent & "discard\n"
  for t in s.tables:
    result.add indent & "table " & nimStr(t.name) & ":\n"
    for c in t.columns:
      result.add renderColumn(c, indent & "  ") & "\n"
    for i in t.indexes:
      result.add indent & "  index " & nimStr(i.name) & ", " & renderStrList(i.columns) &
        renderIndexFlags(i.unique, i.descending) & "\n"

proc renderMigration(
    name, description: string,
    ops, reverses: seq[Operation],
    snapshot: Snapshot,
    reversible: bool,
): string =
  let down =
    if reversible:
      renderOps(reverses, "    ")
    else:
      "    # Fill in the reverse of this migration by hand.\n    discard\n"
  "## Generated by makemigrations. Edit `up` and `down`, then rebuild.\n" &
    "import fastnim/orm\n\n" & "migration " & nimStr(name) & ", " & nimStr(description) &
    ":\n" & "  up:\n" & renderOps(ops, "    ") & "  down:\n" & down & "  snapshot:\n" &
    renderSnapshot(snapshot, "    ")

proc writeIndex(dir: string) =
  var names: seq[string]
  for filename in diskMigrationNames(dir):
    names.add "m" & filename
  var lines = @[
    "## Generated by makemigrations. Import this module so the migrations",
    "## are compiled into the binary.", "",
  ]
  if names.len == 0:
    lines.add "discard"
  for n in names:
    lines.add "import ./" & n
  writeFile(dir / "all.nim", lines.join("\n") & "\n")

# -- migration macro ---------------------------------------------------------

proc called(n: NimNode): string {.compileTime.} =
  if n.kind == nnkIdent:
    n.strVal
  elif n.kind == nnkAccQuoted and n.len > 0 and n[0].kind == nnkIdent:
    n[0].strVal
  else:
    ""

proc bindCall(name: string): NimNode {.compileTime.} =
  case name
  of "column":
    bindSym"column"
  of "index":
    bindSym"index"
  of "createTable":
    bindSym"createTable"
  of "addColumn":
    bindSym"addColumn"
  of "createIndex":
    bindSym"createIndex"
  of "runSql":
    bindSym"runSql"
  of "dropTable":
    bindSym"dropTable"
  of "dropColumn":
    bindSym"dropColumn"
  of "dropIndex":
    bindSym"dropIndex"
  of "renameTable":
    bindSym"renameTable"
  of "renameColumn":
    bindSym"renameColumn"
  else:
    error("unknown operation `" & name & "`")

proc forward(name: string, n: NimNode): NimNode {.compileTime.} =
  result = newCall(bindCall(name))
  for i in 1 ..< n.len:
    result.add n[i]

proc skipStmt(n: NimNode): bool {.compileTime.} =
  n.kind in {nnkEmpty, nnkCommentStmt, nnkDiscardStmt}

proc parseColumns(body: NimNode): seq[NimNode] {.compileTime.} =
  for stmt in body:
    if skipStmt(stmt):
      continue
    if stmt.kind notin {nnkCommand, nnkCall} or called(stmt[0]) != "column":
      error("expected a column line", stmt)
    result.add forward("column", stmt)

proc parseCreateTable(n: NimNode): NimNode {.compileTime.} =
  if n.len != 3 or n[2].kind != nnkStmtList:
    error("write `createTable \"name\":` followed by column lines", n)
  let cols = parseColumns(n[2])
  if cols.len == 0:
    error("createTable needs at least one column", n)
  result = newCall(bindSym"createTable", n[1])
  for c in cols:
    result.add c

proc parseAddColumn(n: NimNode): NimNode {.compileTime.} =
  if n.len != 3 or n[2].kind != nnkStmtList:
    error("write `addColumn \"table\":` followed by one column", n)
  let cols = parseColumns(n[2])
  if cols.len != 1:
    error("addColumn contains exactly one column", n)
  newCall(bindSym"addColumn", n[1], cols[0])

proc parseTable(n: NimNode): NimNode {.compileTime.} =
  if n.len != 3 or n[2].kind != nnkStmtList:
    error("write `table \"name\":` followed by column lines", n)
  var columns, indexes: seq[NimNode]
  for stmt in n[2]:
    if skipStmt(stmt):
      continue
    if stmt.kind notin {nnkCommand, nnkCall}:
      error("expected column or index", stmt)
    case called(stmt[0])
    of "column":
      columns.add forward("column", stmt)
    of "index":
      indexes.add forward("index", stmt)
    else:
      error("expected column or index", stmt)
  if columns.len == 0:
    error("table needs at least one column", n)
  result = newCall(bindSym"table", n[1])
  for c in columns:
    result.add c
  if indexes.len > 0:
    let bare = result
    result = newCall(bindSym"withIndexes", bare)
    for i in indexes:
      result.add i

proc parseSnapshot(body: NimNode): NimNode {.compileTime.} =
  result = newCall(bindSym"snapshot")
  for stmt in body:
    if skipStmt(stmt):
      continue
    if stmt.kind in {nnkCommand, nnkCall} and called(stmt[0]) == "table":
      result.add parseTable(stmt)
    else:
      error("expected `table \"name\":`", stmt)

proc parseOps(body: NimNode): seq[NimNode] {.compileTime.} =
  for stmt in body:
    if skipStmt(stmt):
      continue
    if stmt.kind notin {nnkCommand, nnkCall}:
      error("expected a migration operation", stmt)
    case called(stmt[0])
    of "createTable":
      result.add parseCreateTable(stmt)
    of "addColumn":
      result.add parseAddColumn(stmt)
    of "createIndex", "runSql", "dropTable", "dropColumn", "dropIndex", "renameTable",
        "renameColumn":
      result.add forward(called(stmt[0]), stmt)
    else:
      error("unknown operation `" & called(stmt[0]) & "`", stmt)

proc opSeq(items: seq[NimNode]): NimNode {.compileTime.} =
  if items.len == 0:
    nnkCall.newTree(nnkBracketExpr.newTree(bindSym"newSeq", bindSym"Operation"))
  else:
    nnkPrefix.newTree(ident"@", nnkBracket.newTree(items))

macro migration*(name, description, body: untyped): untyped =
  ## Registers a migration when this module is imported.
  ##
  ## ```nim
  ## migration "0001_initial", "Create the post table":
  ##   up:
  ##     createTable "post":
  ##       column "id", "INTEGER", primaryKey = true, notNull = true
  ##       column "title", "VARCHAR(100)", notNull = true
  ##   down:
  ##     dropTable "post"
  ##   snapshot:
  ##     table "post":
  ##       column "id", "INTEGER", primaryKey = true, notNull = true
  ##       column "title", "VARCHAR(100)", notNull = true
  ## ```
  ##
  ## `snapshot` is the schema after `up` runs. The next `makemigrations`
  ## diffs the models against it. `up` and `down` are applied from the
  ## compiled program, so edit the file and rebuild before migrating.
  var up, down, snap: NimNode
  for stmt in body:
    if skipStmt(stmt):
      continue
    if stmt.kind != nnkCall or stmt.len != 2 or stmt[1].kind != nnkStmtList:
      error("expected `up:`, `down:`, or `snapshot:`", stmt)
    case called(stmt[0])
    of "up":
      up = stmt[1]
    of "down":
      down = stmt[1]
    of "snapshot":
      snap = stmt[1]
    else:
      error("unknown section `" & called(stmt[0]) & "`", stmt)
  if up.isNil:
    error("migration needs an `up:` section", body)
  if down.isNil:
    error("migration needs a `down:` section", body)
  if snap.isNil:
    error("migration needs a `snapshot:` section", body)
  let ops = opSeq(parseOps(up))
  let reverses = opSeq(parseOps(down))
  let snapExpr = parseSnapshot(snap)
  result = quote:
    block:
      const migrationFolder = instantiationInfo(-1, fullPaths = true).filename.parentDir
      var created = Migration(
        name: `name`,
        description: `description`,
        operations: `ops`,
        reverses: `reverses`,
        snapshot: `snapExpr`,
      )
      registerMigration(created, migrationFolder, true)

# -- diff --------------------------------------------------------------------

proc diff*(old, new: Snapshot): tuple[ops: seq[Operation], unsupported: seq[string]] =
  ## Operations turning `old` into `new`. Only additive changes are
  ## generated; anything destructive or ambiguous is listed in `unsupported`.
  var oldTables: Table[string, TableDef]
  for t in old.tables:
    oldTables[t.name] = t
  var newNames: seq[string]
  for t in new.tables:
    newNames.add t.name
    if t.name notin oldTables:
      result.ops.add Operation(kind: opCreateTable, table: t.name, columns: t.columns)
      for i in t.indexes:
        result.ops.add Operation(kind: opCreateIndex, index: i)
      continue
    let prev = oldTables[t.name]
    var prevCols: Table[string, ColumnDef]
    for c in prev.columns:
      prevCols[c.name] = c
    var colNames: seq[string]
    for c in t.columns:
      colNames.add c.name
      if c.name in prevCols:
        if prevCols[c.name] != c:
          result.unsupported.add "column " & t.name & "." & c.name & " changed from `" &
            columnSql(prevCols[c.name]) & "` to `" & columnSql(c) & "`"
      elif c.primaryKey:
        result.unsupported.add "new primary key column " & t.name & "." & c.name
      elif c.notNull and c.default.len == 0:
        result.unsupported.add "new column " & t.name & "." & c.name &
          " is NOT NULL without a default; give it `default:` or `null: true`"
      elif c.refTable.len > 0 and c.notNull:
        result.unsupported.add "new foreign key column " & t.name & "." & c.name &
          " must be `null: true` (SQLite cannot add a NOT NULL REFERENCES column)"
      else:
        var added = c
        added.unique = false
        result.ops.add Operation(kind: opAddColumn, table: t.name, column: added)
        if c.unique:
          result.ops.add Operation(
            kind: opCreateIndex,
            index: IndexDef(
              name: t.name & "_" & c.name & "_uniq",
              table: t.name,
              columns: @[c.name],
              unique: true,
            ),
          )
    for c in prev.columns:
      if c.name notin colNames:
        result.unsupported.add "column " & t.name & "." & c.name & " was removed"
    var prevIdx: Table[string, IndexDef]
    for i in prev.indexes:
      prevIdx[i.name] = i
    var idxNames: seq[string]
    for i in t.indexes:
      idxNames.add i.name
      if i.name notin prevIdx:
        result.ops.add Operation(kind: opCreateIndex, index: i)
      elif prevIdx[i.name] != i:
        result.ops.add Operation(kind: opDropIndex, name: i.name)
        result.ops.add Operation(kind: opCreateIndex, index: i)
    for i in prev.indexes:
      if i.name notin idxNames:
        result.ops.add Operation(kind: opDropIndex, name: i.name)
  for t in old.tables:
    if t.name notin newNames:
      result.unsupported.add "table " & t.name & " was removed"

proc automaticDown(ops: seq[Operation]): tuple[ops: seq[Operation], complete: bool] =
  if ops.len == 0:
    return (@[], true)
  for i in countdown(ops.high, 0):
    case ops[i].kind
    of opCreateTable:
      result.ops.add Operation(kind: opDropTable, table: ops[i].table)
    of opAddColumn:
      result.ops.add Operation(
        kind: opDropColumn, table: ops[i].table, name: ops[i].column.name
      )
    of opCreateIndex:
      result.ops.add Operation(kind: opDropIndex, name: ops[i].index.name)
    else:
      return (@[], false)
  result.complete = true

proc describe(ops: seq[Operation]): string =
  if ops.len != 1:
    return "auto"
  let op = ops[0]
  case op.kind
  of opCreateTable:
    "create_" & op.table
  of opAddColumn:
    "add_" & op.table & "_" & op.column.name
  of opCreateIndex:
    "index_" & op.index.table
  else:
    "auto"

proc migrationDescription(ops: seq[Operation]): string =
  if ops.len == 0:
    "Hand-written migration"
  elif ops.len == 1 and ops[0].kind == opCreateTable:
    "Create the " & ops[0].table & " table"
  elif ops.len == 1 and ops[0].kind == opAddColumn:
    "Add " & ops[0].column.name & " to " & ops[0].table
  else:
    "Update the schema"

proc sanitize(name: string): string =
  for c in name.toLowerAscii:
    result.add(if c in {'a' .. 'z', '0' .. '9'}: c else: '_')

proc makeMigrations*(
    dir: string, name = "", empty = false, snapshot = currentSnapshot()
): Option[string] =
  ## Writes the next Nim migration for changes between the latest compiled
  ## snapshot and `snapshot` (the registered models by default) and returns
  ## its path, or `none` if nothing changed.
  ##
  ## The new module is also registered in this process, so `migrate` can
  ## apply it before the program is rebuilt. The following build has to
  ## import `dir/all` or the migration is no longer part of the binary.
  ## Raises `MigrationError` when the changes need a hand-written `up`.
  ## `empty = true` writes a migration with no operations and the current
  ## snapshot, ready to fill in by hand.
  let existing = loadMigrations(dir)
  let previous =
    if existing.len > 0:
      existing[^1].snapshot
    else:
      Snapshot()
  var ops: seq[Operation]
  if not empty:
    let (found, unsupported) = diff(previous, snapshot)
    if unsupported.len > 0:
      raise newException(
        MigrationError,
        "these changes cannot be generated automatically:\n  - " &
          unsupported.join("\n  - ") &
          "\nWrite them by hand: run makemigrations with --empty, edit the `up` and `down` " &
          "sections of the new file, and rebuild.",
      )
    if found.len == 0:
      return none(string)
    ops = found
  let number =
    if existing.len > 0:
      parseInt(existing[^1].name[0 .. 3]) + 1
    else:
      1
  let label =
    if name.len > 0:
      sanitize(name)
    elif existing.len == 0:
      "initial"
    elif empty:
      "manual"
    else:
      describe(ops)
  let migrationName = align($number, 4, '0') & "_" & label
  let (reverses, reversible) = automaticDown(ops)
  let description = migrationDescription(ops)
  createDir(dir)
  let path = dir / ("m" & migrationName & ".nim")
  writeFile(
    path,
    renderMigration(migrationName, description, ops, reverses, snapshot, reversible),
  )
  registerMigration(
    Migration(
      name: migrationName,
      description: description,
      operations: ops,
      reverses:
        if reversible:
          reverses
        else:
          @[],
      snapshot: snapshot,
    ),
    dir,
  )
  writeIndex(dir)
  some(path)

# -- applying ----------------------------------------------------------------

proc ensureHistory(db: Database): Future[void] {.async.} =
  discard await db.execute(
    "CREATE TABLE IF NOT EXISTS " & quoteIdent(historyTable) &
      " (name TEXT PRIMARY KEY NOT NULL, checksum TEXT NOT NULL, applied_at TEXT NOT NULL)"
  )

proc appliedMigrations(db: Database): Future[OrderedTable[string, string]] {.async.} =
  await db.ensureHistory()
  let res = await db.query(
    "SELECT name, checksum FROM " & quoteIdent(historyTable) & " ORDER BY name"
  )
  var applied: OrderedTable[string, string]
  for row in res.rows:
    applied[row[0].s] = row[1].s
  return applied

proc pending(
    applied: OrderedTable[string, string], migrations: seq[Migration]
): seq[Migration] =
  var known: seq[string]
  for m in migrations:
    known.add m.name
    if m.name in applied:
      if applied[m.name] != m.checksum:
        raise newException(
          MigrationError,
          "migration " & m.name &
            " was modified after it was applied (checksum mismatch)",
        )
    else:
      result.add m
  var lastApplied = ""
  for name in applied.keys:
    if name notin known:
      raise newException(
        MigrationError,
        "migration " & name & " is recorded as applied but is not compiled in",
      )
    lastApplied = max(lastApplied, name)
  for m in result:
    if m.name < lastApplied:
      raise newException(
        MigrationError,
        "migration " & m.name & " is older than the already applied " & lastApplied &
          "; history is inconsistent",
      )

proc migrate*(db: Database, dir: string): Future[seq[string]] {.async.} =
  ## Applies every pending compiled migration for `dir`, each in its own
  ## transaction, and returns the names applied.
  let applied = await db.appliedMigrations()
  var done: seq[string]
  for m in pending(applied, loadMigrations(dir)):
    var stmts: seq[Statement]
    for sql in sqlFor(m):
      stmts.add Statement(sql: sql)
    stmts.add Statement(
      sql:
        "INSERT INTO " & quoteIdent(historyTable) &
        " (name, checksum, applied_at) VALUES (?, ?, ?)",
      params: @[toDbValue(m.name), toDbValue(m.checksum), toDbValue(getTime())],
    )
    try:
      await db.batch(stmts)
    except DatabaseError as e:
      raise newException(MigrationError, "migration " & m.name & " failed: " & e.msg)
    done.add m.name
  return done

proc showMigrations*(
    db: Database, dir: string
): Future[seq[MigrationStatus]] {.async.} =
  ## Lists compiled migrations for `dir` and whether each one is applied.
  let applied = await db.appliedMigrations()
  var statuses: seq[MigrationStatus]
  for m in loadMigrations(dir):
    statuses.add MigrationStatus(name: m.name, applied: m.name in applied)
  return statuses
