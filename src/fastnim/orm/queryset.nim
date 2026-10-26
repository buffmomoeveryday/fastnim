## Immutable, composable query sets and instance persistence.
##
## The generic procs here rely on procs generated per model by the `model`
## macro (`modelMeta`, `fromRow`, `toRow`, `validate`, `fastormPrepare`,
## `fastormPkIsSet`, `fastormSetRowId`, `pkValue`), bound at instantiation.

import std/[options, json, strutils, tables, sets, base64]
import chronos
import ../jsonfields
import ./[values, fields, sqlite]

const rootAlias = "t0"

type
  Predicate* = object
    sql*: string
    params*: seq[DbValue]

  AggregateKind* = enum
    ## SQL aggregate functions supported by `QuerySet.aggregate`.
    akCount
    akSum
    akAvg
    akMin
    akMax

  AggregateSpec* = object
    ## A validated aggregate expression, constructed by the `aggregate` macro.
    alias*: string
    column*: string
    kind*: AggregateKind

  AggregateResult* = Table[string, DbValue]
    ## Aggregate aliases mapped to their SQLite values. `COUNT` is always an
    ## integer; other aggregate values may be `dvNull` when no row supplies a
    ## non-null value.

  QuerySet*[T] = object
    db*: Database
    wheres*: seq[Predicate]
    ordering*: seq[string] ## column name, prefixed with `-` for descending
    selects*: seq[string] ## selectRelated paths
    prefetches*: seq[string] ## prefetchRelated paths
    expands*: seq[string] ## relation paths nested into JSON by `expand`
    relPaths*: seq[string] ## relation paths a filter condition reaches through
    limitN*: int ## -1 means no limit
    offsetN*: int
    forUpdate*: bool ## the rows must be read inside a transaction
    columns*: seq[string] ## selected SQL columns; empty means every field

  ManyToManyManager*[Owner, Target] = object
    ## Bound many-to-many relation returned by a generated model accessor.
    owner: Owner
    db: Database
    table: string
    ownerColumn: string
    targetColumn: string

  UpdateAssignment* = object
    ## One `SET` clause for `QuerySet.update`. A literal value is `sql = "?"`
    ## plus one parameter; an `F()` expression is parameterized SQL.
    column*: string
    sql*: string
    params*: seq[DbValue]

  FastormModel* = ref object of RootObj
    ## Base of every model. Holds relations filled by `selectRelated` and
    ## `prefetchRelated`; it is not a column.
    cache {.jsonRespIgnore.}: RelationCache
    responseSkip {.jsonRespIgnore.}: seq[string]
    responseExpand {.jsonRespIgnore.}: seq[string]
    loaded {.jsonRespIgnore.}: HashSet[string]

  RelationCache = ref object
    single: Table[string, FastormModel]
    missing: Table[string, bool]
    many: Table[string, seq[FastormModel]]

  PrefetchKind* = enum
    pfForward
    pfReverse

  PrefetchDef* = object
    owner*: string
    name*: string
    target*: string
    kind*: PrefetchKind
    keyColumn*: string

  RowFn = proc(m: FastormModel): seq[DbValue] {.gcsafe, raises: [].}
  HydrateFn = proc(row: seq[DbValue]): FastormModel {.gcsafe, raises: [DatabaseError].}

  Join = object
    parentPath: string
    field: string
    path: string ## full dotted path, e.g. "author.publisher"
    model: string
    table: string
    alias: string
    parentAlias: string
    fkColumn: string
    targetColumn: string
    pkIndex: int
    ncols: int

proc qcol(col: string, alias = rootAlias): string =
  quoteIdent(alias) & "." & quoteIdent(col)

proc rememberOmit*(model: FastormModel, fields: openArray[string]) {.raises: [].} =
  ## Records field names for the next FastNim encoding of `model`.
  ## `toJsonHook` consumes the list.
  if model.isNil:
    return
  model.responseSkip.setLen(0)
  for name in fields:
    model.responseSkip.add name

proc rememberExpand*(model: FastormModel, paths: openArray[string]) {.raises: [].} =
  ## Records relation paths to nest into the next JSON encoding of `model`.
  if model.isNil:
    return
  for path in paths:
    if path notin model.responseExpand:
      model.responseExpand.add path

proc jsonKey(field: FieldDef): string =
  if field.kind == fkForeignKey:
    field.name & "Id"
  else:
    field.name

proc dbToJson(value: DbValue, kind: FieldKind): JsonNode =
  if value.kind == dvNull:
    return newJNull()
  case kind
  of fkBoolean:
    newJBool(value.kind == dvInt and value.i != 0)
  of fkInteger:
    if value.kind == dvInt:
      newJInt(value.i)
    else:
      newJNull()
  of fkFloat:
    case value.kind
    of dvFloat:
      newJFloat(value.f)
    of dvInt:
      newJFloat(float(value.i))
    else:
      newJNull()
  of fkForeignKey:
    case value.kind
    of dvInt:
      newJInt(value.i)
    of dvFloat:
      newJFloat(value.f)
    of dvText:
      newJString(value.s)
    else:
      newJNull()
  of fkUUID, fkChar, fkText, fkDateTime, fkDate, fkTime, fkDecimal:
    if value.kind == dvText:
      newJString(value.s)
    else:
      newJNull()
  of fkDuration:
    if value.kind == dvInt:
      newJInt(value.i)
    else:
      newJNull()
  of fkJson:
    if value.kind == dvText:
      try:
        parseJson(value.s)
      except CatchableError:
        newJString(value.s)
    else:
      newJNull()
  of fkBinary:
    if value.kind == dvBlob:
      newJString(encode(value.b))
    else:
      newJNull()

proc encodeModel(
  model: FastormModel, modelName: string, expands: seq[string], skip: openArray[string]
): JsonNode

proc toJsonHook*[T: FastormModel](model: T): JsonNode =
  ## `std/jsonutils.toJson` calls this, which is how FastNim's `ok` and
  ## `created` encode a model. Columns use their Nim names. Relations listed
  ## by `expand` are nested from the relation cache. Names stored by `.omit`
  ## are dropped for this call.
  mixin modelMeta
  if model.isNil:
    return newJNull()
  {.cast(raises: []).}:
    let skip = model.responseSkip
    model.responseSkip = @[]
    result = encodeModel(model, modelMeta(T).name, model.responseExpand, skip)

proc initQuerySet*[T](): QuerySet[T] =
  ## Starts from the model's `Meta.ordering` when it declared one.
  mixin modelMeta
  QuerySet[T](limitN: -1, ordering: modelMeta(T).ordering)

proc initManyToManyManager*[Owner, Target](
    owner: Owner,
    db: Database,
    table, ownerColumn, targetColumn: string,
): ManyToManyManager[Owner, Target] =
  ## Binds the generated relation metadata to one model instance.
  ManyToManyManager[Owner, Target](
    owner: owner,
    db: db,
    table: table,
    ownerColumn: ownerColumn,
    targetColumn: targetColumn,
  )

proc requireSaved[T](model: T, role: string) =
  mixin fastormPkIsSet, modelMeta
  if model.isNil or not fastormPkIsSet(model):
    raise newException(
      QueryError,
      role & " " & modelMeta(T).name &
        " must be saved before changing a many-to-many relation",
    )

proc all*[Owner, Target](
    relation: ManyToManyManager[Owner, Target]
): Future[seq[Target]] {.async.} =
  ## Loads all target models attached to this relation.
  mixin modelMeta, pkValue
  requireSaved(relation.owner, "owner")
  let target = modelMeta(Target)
  var qs = initQuerySet[Target]()
  qs.db = relation.db
  qs.wheres.add Predicate(
    sql: qcol(target.pkField.column) & " IN (SELECT " &
      quoteIdent(relation.targetColumn) & " FROM " & quoteIdent(relation.table) &
      " WHERE " & quoteIdent(relation.ownerColumn) & " = ?)",
    params: @[toDbValue(pkValue(relation.owner))],
  )
  return await qs.all()

proc addMany[Owner, Target](
    relation: ManyToManyManager[Owner, Target], targets: seq[Target]
): Future[void] {.async.} =
  mixin pkValue
  requireSaved(relation.owner, "owner")
  if targets.len == 0:
    return
  let ownerPk = toDbValue(pkValue(relation.owner))
  let sql =
    "INSERT OR IGNORE INTO " & quoteIdent(relation.table) & " (" &
    quoteIdent(relation.ownerColumn) & ", " & quoteIdent(relation.targetColumn) &
    ") VALUES (?, ?)"
  var statements: seq[Statement]
  for target in targets:
    requireSaved(target, "target")
    statements.add Statement(sql: sql, params: @[ownerPk, toDbValue(pkValue(target))])
  await resolveDb(relation.db).batch(statements)

proc add*[Owner, Target](
    relation: ManyToManyManager[Owner, Target], targets: varargs[Target]
): Future[void] =
  ## Adds targets to the relation. Existing pairs are left unchanged.
  addMany(relation, @targets)

proc removeMany[Owner, Target](
    relation: ManyToManyManager[Owner, Target], targets: seq[Target]
): Future[int] {.async.} =
  mixin pkValue
  requireSaved(relation.owner, "owner")
  if targets.len == 0:
    return 0
  var marks: seq[string]
  var params = @[toDbValue(pkValue(relation.owner))]
  for target in targets:
    requireSaved(target, "target")
    marks.add "?"
    params.add toDbValue(pkValue(target))
  let sql =
    "DELETE FROM " & quoteIdent(relation.table) & " WHERE " &
    quoteIdent(relation.ownerColumn) & " = ? AND " &
    quoteIdent(relation.targetColumn) & " IN (" & marks.join(", ") & ")"
  return int((await resolveDb(relation.db).execute(sql, params)).changes)

proc remove*[Owner, Target](
    relation: ManyToManyManager[Owner, Target], targets: varargs[Target]
): Future[int] =
  ## Removes targets and returns the number of deleted junction rows.
  removeMany(relation, @targets)

proc clear*[Owner, Target](
    relation: ManyToManyManager[Owner, Target]
): Future[int] {.async.} =
  ## Removes every target from the relation and returns the number removed.
  mixin pkValue
  requireSaved(relation.owner, "owner")
  let sql =
    "DELETE FROM " & quoteIdent(relation.table) & " WHERE " &
    quoteIdent(relation.ownerColumn) & " = ?"
  return int(
    (await resolveDb(relation.db).execute(
      sql, @[toDbValue(pkValue(relation.owner))]
    )).changes
  )

proc count*[Owner, Target](
    relation: ManyToManyManager[Owner, Target]
): Future[int] {.async.} =
  ## Counts targets attached to this relation.
  mixin pkValue
  requireSaved(relation.owner, "owner")
  let sql =
    "SELECT COUNT(*) FROM " & quoteIdent(relation.table) & " WHERE " &
    quoteIdent(relation.ownerColumn) & " = ?"
  let rows = (await resolveDb(relation.db).query(
    sql, @[toDbValue(pkValue(relation.owner))]
  )).rows
  return int(rows[0][0].i)

proc contains*[Owner, Target](
    relation: ManyToManyManager[Owner, Target], target: Target
): Future[bool] {.async.} =
  ## Tests whether ``target`` belongs to this relation.
  mixin pkValue
  requireSaved(relation.owner, "owner")
  requireSaved(target, "target")
  let sql =
    "SELECT 1 FROM " & quoteIdent(relation.table) & " WHERE " &
    quoteIdent(relation.ownerColumn) & " = ? AND " &
    quoteIdent(relation.targetColumn) & " = ? LIMIT 1"
  let rows = (await resolveDb(relation.db).query(
    sql, @[
      toDbValue(pkValue(relation.owner)),
      toDbValue(pkValue(target)),
    ]
  )).rows
  return rows.len > 0

proc withDb*[T](qs: QuerySet[T], db: Database): QuerySet[T] =
  ## Evaluates the query against `db` instead of the default database.
  result = qs
  result.db = db

proc addPredicate*[T](qs: QuerySet[T], p: Predicate): QuerySet[T] =
  result = qs
  result.wheres.add p

proc addSelect*[T](qs: QuerySet[T], path: string): QuerySet[T] =
  result = qs
  if path notin result.selects:
    result.selects.add path

proc addPrefetch*[T](qs: QuerySet[T], path: string): QuerySet[T] =
  result = qs
  if path notin result.prefetches:
    result.prefetches.add path

proc addExpand*[T](qs: QuerySet[T], path: string): QuerySet[T] =
  ## Records `path` for JSON nesting after the query is evaluated.
  result = qs
  if path notin result.expands:
    result.expands.add path

proc addRelPath*[T](qs: QuerySet[T], path: string): QuerySet[T] =
  ## Records that a filter condition needs `path` joined to resolve a field
  ## on a related model (`author.name = "Ada"`).
  result = qs
  if path notin result.relPaths:
    result.relPaths.add path

proc applyOnly*[T](qs: QuerySet[T], columns: seq[string]): QuerySet[T] =
  ## Replaces the selected columns. The compile-time `only` macro supplies
  ## the list, always including the primary key.
  result = qs
  result.columns = columns

proc applyDefer*[T](qs: QuerySet[T], columns: seq[string]): QuerySet[T] =
  ## Drops `columns` from the current projection, or from every model
  ## column when none has been set. The primary key is kept.
  mixin modelMeta
  let m = modelMeta(T)
  var keep: seq[string]
  if qs.columns.len == 0:
    for f in m.fields:
      keep.add f.column
  else:
    keep = qs.columns
  for c in columns:
    for i in countdown(keep.high, 0):
      if keep[i] == c:
        keep.delete(i)
        break
  let pk = m.pkField.column
  if pk notin keep:
    keep.insert(pk, 0)
  result = qs
  result.columns = keep

proc markLoaded*(m: FastormModel, fields: openArray[string]) {.raises: [].} =
  ## Records which model fields a query hydrated. An empty set means the
  ## instance was not loaded through `only`/`defer` (constructed or fully
  ## selected) and may be saved.
  for name in fields:
    m.loaded.incl name

proc isFullyLoaded*(m: FastormModel, fields: openArray[string]): bool {.raises: [].} =
  ## True when every name in `fields` was hydrated, or when the instance
  ## was never projected (`loaded` is empty).
  if m.loaded.len == 0:
    return true
  for name in fields:
    if name notin m.loaded:
      return false
  true

proc coerceFloat*(v: SomeInteger): DbValue =
  toDbValue(float(v))

proc coerceFloat*(v: SomeFloat): DbValue =
  toDbValue(v)

proc columnFor(m: ModelMeta, name: string): string {.raises: [QueryError].} =
  let i = m.findField(name)
  if i < 0:
    var known: seq[string]
    for f in m.fields:
      known.add f.name
    raise newException(
      QueryError,
      m.name & " has no field '" & name & "' (fields: " & known.join(", ") & ")",
    )
  m.fields[i].column

proc orderBy*[T](
    qs: QuerySet[T], fields: varargs[string]
): QuerySet[T] {.raises: [QueryError].} =
  ## Orders by field names; prefix a name with `-` for descending order.
  ## Replaces any previous ordering.
  mixin modelMeta
  let m = modelMeta(T)
  result = qs
  result.ordering = @[]
  for f in fields:
    let desc = f.startsWith("-")
    let name =
      if desc:
        f[1 .. ^1]
      else:
        f
    result.ordering.add (if desc: "-" else: "") & m.columnFor(name)

proc limit*[T](qs: QuerySet[T], n: Natural): QuerySet[T] =
  result = qs
  result.limitN = n

proc offset*[T](qs: QuerySet[T], n: Natural): QuerySet[T] =
  result = qs
  result.offsetN = n

proc selectForUpdate*[T](qs: QuerySet[T]): QuerySet[T] =
  ## Requires the rows to be read inside a transaction, so nothing else can
  ## change them before it commits. Evaluating the query set outside one
  ## raises `QueryError`.
  ##
  ## No SQL changes: SQLite has no `SELECT ... FOR UPDATE`, and FastORM
  ## opens transactions with `BEGIN IMMEDIATE`, which already takes the
  ## database's write lock. Every row a transaction reads is therefore a row
  ## only it can write until it finishes.
  result = qs
  result.forUpdate = true

proc aggregateInt*(
    values: AggregateResult, alias: string
): int64 {.raises: [QueryError].} =
  ## Reads an integer aggregate, typically `Count`. Raises when the alias is
  ## unknown or its value is NULL/non-integral.
  var value: DbValue
  try:
    value = values[alias]
  except KeyError:
    raise newException(QueryError, "aggregate result has no alias '" & alias & "'")
  if value.kind != dvInt:
    raise newException(QueryError, "aggregate '" & alias & "' is not an integer")
  value.i

proc aggregateValue*(
    values: AggregateResult, alias: string
): DbValue {.raises: [QueryError].} =
  ## Reads a raw aggregate value, including `dvNull` for an empty `SUM`,
  ## `AVG`, `MIN`, or `MAX`.
  try:
    values[alias]
  except KeyError:
    raise newException(QueryError, "aggregate result has no alias '" & alias & "'")

proc aggregateFloat*(
    values: AggregateResult, alias: string
): float {.raises: [QueryError].} =
  ## Reads a numeric aggregate. SQLite may return either an integer or float.
  let value = values.aggregateValue(alias)
  case value.kind
  of dvInt:
    float(value.i)
  of dvFloat:
    value.f
  else:
    raise newException(QueryError, "aggregate '" & alias & "' is not numeric")

# -- predicate builders used by the filter macros ----------------------------

proc coerce*[T](t: typedesc[T], v: T): DbValue =
  toDbValue(v)

proc coerce*[T](t: typedesc[Option[T]], v: T): DbValue =
  toDbValue(v)

proc coerce*[T; M: ref RootObj](t: typedesc[T], v: M): DbValue =
  ## Lets foreign key lookups accept a model instance instead of its key.
  mixin pkValue
  toDbValue(pkValue(v))

proc coerceSeq*[T, V](t: typedesc[T], vs: openArray[V]): seq[DbValue] =
  for v in vs:
    result.add coerce(T, v)

proc notPredicate*(p: Predicate): Predicate =
  Predicate(sql: "NOT (" & p.sql & ")", params: p.params)

proc orPredicate*(ps: openArray[Predicate]): Predicate =
  ## Any of the predicates may match. Zero predicates match nothing.
  if ps.len == 0:
    return Predicate(sql: "0")
  if ps.len == 1:
    return ps[0]
  var parts: seq[string]
  for p in ps:
    parts.add "(" & p.sql & ")"
    result.params.add p.params
  result.sql = parts.join(" OR ")

const relMarker = '\x01'
  ## Marks a column that belongs to a relation path rather than the root
  ## table. A Predicate's `sql` is built before the query set's joins are
  ## planned (more `filter`/`selectRelated` calls can still follow), so the
  ## real table alias isn't known yet; `refCol` embeds the path between two
  ## `relMarker` bytes and `resolveRelMarkers` substitutes the alias once the
  ## joins for the final query are planned.

proc refCol(col, path: string): string =
  if path.len == 0:
    return qcol(col)
  result.add relMarker
  result.add path
  result.add relMarker
  result.add '.'
  result.add quoteIdent(col)

proc resolveRelMarkers(
    sql: string, aliasOf: Table[string, string]
): string {.raises: [QueryError].} =
  if relMarker notin sql:
    return sql
  let parts = sql.split(relMarker)
  for i in 0 ..< parts.len:
    if i mod 2 == 0:
      result.add parts[i]
    else:
      try:
        result.add quoteIdent(aliasOf[parts[i]])
      except KeyError:
        raise newException(
          QueryError, "fastorm: internal error resolving relation '" & parts[i] & "'"
        )

proc eqPredicate*(col: string, v: DbValue, negate = false, path = ""): Predicate =
  let c = refCol(col, path)
  if v.kind == dvNull:
    Predicate(sql: c & (if negate: " IS NOT NULL" else: " IS NULL"))
  elif negate:
    Predicate(sql: "(" & c & " <> ? OR " & c & " IS NULL)", params: @[v])
  else:
    Predicate(sql: c & " = ?", params: @[v])

proc cmpPredicate*(col, op: string, v: DbValue, path = ""): Predicate =
  Predicate(sql: refCol(col, path) & " " & op & " ?", params: @[v])

proc inPredicate*(col: string, vs: seq[DbValue], negate = false, path = ""): Predicate =
  if vs.len == 0:
    return Predicate(sql: if negate: "1" else: "0")
  let marks = repeat("?", vs.len).join(", ")
  Predicate(
    sql: refCol(col, path) & (if negate: " NOT IN (" else: " IN (") & marks & ")",
    params: vs,
  )

proc nullPredicate*(col: string, isNull: bool, path = ""): Predicate =
  Predicate(sql: refCol(col, path) & (if isNull: " IS NULL" else: " IS NOT NULL"))

proc escapeLike(s: string): string =
  for c in s:
    if c in {'\\', '%', '_'}:
      result.add '\\'
    result.add c

proc textPredicate*(col, lookup: string, v: DbValue, path = ""): Predicate =
  ## String lookups. Case-insensitive variants use SQLite `LIKE`, which folds
  ## ASCII letters only.
  let c = refCol(col, path)
  let s =
    if v.kind == dvText:
      v.s
    else:
      $v
  case lookup
  of "iexact":
    Predicate(sql: c & " = ? COLLATE NOCASE", params: @[v])
  of "contains":
    Predicate(sql: "instr(" & c & ", ?) > 0", params: @[v])
  of "startsWith":
    Predicate(sql: "substr(" & c & ", 1, ?) = ?", params: @[toDbValue(s.len), v])
  of "endsWith":
    if s.len == 0:
      Predicate(sql: c & " IS NOT NULL")
    else:
      Predicate(sql: "substr(" & c & ", ?) = ?", params: @[toDbValue(-s.len), v])
  of "icontains":
    Predicate(
      sql: c & " LIKE ? ESCAPE '\\'", params: @[toDbValue("%" & escapeLike(s) & "%")]
    )
  of "istartsWith":
    Predicate(sql: c & " LIKE ? ESCAPE '\\'", params: @[toDbValue(escapeLike(s) & "%")])
  of "iendsWith":
    Predicate(sql: c & " LIKE ? ESCAPE '\\'", params: @[toDbValue("%" & escapeLike(s))])
  else:
    raise newException(Defect, "unknown text lookup " & lookup)

# -- SQL compilation ---------------------------------------------------------

proc whereClause[T](qs: QuerySet[T], params: var seq[DbValue]): string =
  if qs.wheres.len == 0:
    return ""
  var parts: seq[string]
  for p in qs.wheres:
    parts.add "(" & p.sql & ")"
    params.add p.params
  " WHERE " & parts.join(" AND ")

proc columnList(m: ModelMeta, alias: string): string =
  var cols: seq[string]
  for f in m.fields:
    cols.add qcol(f.column, alias)
  cols.join(", ")

proc columnList(columns: seq[string], alias: string): string =
  var cols: seq[string]
  for c in columns:
    cols.add qcol(c, alias)
  cols.join(", ")

proc rootColumns(m: ModelMeta, selected: seq[string]): seq[string] =
  if selected.len == 0:
    for f in m.fields:
      result.add f.column
  else:
    result = selected

proc fromClause(m: ModelMeta): string =
  quoteIdent(m.table) & " AS " & quoteIdent(rootAlias)

# -- relation cache ----------------------------------------------------------

proc ensureCache(m: FastormModel): RelationCache =
  if m.cache.isNil:
    m.cache = RelationCache()
  m.cache

proc rememberSingle*(m: FastormModel, name: string, value: FastormModel) =
  let c = ensureCache(m)
  c.single[name] = value
  if c.missing.hasKey(name):
    c.missing.del(name)

proc rememberMissing*(m: FastormModel, name: string) =
  let c = ensureCache(m)
  c.missing[name] = true
  if c.single.hasKey(name):
    c.single.del(name)

proc rememberMany*[T: FastormModel](
    m: FastormModel, name: string, values: openArray[T]
) =
  var refs: seq[FastormModel]
  for v in values:
    refs.add v
  ensureCache(m).many[name] = refs

proc cachedSingle*[T: FastormModel](
    m: FastormModel, name: string
): tuple[hit: bool, value: Option[T]] =
  if m.cache.isNil:
    return
  try:
    if m.cache.missing[name]:
      return (true, none(T))
  except KeyError:
    discard
  try:
    return (true, some(T(m.cache.single[name])))
  except KeyError:
    discard

proc cachedMany*[T: FastormModel](
    m: FastormModel, name: string
): tuple[hit: bool, value: seq[T]] =
  if m.cache.isNil:
    return
  var rows: seq[FastormModel]
  try:
    rows = m.cache.many[name]
  except KeyError:
    return
  result.hit = true
  for v in rows:
    result.value.add T(v)

proc relationParent(root: FastormModel, path: string): FastormModel =
  if path.len == 0:
    return root
  result = root
  for part in path.split('.'):
    let hit = cachedSingle[FastormModel](result, part)
    if not hit.hit or hit.value.isNone:
      return nil
    result = hit.value.get

# -- model and prefetch registries ------------------------------------------

var modelFns: Table[string, tuple[toRow: RowFn, hydrate: HydrateFn]]
var prefetchDefs: seq[PrefetchDef]

proc registerModelFns*(name: string, toRow: RowFn, hydrate: HydrateFn) =
  modelFns[name] = (toRow, hydrate)

proc registerPrefetch*(d: PrefetchDef) =
  for existing in prefetchDefs:
    if existing.owner == d.owner and existing.name == d.name:
      return
  prefetchDefs.add d

proc modelByName(name: string): ModelMeta {.gcsafe, raises: [QueryError].} =
  for m in registeredModels():
    if m.name == name:
      return m
  raise newException(QueryError, "fastorm: model " & name & " is not registered")

proc fnsOf(
    name: string
): tuple[toRow: RowFn, hydrate: HydrateFn] {.gcsafe, raises: [QueryError].} =
  {.cast(gcsafe).}:
    try:
      result = modelFns[name]
    except KeyError:
      raise newException(QueryError, "fastorm: model " & name & " is not registered")

proc findPrefetch(owner, name: string): PrefetchDef {.gcsafe.} =
  {.cast(gcsafe).}:
    for d in prefetchDefs:
      if d.owner == owner and d.name == name:
        return d

proc prefetchBy(owner, name: string): PrefetchDef {.gcsafe, raises: [QueryError].} =
  result = findPrefetch(owner, name)
  if result.name.len == 0:
    raise
      newException(QueryError, "fastorm: " & owner & " has no relation '" & name & "'")

proc skippedField(field: FieldDef, skip: openArray[string]): bool =
  field.name in skip or jsonKey(field) in skip

proc encodeModel(
    model: FastormModel,
    modelName: string,
    expands: seq[string],
    skip: openArray[string],
): JsonNode =
  ## Columns first, then each expanded relation from the cache. A missing
  ## forward relation is JSON `null`; a missing reverse relation is `[]`.
  if model.isNil:
    return newJNull()
  var meta: ModelMeta
  var toRow: RowFn
  var found = false
  for m in registeredModels():
    if m.name == modelName:
      meta = m
      found = true
      break
  if not found:
    return newJNull()
  {.cast(gcsafe).}:
    try:
      toRow = modelFns[modelName].toRow
    except KeyError:
      return newJNull()
  let row = toRow(model)
  result = newJObject()
  for i, field in meta.fields:
    if skippedField(field, skip):
      continue
    if i < row.len:
      result[jsonKey(field)] = dbToJson(row[i], field.kind)
  var groups: OrderedTable[string, seq[string]]
  for path in expands:
    if path.len == 0:
      continue
    let dot = path.find('.')
    let head =
      if dot < 0:
        path
      else:
        path[0 ..< dot]
    let tail =
      if dot < 0:
        ""
      else:
        path[dot + 1 .. ^1]
    if head notin groups:
      groups[head] = @[]
    if tail.len > 0 and tail notin groups[head]:
      groups[head].add tail
  for rel, suffixes in groups.pairs:
    let spec = findPrefetch(modelName, rel)
    let single = cachedSingle[FastormModel](model, rel)
    if single.hit:
      if single.value.isNone:
        result[rel] = newJNull()
      else:
        result[rel] = encodeModel(single.value.get, spec.target, suffixes, [])
      continue
    let many = cachedMany[FastormModel](model, rel)
    if many.hit:
      var arr = newJArray()
      for child in many.value:
        arr.add encodeModel(child, spec.target, suffixes, [])
      result[rel] = arr
      continue
    result[rel] =
      if spec.kind == pfReverse:
        newJArray()
      else:
        newJNull()

proc colIndex(m: ModelMeta, column: string): int {.raises: [QueryError].} =
  for i, f in m.fields:
    if f.column == column:
      return i
  raise newException(QueryError, m.name & " has no column '" & column & "'")

proc valueKey(v: DbValue): string =
  case v.kind
  of dvNull:
    "n"
  of dvInt:
    "i" & $v.i
  of dvFloat:
    "f" & $v.f
  of dvText:
    "t" & v.s
  of dvBlob:
    "b" & $v.b.len

proc planJoins(
    root: ModelMeta, paths: seq[string]
): seq[Join] {.raises: [QueryError].} =
  var aliasOf = {"": rootAlias}.toTable
  var modelOf = {"": root.name}.toTable
  for path in paths:
    var parentPath = ""
    var acc = ""
    for part in path.split('.'):
      if part.len == 0:
        raise newException(QueryError, "empty relation in '" & path & "'")
      acc =
        if acc.len == 0:
          part
        else:
          acc & "." & part
      if acc in aliasOf:
        parentPath = acc
        continue
      let parent = modelByName(modelOf.getOrDefault(parentPath))
      let fi = parent.findField(part)
      if fi < 0 or parent.fields[fi].kind != fkForeignKey:
        raise
          newException(QueryError, parent.name & " has no foreign key '" & part & "'")
      let f = parent.fields[fi]
      let target = modelByName(f.target)
      let j = Join(
        parentPath: parentPath,
        field: part,
        path: acc,
        model: target.name,
        table: target.table,
        alias: "t" & $(result.len + 1),
        parentAlias: aliasOf.getOrDefault(parentPath),
        fkColumn: f.column,
        targetColumn: f.targetColumn,
        pkIndex: target.pkIndex,
        ncols: target.fields.len,
      )
      result.add j
      aliasOf[acc] = j.alias
      modelOf[acc] = target.name
      parentPath = acc

proc joinedFrom(
    meta: ModelMeta, paths: seq[string]
): tuple[clause: string, joins: seq[Join], aliasOf: Table[string, string]] {.
    raises: [QueryError]
.} =
  ## The FROM clause (base table plus any LEFT JOINs needed for `paths`) and
  ## the path -> alias map used to resolve relation-marked columns.
  let joins = planJoins(meta, paths)
  var aliasOf = {"": rootAlias}.toTable
  var clause = meta.fromClause
  for j in joins:
    aliasOf[j.path] = j.alias
    clause.add " LEFT JOIN " & quoteIdent(j.table) & " AS " & quoteIdent(j.alias) &
      " ON " & qcol(j.fkColumn, j.parentAlias) & " = " & qcol(j.targetColumn, j.alias)
  (clause, joins, aliasOf)

proc selectSql*[T](
    qs: QuerySet[T], params: var seq[DbValue], limitOverride = -1
): string {.raises: [QueryError].} =
  ## Builds the parameterized SELECT statement for `qs`.
  mixin modelMeta
  let m = modelMeta(T)
  let (fromSql, joins, aliasOf) = joinedFrom(m, qs.selects & qs.relPaths)
  var lists = @[columnList(rootColumns(m, qs.columns), rootAlias)]
  for j in joins:
    lists.add columnList(modelByName(j.model), j.alias)
  result = "SELECT " & lists.join(", ") & " FROM " & fromSql
  result.add resolveRelMarkers(qs.whereClause(params), aliasOf)
  if qs.ordering.len > 0:
    var orders: seq[string]
    for o in qs.ordering:
      let desc = o.len > 0 and o[0] == '-'
      let col =
        if desc:
          o[1 .. ^1]
        else:
          o
      orders.add qcol(col) & (if desc: " DESC" else: " ASC")
    result.add " ORDER BY " & orders.join(", ")
  let lim = if limitOverride >= 0: limitOverride else: qs.limitN
  if lim >= 0 or qs.offsetN > 0:
    result.add " LIMIT ? OFFSET ?"
    params.add toDbValue(lim)
    params.add toDbValue(qs.offsetN)

proc queryWhere(
    meta: ModelMeta, pred: Predicate, db: Database
): Future[seq[seq[DbValue]]] {.async: (raises: [DatabaseError, CancelledError]).} =
  let sql =
    "SELECT " & columnList(meta, rootAlias) & " FROM " & meta.fromClause & " WHERE " &
    pred.sql
  return (await db.query(sql, pred.params)).rows

proc deduped(values: seq[DbValue]): seq[DbValue] =
  var seen: Table[string, bool]
  for v in values:
    let k = valueKey(v)
    if k notin seen:
      seen[k] = true
      result.add v

proc loadPrefetch(
    spec: PrefetchDef, parents: seq[FastormModel], db: Database
): Future[void] {.async: (raises: [DatabaseError, QueryError, CancelledError]).} =
  if parents.len == 0:
    return
  let ownerFns = fnsOf(spec.owner)
  let targetFns = fnsOf(spec.target)
  let ownerMeta = modelByName(spec.owner)
  let targetMeta = modelByName(spec.target)
  case spec.kind
  of pfForward:
    let fkIndex = colIndex(ownerMeta, spec.keyColumn)
    var keys: seq[DbValue]
    for m in parents:
      let v = ownerFns.toRow(m)[fkIndex]
      if v.kind != dvNull:
        keys.add v
    var byKey: Table[string, FastormModel]
    if keys.len > 0:
      let rows = await queryWhere(
        targetMeta, inPredicate(targetMeta.pkField.column, deduped(keys)), db
      )
      for row in rows:
        byKey[valueKey(row[targetMeta.pkIndex])] = targetFns.hydrate(row)
    for m in parents:
      let v = ownerFns.toRow(m)[fkIndex]
      let found =
        if v.kind == dvNull:
          nil
        else:
          byKey.getOrDefault(valueKey(v))
      if found.isNil:
        rememberMissing(m, spec.name)
      else:
        rememberSingle(m, spec.name, found)
  of pfReverse:
    let fkIndex = colIndex(targetMeta, spec.keyColumn)
    var keys: seq[DbValue]
    for m in parents:
      keys.add ownerFns.toRow(m)[ownerMeta.pkIndex]
    var groups: Table[string, seq[FastormModel]]
    if keys.len > 0:
      let rows =
        await queryWhere(targetMeta, inPredicate(spec.keyColumn, deduped(keys)), db)
      for row in rows:
        groups.mgetOrPut(valueKey(row[fkIndex]), @[]).add targetFns.hydrate(row)
    for m in parents:
      let k = valueKey(ownerFns.toRow(m)[ownerMeta.pkIndex])
      rememberMany(m, spec.name, groups.getOrDefault(k))

proc applyPath(
    owner: string, models: seq[FastormModel], path: string, db: Database
): Future[void] {.async: (raises: [DatabaseError, QueryError, CancelledError]).} =
  if models.len == 0 or path.len == 0:
    return
  let dot = path.find('.')
  let head =
    if dot < 0:
      path
    else:
      path[0 ..< dot]
  let spec = prefetchBy(owner, head)
  await loadPrefetch(spec, models, db)
  if dot < 0:
    return
  var children: seq[FastormModel]
  for m in models:
    let many = cachedMany[FastormModel](m, head)
    if many.hit:
      for child in many.value:
        children.add child
    else:
      let one = cachedSingle[FastormModel](m, head)
      if one.hit and one.value.isSome:
        children.add one.value.get
  await applyPath(spec.target, children, path[dot + 1 .. ^1], db)

proc applyPrefetches(
    owner: string, models: seq[FastormModel], paths: seq[string], db: Database
): Future[void] {.async: (raises: [DatabaseError, QueryError, CancelledError]).} =
  for path in paths:
    await applyPath(owner, models, path, db)

proc attachJoins[T: FastormModel](
    model: T, row: seq[DbValue], joins: seq[Join]
) {.raises: [DatabaseError, QueryError].} =
  mixin modelMeta
  var at = modelMeta(T).fields.len
  for j in joins:
    let slice = row[at ..< at + j.ncols]
    at += j.ncols
    let parent = relationParent(model, j.parentPath)
    if parent.isNil:
      continue
    if slice[j.pkIndex].kind == dvNull:
      rememberMissing(parent, j.field)
    else:
      rememberSingle(parent, j.field, fnsOf(j.model).hydrate(slice))

proc fetch[T](qs: QuerySet[T], limitOverride: int): Future[seq[T]] {.async.} =
  mixin fromRow, modelMeta
  var params: seq[DbValue]
  let sql = qs.selectSql(params, limitOverride)
  let db = resolveDb(qs.db)
  if qs.forUpdate and not db.inTransaction:
    raise newException(
      QueryError,
      "selectForUpdate() needs an open transaction: " &
        "run the query inside `atomic` and give it the handle, e.g. " & modelMeta(T).name &
        ".objects.withDb(tx).selectForUpdate()",
    )
  let res = await db.query(sql, params)
  let meta = modelMeta(T)
  let selected = rootColumns(meta, qs.columns)
  let joins = planJoins(meta, qs.selects & qs.relPaths)
  var width = selected.len
  for j in joins:
    width += j.ncols
  var models: seq[T]
  for row in res.rows:
    if row.len != width:
      raise
        newException(DatabaseError, "expected " & $width & " columns, got " & $row.len)
    let model = fromRow(T, row[0 ..< selected.len], qs.columns)
    if joins.len > 0:
      attachJoins(model, row, joins)
    models.add model
  if qs.prefetches.len > 0 and models.len > 0:
    var refs: seq[FastormModel]
    for m in models:
      refs.add m
    await applyPrefetches(meta.name, refs, qs.prefetches, db)
  if qs.expands.len > 0:
    for m in models:
      rememberExpand(m, qs.expands)
  return models

proc all*[T](qs: QuerySet[T]): Future[seq[T]] {.async.} =
  ## All matching rows; an empty sequence means nothing matched.
  return await qs.fetch(-1)

proc first*[T](qs: QuerySet[T]): Future[Option[T]] {.async.} =
  let rows = await qs.fetch(1)
  return
    if rows.len > 0:
      some(rows[0])
    else:
      none(T)

proc getImpl*[T](qs: QuerySet[T]): Future[Option[T]] {.async.} =
  ## Exactly one match gives `some`, no match gives `none`, and several
  ## matches raise `MultipleObjectsReturned`.
  mixin modelMeta
  let rows = await qs.fetch(2)
  if rows.len > 1:
    raise newException(
      MultipleObjectsReturned, "get() matched more than one " & modelMeta(T).name
    )
  return
    if rows.len == 1:
      some(rows[0])
    else:
      none(T)

proc count*[T](qs: QuerySet[T]): Future[int] {.async.} =
  mixin modelMeta
  var params: seq[DbValue]
  let (fromSql, _, aliasOf) = joinedFrom(modelMeta(T), qs.relPaths)
  let source = fromSql & resolveRelMarkers(qs.whereClause(params), aliasOf)
  var sql = "SELECT COUNT(*) FROM " & source
  if qs.limitN >= 0 or qs.offsetN > 0:
    sql = "SELECT COUNT(*) FROM (SELECT 1 FROM " & source & " LIMIT ? OFFSET ?)"
    params.add toDbValue(qs.limitN)
    params.add toDbValue(qs.offsetN)
  let res = await resolveDb(qs.db).query(sql, params)
  return int(res.rows[0][0].i)

proc aggregateName(kind: AggregateKind): string =
  case kind
  of akCount: "COUNT"
  of akSum: "SUM"
  of akAvg: "AVG"
  of akMin: "MIN"
  of akMax: "MAX"

proc aggregateImpl*[T](
    qs: QuerySet[T], specs: seq[AggregateSpec]
): Future[AggregateResult] {.async.} =
  ## Evaluates several SQL aggregates with the QuerySet's filters and slice.
  ## Ordering and relation-loading directives do not affect aggregate values.
  mixin modelMeta
  if specs.len == 0:
    raise newException(QueryError, "aggregate() needs at least one aggregate")
  let meta = modelMeta(T)
  var params: seq[DbValue]
  var selected: seq[string]
  for field in meta.fields:
    selected.add qcol(field.column) & " AS " & quoteIdent(field.column)
  let (fromSql, _, aliasOf) = joinedFrom(meta, qs.relPaths)
  var source =
    "SELECT " & selected.join(", ") & " FROM " & fromSql &
    resolveRelMarkers(qs.whereClause(params), aliasOf)
  if qs.limitN >= 0 or qs.offsetN > 0:
    source.add " LIMIT ? OFFSET ?"
    params.add toDbValue(qs.limitN)
    params.add toDbValue(qs.offsetN)
  var expressions: seq[string]
  for spec in specs:
    let operand =
      if spec.column == "*":
        "*"
      else:
        quoteIdent("aggregate_source") & "." & quoteIdent(spec.column)
    expressions.add aggregateName(spec.kind) & "(" & operand & ") AS " &
      quoteIdent(spec.alias)
  let sql =
    "SELECT " & expressions.join(", ") & " FROM (" & source & ") AS " &
    quoteIdent("aggregate_source")
  let rows = (await resolveDb(qs.db).query(sql, params)).rows
  if rows.len != 1:
    raise newException(DatabaseError, "aggregate query returned no result row")
  for i, spec in specs:
    result[spec.alias] = rows[0][i]

proc exists*[T](qs: QuerySet[T]): Future[bool] {.async.} =
  return (await qs.first()).isSome

proc delete*[T](qs: QuerySet[T]): Future[int] {.async.} =
  ## Deletes every matching row and returns the number deleted. Ordering,
  ## limits and offsets are ignored. SQLite's `DELETE` cannot join other
  ## tables, so a filter that reaches through a relation runs as a subquery
  ## (`WHERE pk IN (SELECT ...)`) instead of a plain `WHERE`.
  mixin modelMeta
  let meta = modelMeta(T)
  var params: seq[DbValue]
  if qs.relPaths.len == 0:
    let sql = "DELETE FROM " & meta.fromClause & qs.whereClause(params)
    return int((await resolveDb(qs.db).execute(sql, params)).changes)
  let (fromSql, _, aliasOf) = joinedFrom(meta, qs.relPaths)
  let whereSql = resolveRelMarkers(qs.whereClause(params), aliasOf)
  let sql =
    "DELETE FROM " & quoteIdent(meta.table) & " WHERE " & quoteIdent(
      meta.pkField.column
    ) & " IN (SELECT " & qcol(meta.pkField.column) & " FROM " & fromSql & whereSql & ")"
  return int((await resolveDb(qs.db).execute(sql, params)).changes)

proc updateImpl*[T](
    qs: QuerySet[T], sets: seq[UpdateAssignment]
): Future[int] {.async.} =
  ## Bulk update without validation; returns the number of rows changed. As
  ## with `delete`, a filter through a relation runs as a subquery since
  ## SQLite's `UPDATE` cannot join other tables.
  mixin modelMeta
  if sets.len == 0:
    return 0
  let meta = modelMeta(T)
  var assigns: seq[string]
  var setParams: seq[DbValue]
  for s in sets:
    assigns.add quoteIdent(s.column) & " = " & s.sql
    setParams.add s.params
  if qs.relPaths.len == 0:
    var params = setParams
    let sql =
      "UPDATE " & meta.fromClause & " SET " & assigns.join(", ") & qs.whereClause(
        params
      )
    return int((await resolveDb(qs.db).execute(sql, params)).changes)
  var whereParams: seq[DbValue]
  let (fromSql, _, aliasOf) = joinedFrom(meta, qs.relPaths)
  let whereSql = resolveRelMarkers(qs.whereClause(whereParams), aliasOf)
  let sql =
    "UPDATE " & quoteIdent(meta.table) & " SET " & assigns.join(", ") & " WHERE " &
    quoteIdent(meta.pkField.column) & " IN (SELECT " & qcol(meta.pkField.column) &
    " FROM " & fromSql & whereSql & ")"
  var params = setParams
  params.add whereParams
  return int((await resolveDb(qs.db).execute(sql, params)).changes)

# -- instance persistence ----------------------------------------------------

proc insertRow(
    db: Database, m: ModelMeta, row: seq[DbValue], skipPk: bool
): Future[ExecResult] =
  var cols, marks: seq[string]
  var params: seq[DbValue]
  for i, f in m.fields:
    if skipPk and i == m.pkIndex:
      continue
    cols.add quoteIdent(f.column)
    marks.add "?"
    params.add row[i]
  let sql =
    if cols.len == 0:
      "INSERT INTO " & quoteIdent(m.table) & " DEFAULT VALUES"
    else:
      "INSERT INTO " & quoteIdent(m.table) & " (" & cols.join(", ") & ") VALUES (" &
        marks.join(", ") & ")"
  db.execute(sql, params)

proc saveImpl*[T](model: T, db: Database = nil): Future[void] {.async.} =
  ## Inserts the model when its primary key is unset, otherwise updates the
  ## existing row (inserting it if no row has that key). Raises
  ## `ValidationError` before touching the database if validation fails.
  mixin modelMeta, toRow, validate, fastormPrepare, fastormPkIsSet, fastormSetRowId
  let conn = resolveDb(db)
  let m = modelMeta(T)
  let creating = not fastormPkIsSet(model)
  if not creating:
    var names: seq[string]
    for f in m.fields:
      names.add f.name
    if not isFullyLoaded(model, names):
      raise newException(
        QueryError,
        m.name & " was loaded with only()/defer() and cannot be saved; select every " &
          "field, or use QuerySet.update",
      )
  let autoIncrement = creating and m.pkField.kind == fkInteger
  fastormPrepare(model, creating)
  let errors = validate(model)
  if errors.len > 0:
    raise newValidationError(errors)
  let row = toRow(model)
  if creating:
    let res = await conn.insertRow(m, row, autoIncrement)
    if autoIncrement:
      fastormSetRowId(model, res.lastInsertId)
    return
  var assigns: seq[string]
  var params: seq[DbValue]
  for i, f in m.fields:
    if i == m.pkIndex:
      continue
    assigns.add quoteIdent(f.column) & " = ?"
    params.add row[i]
  var changed = 0'i64
  if assigns.len > 0:
    params.add row[m.pkIndex]
    let sql =
      "UPDATE " & quoteIdent(m.table) & " SET " & assigns.join(", ") & " WHERE " &
      quoteIdent(m.pkField.column) & " = ?"
    changed = (await conn.execute(sql, params)).changes
  if changed == 0:
    let exists = await conn.query(
      "SELECT 1 FROM " & quoteIdent(m.table) & " WHERE " & quoteIdent(m.pkField.column) &
        " = ?",
      @[row[m.pkIndex]],
    )
    if exists.rows.len == 0:
      discard await conn.insertRow(m, row, false)

proc deleteImpl*[T](model: T, db: Database = nil): Future[void] {.async.} =
  mixin modelMeta, toRow, fastormPkIsSet
  if not fastormPkIsSet(model):
    raise newException(
      QueryError,
      "cannot delete a " & modelMeta(T).name & " that has no primary key value",
    )
  let m = modelMeta(T)
  let row = toRow(model)
  discard await resolveDb(db).execute(
    "DELETE FROM " & quoteIdent(m.table) & " WHERE " & quoteIdent(m.pkField.column) &
      " = ?",
    @[row[m.pkIndex]],
  )

proc getByPk*[T](
    t: typedesc[T], pk: DbValue, db: Database = nil
): Future[Option[T]] {.async.} =
  mixin modelMeta
  if pk.kind == dvNull:
    return none(T)
  let m = modelMeta(T)
  var qs = initQuerySet[T]()
  qs.db = db
  qs.wheres.add eqPredicate(m.pkField.column, pk)
  return await qs.getImpl()
