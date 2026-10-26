## The `model` macro and the compile-time checked query macros
## (`filter`, `exclude`, `get`, `update`, `only`, `defer`, `F`).
##
## Every model's field specs are recorded in a compile-time cache so that
## later models can inherit from it (`model Child = ref Parent:`) or reference
## it with `ForeignKey`, and so query macros can validate field names and
## lookups against the model.

import std/[macros, macrocache, options, times, sequtils, strutils, sets, tables, json]
import ./queryset
import chronos
import ./[fields, values, uuids, sqlite, queryset]

const modelCache = CacheTable"fastorm.models"
const forwardCache = CacheTable"fastorm.forward" ## "Book.author" -> "Author"
const reverseCache = CacheTable"fastorm.reverse" ## "Author.books" -> "Book"
const manyCache = CacheTable"fastorm.many" ## "Book.authors" -> "Author"
const indexCache = CacheTable"fastorm.indexes" ## index name -> owning model

const fieldCtors = [
  "UUIDField", "CharField", "TextField", "IntegerField", "FloatField", "BooleanField",
  "DateTimeField", "DateField", "TimeField", "DurationField", "DecimalField",
  "JSONField", "BinaryField", "EmailField", "URLField", "SlugField", "ForeignKey",
  "ManyToManyField",
]
const choiceFields =
  ["CharField", "EmailField", "URLField", "SlugField", "IntegerField", "FloatField"]
const enumChoiceFields = ["CharField", "EmailField", "URLField", "SlugField"]
const textLookups = [
  "iexact", "contains", "icontains", "startsWith", "istartsWith", "endsWith",
  "iendsWith",
]

type
  FieldSpec = object
    name: string ## field name as written in the DSL
    ctor: string
    column: string
    target: string ## foreign keys: referenced model and its key
    targetTable: string
    targetColumn: string
    targetPkCtor: string
    args: seq[NimNode] ## remaining constructor options as `key = value`
    validator: NimNode
    default: NimNode
    primaryKey: bool
    null: bool
    relatedName: string
    relatedExplicit: bool
    throughTable: string
    enumType: string ## `choices: Status` stores the enum's name
    choiceLits: seq[NimNode]

  RelGen = object
    target: string
    name: string
    column: string

  ManySpec = object
    name: string
    target: string
    relatedName: string
    relatedExplicit: bool
    table: string

  ManyGen = object
    target: string
    name: string
    table: string
    ownerColumn: string
    targetColumn: string

  MetaIndexSpec = object
    name: string
    explicit: bool
    unique: bool
    fields: seq[string] ## field names; a leading `-` sorts that column descending

  ModelSpec = object
    name: string
    table: string
    parent: string
    abstract: bool
    fields: seq[FieldSpec]
    indexes: seq[MetaIndexSpec]
    ordering: seq[string]
    manyToMany: seq[ManySpec]

# -- compile-time cache encoding ---------------------------------------------

proc orEmpty(n: NimNode): NimNode =
  if n.isNil:
    newEmptyNode()
  else:
    n.copyNimTree

proc orNil(n: NimNode): NimNode =
  if n.kind == nnkEmpty: nil else: n.copyNimTree

proc encode(f: FieldSpec): NimNode =
  newStmtList(
    newLit(f.name),
    newLit(f.ctor),
    newLit(f.column),
    newLit(f.target),
    newLit(f.targetTable),
    newLit(f.targetColumn),
    newLit(f.targetPkCtor),
    newStmtList(f.args.mapIt(it.copyNimTree)),
    orEmpty(f.validator),
    orEmpty(f.default),
    newLit(ord(f.primaryKey)),
    newLit(ord(f.null)),
    newLit(f.relatedName),
    newLit(ord(f.relatedExplicit)),
    newLit(f.enumType),
    newStmtList(f.choiceLits.mapIt(it.copyNimTree)),
  )

proc decodeField(n: NimNode): FieldSpec =
  FieldSpec(
    name: n[0].strVal,
    ctor: n[1].strVal,
    column: n[2].strVal,
    target: n[3].strVal,
    targetTable: n[4].strVal,
    targetColumn: n[5].strVal,
    targetPkCtor: n[6].strVal,
    args: toSeq(n[7].children).mapIt(it.copyNimTree),
    validator: orNil(n[8]),
    default: orNil(n[9]),
    primaryKey: n[10].intVal != 0,
    null: n[11].intVal != 0,
    relatedName: n[12].strVal,
    relatedExplicit: n[13].intVal != 0,
    enumType: n[14].strVal,
    choiceLits: toSeq(n[15].children).mapIt(it.copyNimTree),
  )

proc encode(ix: MetaIndexSpec): NimNode =
  newStmtList(
    newLit(ix.name),
    newLit(ord(ix.explicit)),
    newLit(ord(ix.unique)),
    newStmtList(ix.fields.mapIt(newLit(it))),
  )

proc decodeIndex(n: NimNode): MetaIndexSpec =
  MetaIndexSpec(
    name: n[0].strVal,
    explicit: n[1].intVal != 0,
    unique: n[2].intVal != 0,
    fields: toSeq(n[3].children).mapIt(it.strVal),
  )

proc encode(m: ManySpec): NimNode =
  newStmtList(
    newLit(m.name),
    newLit(m.target),
    newLit(m.relatedName),
    newLit(ord(m.relatedExplicit)),
    newLit(m.table),
  )

proc decodeMany(n: NimNode): ManySpec =
  ManySpec(
    name: n[0].strVal,
    target: n[1].strVal,
    relatedName: n[2].strVal,
    relatedExplicit: n[3].intVal != 0,
    table: n[4].strVal,
  )

proc encode(m: ModelSpec): NimNode =
  newStmtList(
    newLit(m.name),
    newLit(m.table),
    newLit(m.parent),
    newLit(ord(m.abstract)),
    newStmtList(m.fields.mapIt(encode(it))),
    newStmtList(m.indexes.mapIt(encode(it))),
    newStmtList(m.ordering.mapIt(newLit(it))),
    newStmtList(m.manyToMany.mapIt(encode(it))),
  )

proc readModel(name: string): ModelSpec =
  let n = modelCache[name]
  ModelSpec(
    name: n[0].strVal,
    table: n[1].strVal,
    parent: n[2].strVal,
    abstract: n[3].intVal != 0,
    fields: toSeq(n[4].children).mapIt(decodeField(it)),
    indexes: toSeq(n[5].children).mapIt(decodeIndex(it)),
    ordering: toSeq(n[6].children).mapIt(it.strVal),
    manyToMany: toSeq(n[7].children).mapIt(decodeMany(it)),
  )

# -- field helpers -----------------------------------------------------------

proc isForeignKey(f: FieldSpec): bool =
  f.ctor == "ForeignKey"

proc isManyToMany(f: FieldSpec): bool =
  f.ctor == "ManyToManyField"

proc attrName(f: FieldSpec): string =
  ## Foreign keys store the referenced key in `<name>Id`; `<name>` itself is
  ## an async accessor that loads the related model.
  if f.isForeignKey:
    f.name & "Id"
  else:
    f.name

proc scalarType(ctor: string): NimNode =
  case ctor
  of "UUIDField":
    ident"UUID"
  of "CharField", "TextField", "EmailField", "URLField", "SlugField":
    ident"string"
  of "IntegerField":
    ident"int"
  of "FloatField":
    ident"float"
  of "BooleanField":
    ident"bool"
  of "DateTimeField":
    bindSym"Time"
  of "DateField":
    bindSym"Date"
  of "TimeField":
    bindSym"TimeOfDay"
  of "DurationField":
    bindSym"TimeSpan"
  of "DecimalField":
    bindSym"Decimal"
  of "JSONField":
    bindSym"JsonNode"
  of "BinaryField":
    nnkBracketExpr.newTree(ident"seq", ident"byte")
  else:
    error("fastorm: unsupported field type " & ctor)

proc nimType(f: FieldSpec): NimNode =
  let base =
    if f.enumType.len > 0:
      ident(f.enumType)
    else:
      scalarType(if f.isForeignKey: f.targetPkCtor else: f.ctor)
  if f.null:
    nnkBracketExpr.newTree(ident"Option", base)
  else:
    base

proc kindIdent(ctor: string): NimNode =
  case ctor
  of "UUIDField":
    ident"fkUUID"
  of "CharField", "EmailField", "URLField", "SlugField":
    ident"fkChar"
  of "TextField":
    ident"fkText"
  of "IntegerField":
    ident"fkInteger"
  of "FloatField":
    ident"fkFloat"
  of "BooleanField":
    ident"fkBoolean"
  of "DateTimeField":
    ident"fkDateTime"
  of "DateField":
    ident"fkDate"
  of "TimeField":
    ident"fkTime"
  of "DurationField":
    ident"fkDuration"
  of "DecimalField":
    ident"fkDecimal"
  of "JSONField":
    ident"fkJson"
  of "BinaryField":
    ident"fkBinary"
  else:
    error("fastorm: unsupported field type " & ctor)

proc fieldKind(ctor: string): FieldKind =
  case ctor
  of "UUIDField": fkUUID
  of "CharField", "EmailField", "URLField", "SlugField": fkChar
  of "TextField": fkText
  of "IntegerField": fkInteger
  of "FloatField": fkFloat
  of "BooleanField": fkBoolean
  of "DateTimeField": fkDateTime
  of "DateField": fkDate
  of "TimeField": fkTime
  of "DurationField": fkDuration
  of "DecimalField": fkDecimal
  of "JSONField": fkJson
  of "BinaryField": fkBinary
  else:
    error("fastorm: unsupported field type " & ctor)

proc arg(f: FieldSpec, key: string): NimNode =
  for a in f.args:
    if a[0].eqIdent(key):
      return a[1]
  nil

proc argIsTrue(f: FieldSpec, key: string): bool =
  let v = f.arg(key)
  not v.isNil and v.eqIdent("true")

proc boolLiteral(n: NimNode, key: string): bool =
  if n.kind == nnkIdent and (n.eqIdent("true") or n.eqIdent("false")):
    return n.eqIdent("true")
  error("fastorm: `" & key & "` must be the literal true or false", n)

proc flag(f: FieldSpec, key: string, default: bool): bool =
  let v = f.arg(key)
  if v.isNil:
    default
  else:
    boolLiteral(v, key)

proc hasColumnIndex(f: FieldSpec): bool =
  ## Mirrors the single-column index `tableFor` emits for `index: true`.
  if f.primaryKey or flag(f, "unique", false):
    return false
  flag(f, "index", f.isForeignKey)

proc parseField(stmt: NimNode): FieldSpec =
  if stmt.kind != nnkCall or stmt.len != 2 or stmt[0].kind != nnkIdent or
      stmt[1].kind != nnkStmtList or stmt[1].len != 1:
    error(
      "fastorm: expected a field declaration such as `name: CharField(maxLength: 50)`",
      stmt,
    )
  result.name = $stmt[0]
  let ctorNode = stmt[1][0]
  var params: seq[NimNode]
  case ctorNode.kind
  of nnkIdent:
    result.ctor = $ctorNode
  of nnkCall, nnkObjConstr:
    if ctorNode[0].kind != nnkIdent:
      error("fastorm: expected a field constructor such as CharField(...)", ctorNode)
    result.ctor = $ctorNode[0]
    params = ctorNode[1 .. ^1]
  else:
    error("fastorm: expected a field constructor such as CharField(...)", ctorNode)
  if result.ctor notin fieldCtors:
    error(
      "fastorm: unknown field type `" & result.ctor & "`; expected one of " &
        fieldCtors.join(", "),
      ctorNode,
    )
  for i, p in params:
    if p.kind in {nnkExprColonExpr, nnkExprEqExpr}:
      let key = $p[0]
      if result.isManyToMany and key notin ["relatedName", "table"]:
        error(
          "fastorm: unknown ManyToManyField option `" & key &
            "`; expected relatedName or table",
          p,
        )
      case key
      of "validator":
        result.validator = p[1]
      of "default":
        result.default = p[1]
      of "column":
        if result.isManyToMany:
          error("fastorm: ManyToManyField uses `table`, not `column`", p)
        if p[1].kind notin {nnkStrLit, nnkTripleStrLit}:
          error("fastorm: `column` must be a string literal", p[1])
        result.column = p[1].strVal
      of "target", "targetTable", "targetColumn", "targetKind":
        error("fastorm: `" & key & "` is set automatically", p)
      of "relatedName":
        if result.ctor notin ["ForeignKey", "ManyToManyField"]:
          error(
            "fastorm: `relatedName` is only valid on a ForeignKey or ManyToManyField",
            p,
          )
        if p[1].kind notin {nnkStrLit, nnkTripleStrLit}:
          error("fastorm: `relatedName` must be a string literal", p[1])
        result.relatedName = p[1].strVal
        result.relatedExplicit = true
      of "table":
        if not result.isManyToMany:
          error("fastorm: `table` is only valid on a ManyToManyField", p)
        if p[1].kind notin {nnkStrLit, nnkTripleStrLit} or p[1].strVal.len == 0:
          error("fastorm: ManyToManyField table must be a non-empty string", p[1])
        result.throughTable = p[1].strVal
      of "choices":
        if result.ctor notin choiceFields:
          error("fastorm: choices are only valid on " & choiceFields.join(", "), p)
        if p[1].kind == nnkIdent:
          if result.ctor notin enumChoiceFields:
            error(
              "fastorm: enum choices belong on a CharField, EmailField, URLField or SlugField",
              p,
            )
          result.enumType = $p[1]
        elif p[1].kind == nnkBracket:
          if p[1].len == 0:
            error("fastorm: choices cannot be empty", p)
          for item in p[1]:
            let ok =
              if result.ctor in enumChoiceFields:
                item.kind in {nnkStrLit, nnkTripleStrLit}
              elif result.ctor == "IntegerField":
                item.kind == nnkIntLit or (
                  item.kind == nnkPrefix and item[0].eqIdent("-") and
                  item[1].kind == nnkIntLit
                )
              else:
                item.kind in {nnkIntLit, nnkFloatLit} or (
                  item.kind == nnkPrefix and item[0].eqIdent("-") and
                  item[1].kind in {nnkIntLit, nnkFloatLit}
                )
            if not ok:
              error("fastorm: each choice must be a literal of the field's type", item)
            result.choiceLits.add item
        else:
          error("fastorm: choices must be an enum name or a list of literals", p[1])
      else:
        if key == "primaryKey":
          result.primaryKey = boolLiteral(p[1], key)
        if key == "null":
          result.null = boolLiteral(p[1], key)
        result.args.add nnkExprEqExpr.newTree(ident(key), p[1])
    elif i == 0 and result.ctor in ["ForeignKey", "ManyToManyField"] and
        p.kind == nnkIdent:
      result.target = $p
    else:
      error("fastorm: field options must be named, e.g. `maxLength: 50`", p)
  if result.ctor in ["ForeignKey", "ManyToManyField"] and result.target.len == 0:
    error(
      "fastorm: " & result.ctor &
        " needs the referenced model first, e.g. " & result.ctor & "(User)",
      ctorNode,
    )
  if not result.isManyToMany and result.column.len == 0:
    result.column = toSnakeCase(result.name) & (if result.isForeignKey: "_id" else: "")

proc pkIndex(fields: seq[FieldSpec]): int =
  result = -1
  for i, f in fields:
    if f.primaryKey:
      return i

proc indexOf(fields: seq[FieldSpec], name: string): int =
  for i, f in fields:
    if f.name == name:
      return i
  -1

# -- code generation ---------------------------------------------------------
proc fieldDefExpr(f: FieldSpec): NimNode =
  var call = newCall(ident(f.ctor))
  if f.isForeignKey:
    call.add nnkExprEqExpr.newTree(ident"target", newLit(f.target))
    call.add nnkExprEqExpr.newTree(ident"targetTable", newLit(f.targetTable))
    call.add nnkExprEqExpr.newTree(ident"targetColumn", newLit(f.targetColumn))
    call.add nnkExprEqExpr.newTree(ident"targetKind", kindIdent(f.targetPkCtor))
    call.add nnkExprEqExpr.newTree(ident"relatedName", newLit(f.relatedName))
  for a in f.args:
    call.add a.copyNimTree
  result = newCall(bindSym"named", call, newLit(f.name), newLit(f.column))
  if not f.default.isNil:
    # A JSONField default is a string literal; that text is the stored JSON.
    result = newCall(
      bindSym"withDefault", result, newCall(ident"toDbValue", f.default.copyNimTree)
    )
  if f.choiceLits.len > 0:
    var vals = newNimNode(nnkBracket)
    for c in f.choiceLits:
      vals.add newCall(ident"toDbValue", c.copyNimTree)
    result = newCall(bindSym"withChoices", result, prefix(vals, "@"))

proc defaultValue*[T](t: typedesc[T], v: T): T =
  v

proc defaultValue*[T](t: typedesc[Option[T]], v: T): Option[T] =
  some(v)

proc typeSection(spec: ModelSpec, newAttrs: seq[FieldSpec]): NimNode =
  var recList = newNimNode(nnkRecList)
  for f in newAttrs:
    recList.add newIdentDefs(postfix(ident(attrName(f)), "*"), nimType(f))
  let base =
    if spec.parent.len > 0:
      ident(spec.parent)
    else:
      ident"FastormModel"
  let obj = nnkObjectTy.newTree(newEmptyNode(), nnkOfInherit.newTree(base), recList)
  nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      postfix(ident(spec.name), "*"), newEmptyNode(), nnkRefTy.newTree(obj)
    )
  )

proc isRelIdent(s: string): bool =
  if s.len == 0 or s[0] notin {'a' .. 'z', 'A' .. 'Z', '_'}:
    return false
  for c in s:
    if c notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
      return false
  true

proc reverseName(owner: string, f: FieldSpec, ownedHere: bool): string =
  ## Reverse accessor for a foreign key. `{model}` in an explicit name is
  ## replaced with the concrete model's snake_case name, which keeps abstract
  ## bases unique per child. An explicit empty name disables the reverse side.
  if f.relatedExplicit and f.relatedName.len == 0:
    return ""
  if f.relatedExplicit and (ownedHere or "{model}" in f.relatedName):
    return f.relatedName.replace("{model}", toSnakeCase(owner))
  if f.relatedExplicit and not ownedHere:
    return f.relatedName & "_" & toSnakeCase(owner)
  toSnakeCase(owner) & "s"

proc manyReverseName(owner: string, f: ManySpec): string =
  if f.relatedExplicit:
    return f.relatedName.replace("{model}", toSnakeCase(owner))
  toSnakeCase(owner) & "s"

proc resolvedMany(spec: ModelSpec, f: ManySpec): ManyToManyDef =
  let target =
    if f.target == spec.name:
      spec
    else:
      readModel(f.target)
  let ownerPk = spec.fields[pkIndex(spec.fields)]
  let targetPk = target.fields[pkIndex(target.fields)]
  result = ManyToManyDef(
    name: f.name,
    target: f.target,
    table:
      (if f.table.len > 0:
        f.table.replace("{model}", toSnakeCase(spec.name))
      else:
        spec.table & "_" & toSnakeCase(f.name)),
    ownerColumn: toSnakeCase(spec.name) & "_id",
    targetColumn: toSnakeCase(f.target) & "_id",
    ownerTable: spec.table,
    targetTable: target.table,
    ownerKeyColumn: ownerPk.column,
    targetKeyColumn: targetPk.column,
    ownerKind: fieldKind(ownerPk.ctor),
    targetKind: fieldKind(targetPk.ctor),
    relatedName: manyReverseName(spec.name, f),
  )
  if result.ownerColumn == result.targetColumn:
    result.ownerColumn = "from_" & result.ownerColumn
    result.targetColumn = "to_" & result.targetColumn

proc concreteProcs(
    spec: ModelSpec,
    reverses: seq[RelGen],
    manyReverses: seq[ManyGen],
    indexExprs, orderExprs: NimNode,
): NimNode =
  result = newStmtList()
  let T = ident(spec.name)
  let pkIdx = pkIndex(spec.fields)
  let pk = spec.fields[pkIdx]
  let pkAttr = ident(attrName(pk))
  let pkType = nimType(pk)
  let nameLit = newLit(spec.name)
  let tableLit = newLit(spec.table)
  let parentLit = newLit(spec.parent)
  let pkIdxLit = newLit(pkIdx)
  var fieldExprs = newNimNode(nnkBracket)
  for f in spec.fields:
    fieldExprs.add fieldDefExpr(f)
  var manyExprs = newNimNode(nnkBracket)
  for f in spec.manyToMany:
    let d = resolvedMany(spec, f)
    manyExprs.add nnkObjConstr.newTree(
      bindSym"ManyToManyDef",
      nnkExprColonExpr.newTree(ident"name", newLit(d.name)),
      nnkExprColonExpr.newTree(ident"target", newLit(d.target)),
      nnkExprColonExpr.newTree(ident"table", newLit(d.table)),
      nnkExprColonExpr.newTree(ident"ownerColumn", newLit(d.ownerColumn)),
      nnkExprColonExpr.newTree(ident"targetColumn", newLit(d.targetColumn)),
      nnkExprColonExpr.newTree(ident"ownerTable", newLit(d.ownerTable)),
      nnkExprColonExpr.newTree(ident"targetTable", newLit(d.targetTable)),
      nnkExprColonExpr.newTree(ident"ownerKeyColumn", newLit(d.ownerKeyColumn)),
      nnkExprColonExpr.newTree(ident"targetKeyColumn", newLit(d.targetKeyColumn)),
      nnkExprColonExpr.newTree(ident"ownerKind", ident($d.ownerKind)),
      nnkExprColonExpr.newTree(ident"targetKind", ident($d.targetKind)),
      nnkExprColonExpr.newTree(ident"relatedName", newLit(d.relatedName)),
    )

  let row = ident"row"
  let m = ident"m"
  let columns = ident"columns"
  let colSym = ident"col"
  let iSym = ident"i"
  var fromRowBody = newStmtList(newAssignment(ident"result", newCall(T)))
  var fromRowFull = newStmtList()
  var fromRowCases = nnkCaseStmt.newTree(colSym)
  var loadedNames = newNimNode(nnkBracket)
  var toRowItems = newNimNode(nnkBracket)
  var validateBody = newStmtList()
  var prepareBody = newStmtList()
  var newBody = newStmtList(newAssignment(ident"result", newCall(T)))
  let meta = ident"meta"
  let creating = ident"creating"
  let rowId = ident"rowId"
  for i, f in spec.fields:
    let a = ident(attrName(f))
    let idx = newLit(i)
    fromRowFull.add quote do:
      result.`a` = fromDbValue(`row`[`idx`], typeof(result.`a`))
    let colLit = newLit(f.column)
    let nameLit = newLit(f.name)
    fromRowCases.add nnkOfBranch.newTree(
      colLit,
      quote do:
        result.`a` = fromDbValue(`row`[`iSym`], typeof(result.`a`))
        markLoaded(result, [`nameLit`]),
    )
    loadedNames.add newLit(f.name)
    toRowItems.add quote do:
      toDbValue(`m`.`a`)
    validateBody.add quote do:
      checkField(result, `meta`.fields[`idx`], `m`.`a`)
    if not f.validator.isNil:
      let v = f.validator.copyNimTree
      let fname = newLit(f.name)
      validateBody.add quote do:
        runValidator(result, `fname`, `v`(`m`.`a`))
    if f.ctor in ["DateTimeField", "DateField", "TimeField"]:
      let stamp =
        if f.ctor == "DateField":
          bindSym"today"
        elif f.ctor == "TimeField":
          bindSym"clockNow"
        else:
          bindSym"storedNow"
      if f.argIsTrue("autoNow"):
        prepareBody.add quote do:
          `m`.`a` = defaultValue(typeof(`m`.`a`), `stamp`())
      elif f.argIsTrue("autoNowAdd"):
        prepareBody.add quote do:
          if `creating`:
            `m`.`a` = defaultValue(typeof(`m`.`a`), `stamp`())
    if not f.default.isNil:
      var d = f.default.copyNimTree
      if f.ctor == "JSONField":
        if f.default.kind notin {nnkStrLit, nnkTripleStrLit}:
          error("fastorm: JSONField default must be a JSON string literal", f.default)
        try:
          discard parseJson(f.default.strVal)
        except ValueError as e:
          error("fastorm: JSONField default is not valid JSON: " & e.msg, f.default)
        d = newCall(bindSym"parseJson", f.default.copyNimTree)
      newBody.add quote do:
        result.`a` = defaultValue(typeof(result.`a`), `d`)
  fromRowCases.add nnkElse.newTree(nnkDiscardStmt.newTree(newEmptyNode()))
  fromRowBody.add quote do:
    if `columns`.len == 0:
      `fromRowFull`
      markLoaded(result, `loadedNames`)
    else:
      for `iSym`, `colSym` in `columns`:
        `fromRowCases`

  var pkIsSet, setRowId: NimNode
  case pk.ctor
  of "UUIDField":
    pkIsSet = quote:
      not `m`.`pkAttr`.isZero
    setRowId = quote:
      discard
    prepareBody.insert 0,
      quote do:
        if `m`.`pkAttr`.isZero:
          `m`.`pkAttr` = genUUID()
  of "IntegerField":
    pkIsSet = quote:
      `m`.`pkAttr` != 0
    setRowId = quote:
      `m`.`pkAttr` = int(`rowId`)
  else:
    let pkName = newLit(pk.name)
    pkIsSet = quote:
      `m`.`pkAttr`.len > 0
    setRowId = quote:
      discard
    validateBody.add quote do:
      if `m`.`pkAttr`.len == 0:
        result.add FieldIssue(field: `pkName`, message: "primary key is required")
  prepareBody.add newNimNode(nnkDiscardStmt).add(newEmptyNode())

  let newProc = ident("new" & spec.name)
  let toRowProc = ident("fastormToRow_" & spec.name)
  let hydrateProc = ident("fastormHydrate_" & spec.name)
  let toRowSym = ident"toRow"
  let fromRowSym = ident"fromRow"
  result.add quote do:
    proc modelMeta*(t: typedesc[`T`]): ModelMeta =
      const metadata = ModelMeta(
        name: `nameLit`,
        table: `tableLit`,
        parent: `parentLit`,
        pkIndex: `pkIdxLit`,
        fields: @`fieldExprs`,
        indexes: @`indexExprs`,
        ordering: @`orderExprs`,
        manyToMany: @`manyExprs`,
      )
      metadata

    registerModel(modelMeta(`T`))

    proc pkValue*(`m`: `T`): `pkType` =
      `m`.`pkAttr`

    proc fromRow*(
        t: typedesc[`T`], `row`: seq[DbValue], `columns`: seq[string] = @[]
    ): `T` {.raises: [DatabaseError].} =
      `fromRowBody`

    proc toRow*(`m`: `T`): seq[DbValue] =
      @`toRowItems`

    proc `toRowProc`(model: FastormModel): seq[DbValue] {.gcsafe.} =
      `toRowSym`(`T`(model))

    proc `hydrateProc`(
        row: seq[DbValue]
    ): FastormModel {.gcsafe, raises: [DatabaseError].} =
      `fromRowSym`(`T`, row)

    registerModelFns(`nameLit`, `toRowProc`, `hydrateProc`)

    proc validate*(`m`: `T`): seq[FieldIssue] =
      ## Built-in field checks plus custom validators; empty means valid.
      const `meta` = modelMeta(`T`)
      `validateBody`

    proc fastormPkIsSet*(`m`: `T`): bool =
      `pkIsSet`

    proc fastormSetRowId*(`m`: `T`, `rowId`: int64) =
      `setRowId`

    proc fastormPrepare*(`m`: `T`, `creating`: bool) {.raises: [OSError].} =
      `prepareBody`

    proc `newProc`*(): `T` =
      ## A new unsaved instance with field defaults applied.
      `newBody`

    proc objects*(t: typedesc[`T`]): QuerySet[`T`] =
      initQuerySet[`T`]()

    template all*(t: typedesc[`T`]): untyped =
      all(objects(`T`))

    template filter*(t: typedesc[`T`], args: varargs[untyped]): untyped =
      filter(objects(`T`), args)

    template exclude*(t: typedesc[`T`], args: varargs[untyped]): untyped =
      exclude(objects(`T`), args)

    template get*(t: typedesc[`T`], args: varargs[untyped]): untyped =
      get(objects(`T`), args)

    template selectRelated*(t: typedesc[`T`], args: varargs[untyped]): untyped =
      selectRelated(objects(`T`), args)

    template prefetchRelated*(t: typedesc[`T`], args: varargs[untyped]): untyped =
      prefetchRelated(objects(`T`), args)

    template only*(t: typedesc[`T`], args: varargs[untyped]): untyped =
      only(objects(`T`), args)

    template expand*(t: typedesc[`T`], args: varargs[untyped]): untyped =
      expand(objects(`T`), args)

    proc save*(`m`: `T`, db: Database = nil): Future[void] =
      saveImpl(`m`, db)

    proc delete*(`m`: `T`, db: Database = nil): Future[void] =
      deleteImpl(`m`, db)

  for f in spec.fields:
    if not f.isForeignKey:
      continue
    let a = ident(attrName(f))
    let accessor = ident(f.name)
    let setter = nnkAccQuoted.newTree(ident(f.name & "="))
    let target = ident(f.target)
    let relLit = newLit(f.name)
    let targetLit = newLit(f.target)
    let colLit = newLit(f.column)
    result.add quote do:
      registerPrefetch(
        PrefetchDef(
          owner: `nameLit`,
          name: `relLit`,
          target: `targetLit`,
          kind: pfForward,
          keyColumn: `colLit`,
        )
      )

      proc `accessor`*(
          `m`: `T`, db: Database = nil
      ): Future[Option[`target`]] {.async.} =
        ## Loads the related model; `none` if the key is null or dangling.
        ## Uses the object cached by `selectRelated` or `prefetchRelated`.
        let cached = cachedSingle[`target`](`m`, `relLit`)
        if cached.hit:
          return cached.value
        let loaded = await getByPk(`target`, toDbValue(`m`.`a`), db)
        if loaded.isSome:
          rememberSingle(`m`, `relLit`, loaded.get)
        else:
          rememberMissing(`m`, `relLit`)
        return loaded

      proc `setter`*(`m`: `T`, value: `target`) =
        `m`.`a` = defaultValue(typeof(`m`.`a`), pkValue(value))

  for rev in reverses:
    let parent = ident(rev.target)
    let acc = ident(rev.name)
    let relLit = newLit(rev.name)
    let targetLit = newLit(rev.target)
    let colLit = newLit(rev.column)
    result.add quote do:
      registerPrefetch(
        PrefetchDef(
          owner: `targetLit`,
          name: `relLit`,
          target: `nameLit`,
          kind: pfReverse,
          keyColumn: `colLit`,
        )
      )

      proc `acc`*(`m`: `parent`, db: Database = nil): Future[seq[`T`]] {.async.} =
        ## Reverse of a foreign key. One query, or the rows cached by
        ## `prefetchRelated`.
        let cached = cachedMany[`T`](`m`, `relLit`)
        if cached.hit:
          return cached.value
        var qs = initQuerySet[`T`]()
        qs.db = db
        qs.wheres.add eqPredicate(`colLit`, toDbValue(pkValue(`m`)))
        let rows = await qs.all()
        rememberMany(`m`, `relLit`, rows)
        return rows

  for f in spec.manyToMany:
    let d = resolvedMany(spec, f)
    let accessor = ident(f.name)
    let target = ident(f.target)
    let tableLit = newLit(d.table)
    let ownerColLit = newLit(d.ownerColumn)
    let targetColLit = newLit(d.targetColumn)
    result.add quote do:
      proc `accessor`*(
          `m`: `T`, db: Database = nil
      ): ManyToManyManager[`T`, `target`] =
        ## Returns the async manager for this many-to-many relation.
        initManyToManyManager[`T`, `target`](
          `m`, db, `tableLit`, `ownerColLit`, `targetColLit`
        )

  for rev in manyReverses:
    let parent = ident(rev.target)
    let accessor = ident(rev.name)
    let tableLit = newLit(rev.table)
    let ownerColLit = newLit(rev.ownerColumn)
    let targetColLit = newLit(rev.targetColumn)
    result.add quote do:
      proc `accessor`*(
          `m`: `parent`, db: Database = nil
      ): ManyToManyManager[`parent`, `T`] =
        ## Returns the async manager for the reverse many-to-many relation.
        initManyToManyManager[`parent`, `T`](
          `m`, db, `tableLit`, `ownerColLit`, `targetColLit`
        )

proc isFieldConstructor(n: NimNode): bool =
  var name = ""
  if n.kind == nnkIdent:
    name = $n
  elif n.kind in {nnkCall, nnkObjConstr, nnkCommand} and n.len > 0 and
      n[0].kind == nnkIdent:
    name = $n[0]
  name in fieldCtors

proc isMetaStmt(stmt: NimNode): bool =
  ## `Meta:` holds model options. `meta: CharField()` stays an ordinary field.
  if stmt.kind notin {nnkCall, nnkCommand} or stmt.len != 2 or stmt[0].kind != nnkIdent:
    return false
  if not (stmt[0].eqIdent("Meta") or stmt[0].eqIdent("meta")):
    return false
  if stmt[1].kind == nnkStmtList:
    return not (stmt[1].len == 1 and isFieldConstructor(stmt[1][0]))
  not isFieldConstructor(stmt[1])

proc metaBody(stmt: NimNode): NimNode =
  if stmt[1].kind == nnkStmtList:
    stmt[1]
  else:
    newStmtList(stmt[1])

proc optionOf(stmt: NimNode): tuple[key: string, body: NimNode] =
  if stmt.kind in {nnkCall, nnkCommand} and stmt.len == 2 and stmt[0].kind == nnkIdent:
    let body =
      if stmt[1].kind == nnkStmtList:
        stmt[1]
      else:
        newStmtList(stmt[1])
    return ($stmt[0], body)
  error("fastorm: expected `option: value` inside Meta", stmt)

proc keptNodes(body: NimNode): seq[NimNode] =
  for n in body:
    if n.kind notin {nnkEmpty, nnkCommentStmt}:
      result.add n

proc fieldToken(n: NimNode): string =
  case n.kind
  of nnkStrLit, nnkTripleStrLit:
    if n.strVal.len == 0:
      error("fastorm: expected a field name", n)
    n.strVal
  of nnkIdent:
    $n
  of nnkAccQuoted:
    if n.len == 1 and n[0].kind == nnkIdent:
      $n[0]
    else:
      error("fastorm: expected a field name", n)
  of nnkPrefix:
    if n[0].eqIdent("-"):
      let inner = fieldToken(n[1])
      if inner.len == 0 or inner[0] == '-':
        error("fastorm: expected a field name", n)
      "-" & inner
    else:
      error("fastorm: expected a field name", n)
  else:
    error("fastorm: expected a field name", n)

proc fieldList(n: NimNode): seq[string] =
  if n.kind != nnkBracket or n.len == 0:
    error("fastorm: expected a list of field names", n)
  for c in n:
    result.add fieldToken(c)

proc parseOrdering(body: NimNode): seq[string] =
  let nodes = keptNodes(body)
  if nodes.len == 0 or
      (nodes.len == 1 and nodes[0].kind == nnkBracket and nodes[0].len == 0):
    return
  if nodes.len == 1 and nodes[0].kind == nnkBracket:
    for c in nodes[0]:
      result.add fieldToken(c)
  else:
    error(
      "fastorm: ordering expects a list of field names, e.g. [\"name\", \"-createdAt\"]",
      body,
    )

proc indexCalls(body: NimNode): seq[NimNode] =
  let nodes = keptNodes(body)
  if nodes.len == 1 and nodes[0].kind == nnkBracket:
    for n in nodes[0]:
      result.add n
  else:
    result = nodes
  if result.len == 0:
    error("fastorm: indexes needs at least one Index(...)", body)

proc parseIndexCall(n: NimNode): MetaIndexSpec =
  if n.kind notin {nnkCall, nnkObjConstr, nnkCommand} or n.len < 2 or
      n[0].kind != nnkIdent or not n[0].eqIdent("Index"):
    error("fastorm: expected Index(fields: [...])", n)
  var fields: seq[string]
  var name = ""
  var unique = false
  var sawFields = false
  for i in 1 ..< n.len:
    let p = n[i]
    if p.kind in {nnkExprColonExpr, nnkExprEqExpr}:
      let key = $p[0]
      case key
      of "fields":
        if sawFields or fields.len > 0:
          error("fastorm: Index fields are listed twice", p)
        fields = fieldList(p[1])
        sawFields = true
      of "name":
        if p[1].kind notin {nnkStrLit, nnkTripleStrLit} or p[1].strVal.len == 0:
          error("fastorm: Index name must be a non-empty string", p[1])
        if name.len > 0:
          error("fastorm: Index name is listed twice", p)
        name = p[1].strVal
      of "unique":
        unique = boolLiteral(p[1], "unique")
      else:
        error(
          "fastorm: unknown Index option `" & key & "`; expected fields, name, or unique",
          p,
        )
    else:
      if sawFields:
        error("fastorm: pass either fields: [...] or positional field names", p)
      fields.add fieldToken(p)
  if fields.len == 0:
    error("fastorm: Index needs at least one field", n)
  MetaIndexSpec(name: name, explicit: name.len > 0, unique: unique, fields: fields)

proc uniqueGroups(body: NimNode): seq[seq[string]] =
  let nodes = keptNodes(body)
  if nodes.len == 0:
    error("fastorm: uniqueTogether needs at least one group of fields", body)
  if nodes.len == 1 and nodes[0].kind == nnkBracket and nodes[0].len > 0 and
      nodes[0][0].kind == nnkBracket:
    for g in nodes[0]:
      result.add fieldList(g)
  else:
    for n in nodes:
      result.add fieldList(n)

proc parseMeta(spec: var ModelSpec, body: NimNode, pragmaTable: string) =
  var seen: seq[string]
  for stmt in body:
    if stmt.kind in {nnkEmpty, nnkCommentStmt}:
      continue
    var (key, inner) = optionOf(stmt)
    if key in ["table", "dbTable"]:
      key = "table"
    if key in seen:
      error("fastorm: Meta option `" & key & "` is declared twice", stmt)
    seen.add key
    case key
    of "table":
      if spec.abstract:
        error("fastorm: abstract model " & spec.name & " cannot set Meta.table", stmt)
      if inner.len != 1 or inner[0].kind notin {nnkStrLit, nnkTripleStrLit} or
          inner[0].strVal.len == 0:
        error("fastorm: Meta.table expects a non-empty string", stmt)
      let table = inner[0].strVal
      if pragmaTable.len > 0 and pragmaTable != table:
        error(
          "fastorm: Meta.table `" & table & "` conflicts with {.table: \"" & pragmaTable &
            "\".}",
          stmt,
        )
      spec.table = table
    of "ordering":
      spec.ordering = parseOrdering(inner)
    of "indexes":
      for call in indexCalls(inner):
        spec.indexes.add parseIndexCall(call)
    of "uniqueTogether":
      for group in uniqueGroups(inner):
        if group.len < 2:
          error("fastorm: uniqueTogether needs at least two fields", stmt)
        spec.indexes.add MetaIndexSpec(unique: true, fields: group)
    else:
      error(
        "fastorm: unknown Meta option `" & key &
          "`; expected table, ordering, indexes, or uniqueTogether",
        stmt,
      )

proc splitOrder(raw: string, n: NimNode): tuple[desc: bool, name: string] =
  if raw.len > 0 and raw[0] == '-':
    if raw.len == 1:
      error("fastorm: expected a field name", n)
    (true, raw[1 .. ^1])
  else:
    (false, raw)

proc metaField(
    spec: ModelSpec, raw: string, n: NimNode
): tuple[desc: bool, field: FieldSpec] =
  let (desc, name) = splitOrder(raw, n)
  let i = spec.fields.indexOf(name)
  if i < 0:
    error("fastorm: " & spec.name & " has no field `" & name & "`", n)
  (desc, spec.fields[i])

proc sameIndex(a, b: MetaIndex): bool =
  a.unique == b.unique and a.columns == b.columns and a.descending == b.descending

proc claimIndex(owner, indexName: string, n: NimNode) =
  if indexName in indexCache:
    let previous = indexCache[indexName].strVal
    if previous != owner:
      error("fastorm: index name `" & indexName & "` is already used by " & previous, n)
  else:
    indexCache[indexName] = newLit(owner)

proc indexIdent(spec: ModelSpec, raw: MetaIndexSpec, columns: seq[string]): string =
  if raw.explicit:
    result = raw.name.replace("{model}", toSnakeCase(spec.name))
  else:
    result =
      spec.table & "_" & columns.join("_") & (if raw.unique: "_uniq" else: "_idx")
  if result.len == 0:
    error("fastorm: index name cannot be empty")

proc resolveMeta(
    spec: ModelSpec, n: NimNode
): tuple[indexes: seq[MetaIndex], ordering: seq[string]] =
  var covered: seq[MetaIndex]
  if not spec.abstract:
    for f in spec.fields:
      if not hasColumnIndex(f):
        continue
      let ix =
        MetaIndex(name: spec.table & "_" & f.column & "_idx", columns: @[f.column])
      covered.add ix
      claimIndex(spec.name, ix.name, n)
  for raw in spec.indexes:
    var columns: seq[string]
    var descending: seq[bool]
    for item in raw.fields:
      let found = metaField(spec, item, n)
      if found.field.column in columns:
        error("fastorm: index lists `" & found.field.name & "` more than once", n)
      columns.add found.field.column
      descending.add found.desc
    if not descending.anyIt(it):
      descending.setLen(0)
    let ix = MetaIndex(
      name: indexIdent(spec, raw, columns),
      columns: columns,
      descending: descending,
      unique: raw.unique,
    )
    var coveredBy: string
    for previous in covered:
      if sameIndex(previous, ix):
        if raw.explicit and previous.name != ix.name:
          error(
            "fastorm: index `" & ix.name & "` indexes the same columns as `" &
              previous.name & "`",
            n,
          )
        coveredBy = previous.name
        break
      elif previous.name == ix.name:
        error("fastorm: index name `" & ix.name & "` is declared twice", n)
    if coveredBy.len > 0:
      continue
    if not spec.abstract:
      claimIndex(spec.name, ix.name, n)
    covered.add ix
    result.indexes.add ix
  for item in spec.ordering:
    let found = metaField(spec, item, n)
    result.ordering.add (if found.desc: "-" else: "") & found.field.column

proc indexNode(ix: MetaIndex): NimNode =
  var cols = newNimNode(nnkBracket)
  for c in ix.columns:
    cols.add newLit(c)
  var descending = newNimNode(nnkBracket)
  for d in ix.descending:
    descending.add newLit(d)
  let nameLit = newLit(ix.name)
  let uniqueLit = newLit(ix.unique)
  quote:
    MetaIndex(
      name: `nameLit`, columns: @`cols`, descending: @`descending`, unique: `uniqueLit`
    )

macro model*(args: varargs[untyped]): untyped =
  ## Declares a model. See the README for the full DSL.
  ##
  ## ```nim
  ## model BaseModel {.abstract.}:
  ##   id: UUIDField(primaryKey: true)
  ##
  ## model User = ref BaseModel:
  ##   name: CharField(maxLength: 19)
  ## ```
  # `varargs` because `model User = ref Base:` reaches the macro as a named
  # argument, which a fixed parameter list would reject.
  if args.len != 2 or args[1].kind != nnkStmtList:
    error("fastorm: expected `model Name:` followed by an indented field list", args)
  let head = args[0]
  let body = args[1]
  var spec: ModelSpec
  var h = head
  if h.kind == nnkExprEqExpr:
    let rhs = h[1]
    if rhs.kind != nnkRefTy or rhs[0].kind != nnkIdent:
      error("fastorm: expected `model Name = ref BaseModel:`", rhs)
    spec.parent = $rhs[0]
    h = h[0]
  if h.kind == nnkPragmaExpr:
    for p in h[1]:
      if p.kind == nnkIdent and p.eqIdent("abstract"):
        spec.abstract = true
      elif p.kind == nnkExprColonExpr and p[0].eqIdent("table") and
          p[1].kind == nnkStrLit:
        spec.table = p[1].strVal
      else:
        error(
          "fastorm: unknown model pragma; supported: {.abstract.}, {.table: \"name\".}",
          p,
        )
    h = h[0]
  if h.kind == nnkPostfix:
    h = h[1]
  if h.kind != nnkIdent:
    error("fastorm: expected a model name", h)
  spec.name = $h
  if spec.name in modelCache:
    error("fastorm: model " & spec.name & " is already defined", h)
  let pragmaTable = spec.table
  if spec.table.len == 0:
    spec.table = toSnakeCase(spec.name)

  var inheritedCount = 0
  var inheritedTypes: seq[(string, string)]
  if spec.parent.len > 0:
    if spec.parent notin modelCache:
      error(
        "fastorm: unknown base model `" & spec.parent &
          "`; it must be declared with `model` before " & spec.name,
        head,
      )
    let parent = readModel(spec.parent)
    spec.fields = parent.fields
    spec.indexes = parent.indexes
    spec.ordering = parent.ordering
    spec.manyToMany = parent.manyToMany
    inheritedCount = spec.fields.len

  var declared: seq[string]
  var seenMeta = false
  var metaNode = head
  for stmt in body:
    if stmt.kind in {nnkCommentStmt, nnkEmpty}:
      continue
    if isMetaStmt(stmt):
      if seenMeta:
        error("fastorm: Meta is declared twice", stmt)
      seenMeta = true
      metaNode = stmt
      parseMeta(spec, metaBody(stmt), pragmaTable)
      continue
    let f = parseField(stmt)
    if f.name in declared:
      error("fastorm: field `" & f.name & "` is declared twice", stmt)
    declared.add f.name
    if f.isManyToMany:
      if spec.fields.indexOf(f.name) >= 0 or
          spec.manyToMany.anyIt(it.name == f.name):
        error("fastorm: field `" & f.name & "` is already inherited", stmt)
      spec.manyToMany.add ManySpec(
        name: f.name,
        target: f.target,
        relatedName: f.relatedName,
        relatedExplicit: f.relatedExplicit,
        table: f.throughTable,
      )
      continue
    if spec.manyToMany.anyIt(it.name == f.name):
      error("fastorm: field `" & f.name & "` clashes with a many-to-many relation", stmt)
    let existing = spec.fields.indexOf(f.name)
    if existing >= 0:
      inheritedTypes.add (f.name, nimType(spec.fields[existing]).repr)
      spec.fields[existing] = f
    else:
      spec.fields.add f

  var pks = 0
  for f in spec.fields:
    if f.primaryKey:
      inc pks
      if f.isForeignKey:
        error(
          "fastorm: a ForeignKey cannot be the primary key (" & spec.name & "." & f.name &
            ")",
          head,
        )
  if pks > 1:
    error("fastorm: model " & spec.name & " declares more than one primary key", head)
  var autoId = false
  if pks == 0 and not spec.abstract:
    if spec.fields.indexOf("id") >= 0:
      error(
        "fastorm: `" & spec.name &
          ".id` is not a primary key; mark a field primaryKey: true",
        head,
      )
    spec.fields.insert(
      FieldSpec(
        name: "id",
        ctor: "IntegerField",
        column: "id",
        primaryKey: true,
        args: @[nnkExprEqExpr.newTree(ident"primaryKey", ident"true")],
      ),
      0,
    )
    autoId = true

  for f in spec.fields.mitems:
    if not f.isForeignKey or f.targetTable.len > 0:
      continue
    var target: ModelSpec
    if f.target == spec.name:
      if spec.abstract:
        error("fastorm: abstract model " & spec.name & " cannot reference itself", head)
      target = spec
    elif f.target in modelCache:
      target = readModel(f.target)
    else:
      error(
        "fastorm: ForeignKey target `" & f.target &
          "` must be declared with `model` before " & spec.name,
        head,
      )
    if target.abstract:
      error("fastorm: ForeignKey cannot target abstract model " & f.target, head)
    let tpk = target.fields[pkIndex(target.fields)]
    f.targetTable = target.table
    f.targetColumn = tpk.column
    f.targetPkCtor = tpk.ctor

  for f in spec.manyToMany:
    var target: ModelSpec
    if f.target == spec.name:
      if spec.abstract:
        error("fastorm: abstract model " & spec.name & " cannot reference itself", head)
      target = spec
    elif f.target in modelCache:
      target = readModel(f.target)
    else:
      error(
        "fastorm: ManyToManyField target `" & f.target &
          "` must be declared with `model` before " & spec.name,
        head,
      )
    if target.abstract:
      error("fastorm: ManyToManyField cannot target abstract model " & f.target, head)

  for (name, oldType) in inheritedTypes:
    let newType = nimType(spec.fields[spec.fields.indexOf(name)]).repr
    if newType != oldType:
      error(
        "fastorm: " & spec.name & " overrides inherited field `" & name & "` with type " &
          newType & " but " & spec.parent & " declares it as " & oldType,
        head,
      )

  var newAttrs: seq[FieldSpec]
  for i, f in spec.fields:
    let isInherited =
      (if autoId: i - 1 else: i) < inheritedCount and not (autoId and i == 0)
    if not isInherited:
      newAttrs.add f

  let resolved = resolveMeta(spec, metaNode)
  modelCache[spec.name] = encode(spec)
  var reverses: seq[RelGen]
  var manyReverses: seq[ManyGen]
  if not spec.abstract:
    for f in spec.fields:
      if not f.isForeignKey:
        continue
      let ownedHere = f.name in declared
      let fwd = spec.name & "." & f.name
      if fwd in forwardCache:
        error(
          "fastorm: " & spec.name & " already has a relation `" & f.name & "`", head
        )
      forwardCache[fwd] = newLit(f.target)
      let rn = reverseName(spec.name, f, ownedHere)
      if rn.len == 0:
        continue
      if not isRelIdent(rn):
        error("fastorm: relatedName `" & rn & "` is not a valid identifier", head)
      let rev = f.target & "." & rn
      if rev in forwardCache or rev in reverseCache:
        error(
          "fastorm: reverse name `" & rn & "` of " & spec.name & "." & f.name &
            " clashes with relation " & rev & "; set a different relatedName",
          head,
        )
      let targetSpec =
        if f.target == spec.name:
          spec
        else:
          readModel(f.target)
      if targetSpec.fields.indexOf(rn) >= 0:
        error(
          "fastorm: reverse name `" & rn & "` clashes with field " & f.target & "." & rn &
            "; set a different relatedName",
          head,
        )
      reverseCache[rev] = newLit(spec.name)
      reverses.add RelGen(target: f.target, name: rn, column: f.column)
    for f in spec.manyToMany:
      let d = resolvedMany(spec, f)
      let fwd = spec.name & "." & f.name
      if fwd in forwardCache or fwd in reverseCache or fwd in manyCache:
        error("fastorm: " & spec.name & " already has a relation `" & f.name & "`", head)
      if spec.fields.indexOf(f.name) >= 0:
        error(
          "fastorm: many-to-many name `" & f.name & "` clashes with field " & fwd,
          head,
        )
      manyCache[fwd] = newLit(f.target)
      let rn = d.relatedName
      if rn.len == 0:
        continue
      if not isRelIdent(rn):
        error("fastorm: relatedName `" & rn & "` is not a valid identifier", head)
      let rev = f.target & "." & rn
      if rev in forwardCache or rev in reverseCache or rev in manyCache:
        error(
          "fastorm: reverse name `" & rn & "` of " & fwd &
            " clashes with relation " & rev & "; set a different relatedName",
          head,
        )
      let targetSpec =
        if f.target == spec.name:
          spec
        else:
          readModel(f.target)
      if targetSpec.fields.indexOf(rn) >= 0 or
          targetSpec.manyToMany.anyIt(it.name == rn):
        error(
          "fastorm: reverse name `" & rn & "` clashes with field " & f.target & "." & rn &
            "; set a different relatedName",
          head,
        )
      manyCache[rev] = newLit(spec.name)
      manyReverses.add ManyGen(
        target: f.target,
        name: rn,
        table: d.table,
        ownerColumn: d.targetColumn,
        targetColumn: d.ownerColumn,
      )
  result = newStmtList(typeSection(spec, newAttrs))
  if not spec.abstract:
    var indexExprs = newNimNode(nnkBracket)
    for ix in resolved.indexes:
      indexExprs.add indexNode(ix)
    var orderExprs = newNimNode(nnkBracket)
    for column in resolved.ordering:
      orderExprs.add newLit(column)
    result.add concreteProcs(spec, reverses, manyReverses, indexExprs, orderExprs)

# -- query macros ------------------------------------------------------------

proc querySetModel(qs: NimNode): (NimNode, ModelSpec) =
  let t = qs.getTypeInst
  if t.kind != nnkBracketExpr or t.len != 2:
    error("fastorm: expected a QuerySet", qs)
  let name = t[1].strVal
  if name notin modelCache:
    error("fastorm: " & name & " is not a fastorm model", qs)
  (t[1], readModel(name))

proc findSpec(spec: ModelSpec, field: NimNode): FieldSpec =
  if field.kind != nnkIdent:
    error("fastorm: expected a field name", field)
  let i = spec.fields.indexOf($field)
  if i < 0:
    error(
      "fastorm: " & spec.name & " has no field `" & $field & "` (fields: " &
        spec.fields.mapIt(it.name).join(", ") & ")",
      field,
    )
  spec.fields[i]

proc flattenDots(n: NimNode): seq[NimNode] =
  ## `author.publisher.name` (parsed as nested DotExpr) -> [author, publisher, name].
  if n.kind == nnkDotExpr:
    result = flattenDots(n[0])
    result.add n[1]
  else:
    result = @[n]

proc resolveFieldPath(
    spec: ModelSpec, parts: seq[NimNode], allowLookup = true
): tuple[path: string, targetSpec: ModelSpec, fieldIdx: int, lookup: NimNode] =
  ## Walks `parts` as zero or more foreign-key hops followed by a field name
  ## and, if `allowLookup`, an optional trailing lookup name.
  var cur = spec
  var path = ""
  var i = 0
  while i < parts.len - 1:
    if parts[i].kind != nnkIdent:
      error("fastorm: expected a field or relation name", parts[i])
    let fi = cur.fields.indexOf($parts[i])
    if fi < 0 or not cur.fields[fi].isForeignKey:
      break
    cur = readModel(cur.fields[fi].target)
    path =
      if path.len == 0:
        $parts[i]
      else:
        path & "." & $parts[i]
    inc i
  let remaining = parts.len - i
  let maxRemaining = if allowLookup: 2 else: 1
  if remaining > maxRemaining:
    var msg = cur.name & " has no foreign key `" & $parts[i] & "` to filter through"
    if not allowLookup and remaining == 2:
      msg = "comparison operators do not take a `.lookup` suffix; " & msg
    error("fastorm: " & msg, parts[i])
  if parts[i].kind != nnkIdent:
    error("fastorm: expected a field name", parts[i])
  let fieldName = $parts[i]
  let fi = cur.fields.indexOf(fieldName)
  if fi < 0:
    error(
      "fastorm: " & cur.name & " has no field `" & fieldName & "` (fields: " &
        cur.fields.mapIt(it.name).join(", ") & ")",
      parts[i],
    )
  let lookup =
    if remaining == 2:
      parts[i + 1]
    else:
      nil
  (path, cur, fi, lookup)

proc buildPredicate(
    path: string, targetSpec: ModelSpec, fieldIdx: int, lookupNode, value: NimNode
): NimNode =
  let f = targetSpec.fields[fieldIdx]
  let a = ident(attrName(f))
  let targetT = ident(targetSpec.name)
  let pathLit = newLit(path)
  let col = newLit(f.column)
  let fieldType = quote:
    typeof(`targetT`().`a`)
  let coerced = quote:
    coerce(`fieldType`, `value`)
  let lookup =
    if lookupNode.isNil:
      "exact"
    else:
      $lookupNode
  for tl in textLookups:
    if lookupNode != nil and lookupNode.eqIdent(tl):
      if f.ctor notin ["CharField", "TextField"]:
        error(
          "fastorm: lookup `" & tl & "` needs a CharField or TextField, but " &
            targetSpec.name & "." & f.name & " is a " & f.ctor,
          lookupNode,
        )
      let tlLit = newLit(tl)
      return quote:
        textPredicate(`col`, `tlLit`, `coerced`, `pathLit`)
  template isLookup(name: string): bool =
    lookupNode.isNil and name == "exact" or
      not lookupNode.isNil and lookupNode.eqIdent(name)

  if isLookup("exact"):
    return quote:
      eqPredicate(`col`, `coerced`, path = `pathLit`)
  if isLookup("ne"):
    return quote:
      eqPredicate(`col`, `coerced`, negate = true, path = `pathLit`)
  for (name, op) in [("gt", ">"), ("gte", ">="), ("lt", "<"), ("lte", "<=")]:
    if isLookup(name):
      let opLit = newLit(op)
      return quote:
        cmpPredicate(`col`, `opLit`, `coerced`, `pathLit`)
  if isLookup("isIn"):
    return quote:
      inPredicate(`col`, coerceSeq(`fieldType`, `value`), path = `pathLit`)
  if isLookup("notIn"):
    return quote:
      inPredicate(
        `col`, coerceSeq(`fieldType`, `value`), negate = true, path = `pathLit`
      )
  if isLookup("isNull"):
    return quote:
      nullPredicate(`col`, bool(`value`), `pathLit`)
  error(
    "fastorm: unknown lookup `" & lookup & "`; supported: exact, ne, gt, gte, lt, lte, " &
      "isIn, notIn, isNull, " & textLookups.join(", "),
    lookupNode,
  )

proc andPredicates*(ps: openArray[Predicate]): Predicate =
  if ps.len == 0:
    return Predicate(sql: "1")
  var parts: seq[string]
  for p in ps:
    parts.add "(" & p.sql & ")"
    result.params.add p.params
  result.sql = parts.join(" AND ")

proc unwrapPar(n: NimNode): NimNode =
  result = n
  while result.kind in {nnkPar, nnkStmtList} and result.len == 1:
    result = result[0]

proc combineConds(op: string, parts: seq[NimNode]): NimNode =
  var bracket = newNimNode(nnkBracket)
  for p in parts:
    bracket.add p
  let fn =
    if op == "or":
      bindSym"orPredicate"
    else:
      bindSym"andPredicates"
  newCall(fn, bracket)

proc notePath(path: string, paths: var seq[string]) =
  if path.len > 0 and path notin paths:
    paths.add path

proc simpleCond(spec: ModelSpec, arg: NimNode, paths: var seq[string]): NimNode =
  case arg.kind
  of nnkExprEqExpr:
    let (path, targetSpec, fieldIdx, lookup) =
      resolveFieldPath(spec, flattenDots(arg[0]))
    notePath(path, paths)
    return buildPredicate(path, targetSpec, fieldIdx, lookup, arg[1])
  of nnkInfix:
    let ops = {
      "==": "exact",
      "!=": "ne",
      "<": "lt",
      "<=": "lte",
      ">": "gt",
      ">=": "gte",
      "in": "isIn",
      "notin": "notIn",
    }
    for (op, lookupName) in ops:
      if arg[0].eqIdent(op):
        let (path, targetSpec, fieldIdx, suffix) =
          resolveFieldPath(spec, flattenDots(arg[1]), allowLookup = op == "==")
        # `field.lookup == value` keeps the explicit lookup; every other
        # operator (and `==` without a suffix) uses the operator's lookup.
        let lookup =
          if op == "==" and suffix != nil:
            suffix
          else:
            ident(lookupName)
        notePath(path, paths)
        return buildPredicate(path, targetSpec, fieldIdx, lookup, arg[2])
    error("fastorm: unsupported operator `" & $arg[0] & "` in filter", arg)
  else:
    error(
      "fastorm: unsupported filter; use `field = value`, `field.lookup = value`, " &
        "`field <op> value`, `a or b`, or `any(...)`",
      arg,
    )

proc parseCond(spec: ModelSpec, arg: NimNode, paths: var seq[string]): NimNode =
  let arg = unwrapPar(arg)
  if arg.kind == nnkInfix and (arg[0].eqIdent("or") or arg[0].eqIdent("and")):
    let op = if arg[0].eqIdent("or"): "or" else: "and"
    return combineConds(
      op, @[parseCond(spec, arg[1], paths), parseCond(spec, arg[2], paths)]
    )
  if arg.kind == nnkCall and arg[0].kind == nnkIdent and
      (arg[0].eqIdent("any") or arg[0].eqIdent("all")):
    if arg.len < 2:
      error("fastorm: `" & $arg[0] & "` needs at least one condition", arg)
    var parts: seq[NimNode]
    for i in 1 ..< arg.len:
      parts.add parseCond(spec, arg[i], paths)
    let op = if arg[0].eqIdent("any"): "or" else: "and"
    return combineConds(op, parts)
  simpleCond(spec, arg, paths)

proc withRelPaths(qs: NimNode, paths: seq[string]): NimNode =
  result = qs
  for p in paths:
    result = newCall(bindSym"addRelPath", result, newLit(p))

macro filter*(qs: QuerySet, args: varargs[untyped]): untyped =
  ## Narrows `qs`; every argument must hold. Arguments can be
  ## `field = value`, `field.lookup = value`, `field <op> value`,
  ## `a == x or b == y`, `any(...)` / `all(...)`, and can reach through a
  ## foreign key (`author.name = "Ada"`, `author.publisher.name = "Orbit"`).
  let (_, spec) = querySetModel(qs)
  result = qs
  var paths: seq[string]
  for a in args:
    result = newCall(bindSym"addPredicate", result, parseCond(spec, a, paths))
  result = withRelPaths(result, paths)

macro exclude*(qs: QuerySet, args: varargs[untyped]): untyped =
  ## Removes rows for which all the given conditions hold.
  let (_, spec) = querySetModel(qs)
  var ps = newNimNode(nnkBracket)
  var paths: seq[string]
  for a in args:
    ps.add parseCond(spec, a, paths)
  let combined = newCall(bindSym"notPredicate", newCall(bindSym"andPredicates", ps))
  withRelPaths(newCall(bindSym"addPredicate", qs, combined), paths)

macro get*(qs: QuerySet, args: varargs[untyped]): untyped =
  ## `Future[Option[T]]`: `some` for exactly one match, `none` for no match;
  ## raises `MultipleObjectsReturned` for several matches.
  let (_, spec) = querySetModel(qs)
  var filtered = qs
  var paths: seq[string]
  for a in args:
    filtered = newCall(bindSym"addPredicate", filtered, parseCond(spec, a, paths))
  filtered = withRelPaths(filtered, paths)
  newCall(bindSym"getImpl", filtered)

macro F*(field: untyped): untyped =
  ## Column reference for `update`. Only valid inside an `update` argument
  ## such as `views = F(views) + 1`; the `update` macro reads this call
  ## from the AST and never evaluates it.
  error("fastorm: F() is only valid inside update(...)", field)

proc containsF(n: NimNode): bool =
  if n.kind == nnkCall and n.len >= 1 and n[0].eqIdent("F"):
    return true
  for c in n:
    if containsF(c):
      return true
  false

proc isNumericCtor(ctor: string): bool =
  ctor in ["IntegerField", "FloatField"]

type FBuild = object
  sql: string
  params: seq[NimNode]
  fCount: int
  hasDiv: bool
  sourceCtor: string

proc parseFNode(spec: ModelSpec, dest: FieldSpec, n: NimNode, acc: var FBuild) =
  let n = unwrapPar(n)
  if n.kind == nnkCall and n.len >= 1 and n[0].eqIdent("F"):
    if n.len != 2:
      error("fastorm: F() takes one field name", n)
    if n[1].kind == nnkDotExpr:
      error(
        "fastorm: F() cannot reach through a relation; use a field of " & spec.name, n
      )
    let src = findSpec(spec, n[1])
    if not isNumericCtor(src.ctor):
      error(
        "fastorm: F(" & src.name & ") needs an IntegerField or FloatField, but " &
          spec.name & "." & src.name & " is a " & src.ctor,
        n,
      )
    inc acc.fCount
    if acc.fCount > 1:
      error("fastorm: an update expression can mention only one F() field", n)
    acc.sourceCtor = src.ctor
    acc.sql.add quoteIdent(src.column)
    return
  if n.kind == nnkPrefix and n[0].eqIdent("-"):
    acc.sql.add "-("
    parseFNode(spec, dest, n[1], acc)
    acc.sql.add ")"
    return
  if n.kind == nnkInfix:
    let op = $n[0]
    if op notin ["+", "-", "*", "/"]:
      error(
        "fastorm: unsupported operator `" & op & "` in F() expression; " &
          "expected +, -, *, /",
        n,
      )
    if op == "/":
      acc.hasDiv = true
    acc.sql.add "("
    parseFNode(spec, dest, n[1], acc)
    acc.sql.add " " & op & " "
    parseFNode(spec, dest, n[2], acc)
    acc.sql.add ")"
    return
  if n.kind == nnkCall:
    error("fastorm: unsupported call `" & $n[0] & "` in F() expression", n)
  if dest.ctor == "IntegerField" and
      n.kind in {nnkFloatLit, nnkFloat32Lit, nnkFloat64Lit}:
    error(
      "fastorm: cannot use a float value when updating IntegerField " & spec.name & "." &
        dest.name,
      n,
    )
  acc.sql.add "?"
  if dest.ctor == "IntegerField":
    acc.params.add quote do:
      coerce(int, `n`)
  else:
    acc.params.add quote do:
      coerceFloat(`n`)

macro update*(qs: QuerySet, args: varargs[untyped]): untyped =
  ## Bulk `UPDATE` of all matching rows: `qs.update(name = "x")` or
  ## `qs.update(views = F(views) + 1)`. Returns `Future[int]` with the
  ## number of rows changed. Skips validation.
  let (T, spec) = querySetModel(qs)
  var sets = newNimNode(nnkBracket)
  for a in args:
    if a.kind != nnkExprEqExpr:
      error("fastorm: update expects `field = value` arguments", a)
    let f = findSpec(spec, a[0])
    if f.primaryKey:
      error("fastorm: update cannot change the primary key", a)
    let attr = ident(attrName(f))
    let col = newLit(f.column)
    let value = a[1]
    if containsF(value):
      if not isNumericCtor(f.ctor):
        error(
          "fastorm: F() can only assign an IntegerField or FloatField, but " & spec.name &
            "." & f.name & " is a " & f.ctor,
          a[0],
        )
      var acc: FBuild
      parseFNode(spec, f, value, acc)
      if acc.fCount == 0:
        error("fastorm: an F() expression must mention exactly one field", value)
      if acc.hasDiv and f.ctor != "FloatField":
        error(
          "fastorm: division produces a float and cannot be assigned to IntegerField " &
            spec.name & "." & f.name,
          value,
        )
      if f.ctor == "IntegerField" and acc.sourceCtor == "FloatField":
        error(
          "fastorm: cannot assign FloatField " & spec.name &
            " expression to IntegerField " & f.name,
          value,
        )
      let sqlLit = newLit(acc.sql)
      var paramsBrack = newNimNode(nnkBracket)
      for p in acc.params:
        paramsBrack.add p
      sets.add quote do:
        UpdateAssignment(column: `col`, sql: `sqlLit`, params: @`paramsBrack`)
    else:
      sets.add quote do:
        UpdateAssignment(
          column: `col`, sql: "?", params: @[coerce(typeof(`T`().`attr`), `value`)]
        )
  newCall(bindSym"updateImpl", qs, prefix(sets, "@"))

proc aggregateField(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkAccQuoted:
    if n.kind == nnkAccQuoted and (n.len != 1 or n[0].kind != nnkIdent):
      error("fastorm: expected a field name or \"*\"", n)
    if n.kind == nnkAccQuoted:
      $n[0]
    else:
      $n
  of nnkStrLit, nnkTripleStrLit:
    n.strVal
  else:
    error("fastorm: expected a field name or \"*\"", n)

proc aggregateKind(n: NimNode): NimNode =
  if n.kind != nnkCall or n.len != 2 or n[0].kind != nnkIdent:
    error(
      "fastorm: aggregate values must be Count(field), Sum(field), Avg(field), Min(field), or Max(field)",
      n,
    )
  if n[0].eqIdent("Count"):
    return ident"akCount"
  if n[0].eqIdent("Sum"):
    return ident"akSum"
  if n[0].eqIdent("Avg"):
    return ident"akAvg"
  if n[0].eqIdent("Min"):
    return ident"akMin"
  if n[0].eqIdent("Max"):
    return ident"akMax"
  error(
    "fastorm: unsupported aggregate `" & $n[0] &
      "`; expected Count, Sum, Avg, Min, or Max",
    n[0],
  )

macro aggregate*(qs: QuerySet, args: varargs[untyped]): untyped =
  ## Evaluates named SQL aggregates, for example:
  ## `await Article.objects.aggregate(total = Count(id), mean = Avg(views))`.
  let (_, spec) = querySetModel(qs)
  if args.len == 0:
    error("fastorm: aggregate needs at least one named aggregate", qs)
  var aggregates = newNimNode(nnkBracket)
  var aliases: seq[string]
  for arg in args:
    if arg.kind != nnkExprEqExpr:
      error("fastorm: aggregate expects named arguments, e.g. total = Count(id)", arg)
    let alias = aggregateField(arg[0])
    if alias == "*":
      error("fastorm: aggregate aliases cannot be `*`", arg[0])
    if alias in aliases:
      error("fastorm: duplicate aggregate alias `" & alias & "`", arg[0])
    aliases.add alias
    let call = arg[1]
    let kind = aggregateKind(call)
    let field = aggregateField(call[1])
    var column: string
    if field == "*":
      if not kind.eqIdent("akCount"):
        error("fastorm: only Count supports `*`", call[1])
      column = "*"
    else:
      let f = findSpec(spec, call[1])
      if kind.eqIdent("akSum") or kind.eqIdent("akAvg"):
        if f.ctor notin ["IntegerField", "FloatField"]:
          error(
            "fastorm: " & $call[0] & " requires an IntegerField or FloatField, but " &
              spec.name & "." & f.name & " is a " & f.ctor,
            call[1],
          )
      column = f.column
    let aliasLit = newLit(alias)
    let colLit = newLit(column)
    aggregates.add quote do:
      AggregateSpec(alias: `aliasLit`, column: `colLit`, kind: `kind`)
  newCall(bindSym"aggregateImpl", qs, prefix(aggregates, "@"))

proc relPath(n: NimNode): string =
  case n.kind
  of nnkStrLit, nnkTripleStrLit:
    n.strVal
  of nnkIdent:
    $n
  of nnkAccQuoted:
    if n.len == 1 and n[0].kind == nnkIdent:
      $n[0]
    else:
      error("fastorm: expected a relation name", n)
  of nnkDotExpr:
    if n[1].kind != nnkIdent:
      error("fastorm: expected a relation name", n)
    relPath(n[0]) & "." & $n[1]
  else:
    error(
      "fastorm: expected a relation name such as `author` or \"author.publisher\"", n
    )

proc cacheTarget(cache: CacheTable, key: string): string =
  if key in cache:
    cache[key].strVal
  else:
    ""

proc walkRelation(start, path: string, n: NimNode, forwardOnly: bool): bool =
  ## Walks `path` from `start`. Returns true when a hop is a reverse relation.
  var model = start
  for part in path.split('.'):
    if part.len == 0:
      error("fastorm: empty relation in `" & path & "`", n)
    let key = model & "." & part
    let forward = cacheTarget(forwardCache, key)
    if forward.len > 0:
      model = forward
      continue
    let reverse = cacheTarget(reverseCache, key)
    if reverse.len > 0:
      if forwardOnly:
        error(
          "fastorm: `" & key & "` is a reverse relation; selectRelated follows " &
            "foreign keys only. Use prefetchRelated(\"" & path & "\")",
          n,
        )
      result = true
      model = reverse
      continue
    error("fastorm: " & model & " has no relation `" & part & "`", n)

proc calleeName(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkSym, nnkAccQuoted:
    $n
  of nnkOpenSymChoice, nnkClosedSymChoice:
    if n.len > 0:
      $n[0]
    else:
      ""
  of nnkDotExpr:
    calleeName(n[^1])
  of nnkBracketExpr:
    calleeName(n[0])
  else:
    ""

proc chainHas(n: NimNode, names: HashSet[string]): bool =
  ## Walks a QuerySet call chain looking for a callee in `names`.
  var cur = n
  while cur.kind in {nnkCall, nnkCommand, nnkInfix}:
    if calleeName(cur[0]) in names:
      return true
    if cur.len < 2:
      return false
    cur = cur[1]
  false

const eagerCallees = [
  "addSelect", "addPrefetch", "addExpand", "selectRelated", "prefetchRelated", "expand"
].toHashSet
const projectCallees = ["applyOnly", "applyDefer", "only", "defer"].toHashSet

proc rejectProjectionWithEager(qs: NimNode, eager: bool) =
  if eager and chainHas(qs, projectCallees):
    error(
      "fastorm: only() and defer() cannot be combined with selectRelated " &
        "or prefetchRelated",
      qs,
    )
  if not eager and chainHas(qs, eagerCallees):
    error(
      "fastorm: only() and defer() cannot be combined with selectRelated " &
        "or prefetchRelated",
      qs,
    )

proc projectionFields(spec: ModelSpec, fields: NimNode): seq[string] =
  var seen: HashSet[string]
  for f in fields:
    let fs = findSpec(spec, f)
    if fs.name in seen:
      error("fastorm: duplicate field `" & fs.name & "` in only()/defer()", f)
    seen.incl fs.name
    result.add fs.column

macro selectRelated*(qs: QuerySet, rels: varargs[untyped]): untyped =
  ## Follows foreign keys with a LEFT JOIN so the related objects are already
  ## loaded (`model.author()` does not query again). Paths use dots:
  ## `selectRelated("author.publisher")` or `selectRelated(author.publisher)`.
  rejectProjectionWithEager(qs, eager = true)
  let (_, spec) = querySetModel(qs)
  result = qs
  for r in rels:
    let path = relPath(r)
    discard walkRelation(spec.name, path, r, forwardOnly = true)
    result = newCall(bindSym"addSelect", result, newLit(path))

macro prefetchRelated*(qs: QuerySet, rels: varargs[untyped]): untyped =
  ## Loads relations in batched follow-up queries. Works for foreign keys and
  ## for the reverse side (`author.articles()` when `Article.author` points
  ## at `Author`). Nested paths (`"articles.chapters"`) each take one query.
  rejectProjectionWithEager(qs, eager = true)
  let (_, spec) = querySetModel(qs)
  result = qs
  for r in rels:
    let path = relPath(r)
    discard walkRelation(spec.name, path, r, forwardOnly = false)
    result = newCall(bindSym"addPrefetch", result, newLit(path))

macro only*(qs: QuerySet, fields: varargs[untyped]): untyped =
  ## Selects only the named columns (plus the primary key). A later `only`
  ## replaces the previous projection. Incompatible with `selectRelated`
  ## and `prefetchRelated`.
  rejectProjectionWithEager(qs, eager = false)
  let (_, spec) = querySetModel(qs)
  if fields.len == 0:
    error("fastorm: only() needs at least one field", qs)
  var cols = projectionFields(spec, fields)
  let pk = spec.fields[pkIndex(spec.fields)].column
  if pk notin cols:
    cols.insert(pk, 0)
  var brack = newNimNode(nnkBracket)
  for c in cols:
    brack.add newLit(c)
  newCall(bindSym"applyOnly", qs, prefix(brack, "@"))

macro `defer`*(qs: QuerySet, fields: varargs[untyped]): untyped =
  ## Omits the named columns from the result. The primary key is always
  ## kept. Incompatible with `selectRelated` and `prefetchRelated`.
  rejectProjectionWithEager(qs, eager = false)
  let (_, spec) = querySetModel(qs)
  if fields.len == 0:
    error("fastorm: defer() needs at least one field", qs)
  let cols = projectionFields(spec, fields)
  var brack = newNimNode(nnkBracket)
  for c in cols:
    brack.add newLit(c)
  newCall(bindSym"applyDefer", qs, prefix(brack, "@"))

# -- N+1 detection -----------------------------------------------------------
#
# `checkNPlusOne` is a best-effort, purely syntactic scan over a block of
# user code: it looks for `for v in <query>:` loops and, inside their body,
# calls like `v.author()` or `v.articles()` that look like a fastorm relation
# accessor the surrounding query didn't already eager-load with
# `selectRelated`/`prefetchRelated`. It never changes what the code does; it
# can only fail the build (when `-d:raiseNPlusOne` is passed) by reporting
# every offending call site it found.

proc allRelationNames(): HashSet[string] =
  ## Every relation name ever registered on any model, forward or reverse
  ## (`"Book.author" -> "Author"` contributes `"author"`). Used as a allowlist
  ## so the scan only flags calls that are plausibly relation accessors.
  for key, _ in pairs(forwardCache):
    let dot = key.find('.')
    if dot >= 0:
      result.incl key[dot + 1 .. ^1]
  for key, _ in pairs(reverseCache):
    let dot = key.find('.')
    if dot >= 0:
      result.incl key[dot + 1 .. ^1]

proc safeRelPath(n: NimNode): string =
  ## Like `relPath`, but returns "" instead of raising a compile error for
  ## shapes it doesn't recognize (used where a mismatch just means "this
  ## wasn't a relation path argument", not a user mistake).
  case n.kind
  of nnkStrLit, nnkTripleStrLit:
    n.strVal
  of nnkIdent:
    $n
  of nnkDotExpr:
    if n[1].kind == nnkIdent:
      let base = safeRelPath(n[0])
      if base.len > 0:
        base & "." & $n[1]
      else:
        ""
    else:
      ""
  else:
    ""

proc stripAwait(n: NimNode): NimNode =
  if n.len == 2 and n.kind in {nnkCommand, nnkCall} and n[0].kind == nnkIdent and
      n[0].eqIdent("await"):
    stripAwait(n[1])
  else:
    n

proc matchRelationCall(n: NimNode): tuple[recv: NimNode, relName: string, ok: bool] =
  ## Recognizes `<recv>.<relName>(...)`, optionally `await`ed: the shape every
  ## generated relation accessor is called with.
  let inner = stripAwait(n)
  if inner.kind == nnkCall and inner.len >= 1 and inner[0].kind == nnkDotExpr and
      inner[0].len == 2 and inner[0][1].kind == nnkIdent:
    return (inner[0][0], $inner[0][1], true)
  (nil, "", false)

proc collectEagerPaths(n: NimNode, into: var HashSet[string]) =
  ## Recursively finds `.selectRelated(...)`/`.prefetchRelated(...)` calls
  ## anywhere in `n` and collects their path arguments.
  if n.kind == nnkCall and n.len >= 2 and n[0].kind == nnkDotExpr and n[0].len == 2 and
      n[0][1].kind == nnkIdent and (
    $n[0][1] == "selectRelated" or $n[0][1] == "prefetchRelated" or $n[0][1] == "expand"
  ):
    for i in 1 ..< n.len:
      let path = safeRelPath(n[i])
      if path.len > 0:
        into.incl path
  for c in n:
    collectEagerPaths(c, into)

proc derivedEagerPaths(
    iterable: NimNode, ctx: Table[string, HashSet[string]]
): HashSet[string] =
  ## The eager-loaded relation paths a `for v in iterable:` loop's body can
  ## rely on: paths named directly on `iterable` itself, plus — when
  ## `iterable` is `other.relName()` for an already-tracked `other` — the
  ## tail of any of `other`'s eager paths that start with `relName.`
  ## (`prefetchRelated("articles.chapters")` on the outer loop covers
  ## `chapters` on `for article in author.articles():`).
  result = initHashSet[string]()
  collectEagerPaths(iterable, result)
  let (recv, relName, ok) = matchRelationCall(iterable)
  if ok and recv.kind == nnkIdent and $recv in ctx:
    let prefix = relName & "."
    for p in ctx[$recv]:
      if p.startsWith(prefix):
        result.incl p[prefix.len .. ^1]

proc isEagerlyLoaded(eager: HashSet[string], relName: string): bool =
  ## `relName` is covered either directly (`"author" in eager`) or because a
  ## deeper path through it was eager-loaded (`"articles.chapters"` covers
  ## `"articles"`, since reaching `chapters` already requires joining/
  ## fetching `articles`).
  if relName in eager:
    return true
  let prefix = relName & "."
  for p in eager:
    if p.startsWith(prefix):
      return true
  false

proc checkCallViolation(
    n: NimNode,
    ctx: Table[string, HashSet[string]],
    relationNames: HashSet[string],
    findings: var seq[string],
): bool =
  ## Checks whether `n` is a `<ident>.<relation>(...)` call (optionally
  ## `await`ed) on a tracked loop variable, recording a finding if the
  ## relation wasn't eager-loaded. Returns whether `n` matched that shape at
  ## all (flagged or not), so callers can skip recursing into it.
  let (recv, relName, ok) = matchRelationCall(n)
  if not (ok and recv.kind == nnkIdent and relName in relationNames):
    return false
  let recvName = $recv
  if recvName in ctx and not isEagerlyLoaded(ctx[recvName], relName):
    let info = n.lineInfoObj
    findings.add(
      info.filename & "(" & $info.line & "): `" & recvName & "." & relName &
        "()` inside a loop may run one query per row. Add `.selectRelated(\"" & relName &
        "\")` or `.prefetchRelated(\"" & relName & "\")` to the query that produced `" &
        recvName & "`."
    )
  true

proc scanForNPlusOne(
    n: NimNode,
    ctx: var Table[string, HashSet[string]],
    relationNames: HashSet[string],
    findings: var seq[string],
) =
  if n.kind == nnkForStmt and n.len == 3 and n[0].kind == nnkIdent:
    let varName = $n[0]
    # The iterable itself is a relation access running once per outer
    # iteration (`for chapter in article.chapters():` inside a loop over
    # articles), so it needs the same check as any other relation call.
    discard checkCallViolation(n[1], ctx, relationNames, findings)
    let eager = derivedEagerPaths(n[1], ctx)
    let prev =
      if varName in ctx:
        some(ctx[varName])
      else:
        none(HashSet[string])
    ctx[varName] = eager
    scanForNPlusOne(n[2], ctx, relationNames, findings)
    if prev.isSome:
      ctx[varName] = prev.get
    else:
      ctx.del(varName)
    return
  if checkCallViolation(n, ctx, relationNames, findings):
    return
  for c in n:
    scanForNPlusOne(c, ctx, relationNames, findings)

macro checkNPlusOne*(body: untyped): untyped =
  ## Scans `body` for the classic N+1 pattern: a `for v in <query>:` loop
  ## whose body calls a relation accessor on `v` (`v.author()`,
  ## `v.articles()`, ...) that the query producing `v` didn't already
  ## eager-load with `selectRelated`/`prefetchRelated`. Understands nested
  ## prefetch paths, so a loop derived from `prefetchRelated("a.b")` doesn't
  ## flag `.b()` inside a loop over `.a()`.
  ##
  ## Always expands to `body` unchanged — this only ever adds a compile-time
  ## check, never changes behavior. Without `-d:raiseNPlusOne` it's a no-op.
  ## With it, any findings fail the build, listing every offending call site.
  ##
  ## This is a syntactic, best-effort scan (no type information), so it only
  ## recognizes `for` loops with a single loop variable and relation calls
  ## written directly as `v.relName(...)`, `await v.relName(...)`. It can
  ## miss cases (e.g. a loop variable aliased through an intermediate `let`)
  ## and, rarely, flag an unrelated method that happens to share a relation's
  ## name.
  result = body
  when defined(raiseNPlusOne):
    let relationNames = allRelationNames()
    var ctx: Table[string, HashSet[string]]
    var findings: seq[string]
    scanForNPlusOne(body, ctx, relationNames, findings)
    if findings.len > 0:
      error(
        "fastorm: possible N+1 queries (-d:raiseNPlusOne):\n  " & findings.join("\n  "),
        body,
      )

# -- input objects -----------------------------------------------------------

proc inputFieldName(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkSym:
    $n
  of nnkOpenSymChoice, nnkClosedSymChoice:
    inputFieldName(n[0])
  of nnkAccQuoted:
    if n.len == 1:
      inputFieldName(n[0])
    else:
      error("fastorm: ignore expects a field name", n)
  of nnkDotExpr:
    inputFieldName(n[^1])
  of nnkStrLit, nnkTripleStrLit, nnkRStrLit:
    n.strVal
  else:
    error("fastorm: ignore expects a field name, got `" & n.repr & "`", n)

proc collectIgnore(call: NimNode): seq[string] =
  if call.len == 2 and call[1].kind == nnkBracket:
    for item in call[1]:
      result.add inputFieldName(item)
  else:
    for i in 1 ..< call.len:
      result.add inputFieldName(call[i])

proc parseTypeFrom(spec: NimNode): tuple[model: string, ignore: seq[string]] =
  if spec.kind in {nnkIdent, nnkSym}:
    return ($spec, @[])
  if spec.kind == nnkCall and spec[0].kind == nnkDotExpr and spec[0][1].eqIdent(
    "ignore"
  ):
    let head = spec[0][0]
    if head.kind notin {nnkIdent, nnkSym}:
      error("fastorm: typeFrom expects `Model` or `Model.ignore(field, ...)`", spec)
    return ($head, collectIgnore(spec))
  error(
    "fastorm: typeFrom expects `Model` or `Model.ignore(field, ...)`, got `" & spec.repr &
      "`",
    spec,
  )

proc ignoredFields(spec: ModelSpec, ignore: seq[string], at: NimNode): HashSet[string] =
  for name in ignore:
    var found = false
    for f in spec.fields:
      if f.name == name or attrName(f) == name:
        result.incl f.name
        found = true
    if not found:
      error("fastorm: " & spec.name & " has no field `" & name & "`", at)

proc inputObject(spec: ModelSpec, ignore: seq[string], at: NimNode): NimNode =
  let skipped = ignoredFields(spec, ignore, at)
  var rec = newNimNode(nnkRecList)
  for f in spec.fields:
    if f.name in skipped:
      continue
    rec.add newIdentDefs(postfix(ident(attrName(f)), "*"), nimType(f))
  nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), rec)

macro typeFrom*(name: untyped, spec: untyped): untyped =
  ## Declares a plain object type from a model's columns, for a request body.
  ##
  ## ```nim
  ## typeFrom(CreateAuthor, Author.ignore(id))
  ## typeFrom(CreateBook, Book.ignore(id, createdAt))
  ## ```
  ##
  ## `.ignore` takes field names (`id`, `author`) or the stored name of a
  ## foreign key (`authorId`). `Author.id` is the same as `id`. A foreign key
  ## becomes its key column (`authorId: int`, or `Option[int]` when nullable).
  ## Fields that are not ignored use the same Nim type as the model.
  if name.kind != nnkIdent:
    error(
      "fastorm: typeFrom expects a type name, as in `typeFrom(CreateAuthor, Author.ignore(id))`",
      name,
    )
  let parsed = parseTypeFrom(spec)
  if parsed.model notin modelCache:
    error(
      "fastorm: unknown model `" & parsed.model &
        "`; declare it with `model` before typeFrom",
      spec,
    )
  nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      name, newEmptyNode(), inputObject(readModel(parsed.model), parsed.ignore, spec)
    )
  )

proc addInputFields(def: NimNode, into: var seq[string]) =
  if def.kind != nnkIdentDefs:
    return
  for i in 0 ..< def.len - 2:
    let n = def[i]
    let name =
      if n.kind == nnkPostfix:
        $n[1]
      elif n.kind == nnkPragmaExpr:
        $n[0]
      else:
        $n
    if name != "cache":
      into.add name

proc fieldsOfType(t: NimNode, into: var seq[string]) =
  var n = t
  if n.kind notin {nnkObjectTy, nnkRefTy, nnkRecList}:
    n = getTypeImpl(n)
  if n.kind == nnkRefTy:
    n = n[0]
  if n.kind == nnkObjectTy:
    if n[1].kind == nnkOfInherit:
      for parent in n[1]:
        fieldsOfType(parent, into)
    for def in n[2]:
      addInputFields(def, into)
  elif n.kind == nnkRecList:
    for def in n:
      addInputFields(def, into)
  else:
    error("fastorm: toModel copies fields from an object, got `" & n.repr & "`", t)

macro toModel*(source: typed, model: typed): untyped =
  ## Copies `source`'s fields onto a new model. Omitted fields keep the
  ## defaults from `newModel()`.
  ##
  ## ```nim
  ## let author = body.toModel(Author)
  ## await author.save()
  ## ```
  if model.kind notin {nnkSym, nnkIdent}:
    error("fastorm: toModel expects a model type, as in `input.toModel(Author)`", model)
  let name = $model
  if name notin modelCache:
    error("fastorm: unknown model `" & name & "`", model)
  let spec = readModel(name)
  if spec.abstract:
    error("fastorm: `" & name & "` is abstract and cannot be constructed", model)
  var columns = initHashSet[string]()
  for f in spec.fields:
    columns.incl attrName(f)
  var incoming: seq[string]
  fieldsOfType(getTypeImpl(source), incoming)
  let src = genSym(nskLet, "src")
  let dest = genSym(nskVar, "model")
  var body = newStmtList()
  body.add newLetStmt(src, source)
  body.add newVarStmt(dest, newCall(ident("new" & name)))
  var seen = initHashSet[string]()
  for field in incoming:
    if field in seen:
      continue
    seen.incl field
    if field notin columns:
      error("fastorm: `" & field & "` is not a field of " & name, source)
    body.add newAssignment(
      newDotExpr(dest, ident(field)), newDotExpr(src, ident(field))
    )
  body.add dest
  nnkBlockStmt.newTree(newEmptyNode(), body)

# -- serializers -------------------------------------------------------------

proc typeHead(t: NimNode): string =
  if t.kind == nnkBracketExpr and t.len > 0:
    let head = t[0]
    if head.kind in {nnkSym, nnkIdent}:
      $head
    else:
      typeHead(head)
  else:
    ""

proc typeTailName(t: NimNode): string =
  var n = t
  while n.kind == nnkBracketExpr and n.len > 1:
    n = n[^1]
  if n.kind in {nnkSym, nnkIdent}:
    let name = $n
    let colon = name.find(':')
    if colon > 0:
      name[0 ..< colon]
    else:
      name
  else:
    ""

proc fastormIgnored*[T](value: T, fields: varargs[string]): T {.raises: [].} =
  ## Gives `model.omit(field)` the model's type so FastNim's `ok` and `created`
  ## accept it. The names are also stored for `toJsonHook`.
  when T is FastormModel:
    rememberOmit(value, fields)
  elif T is seq:
    for item in value:
      when typeof(item) is FastormModel:
        rememberOmit(item, fields)
  elif T is Option:
    type Inner = typeof(get(value))
    when Inner is FastormModel:
      if isSome(value):
        rememberOmit(get(value), fields)
  value

proc fastormExpanded*[T](value: T, paths: varargs[string]): T {.raises: [].} =
  ## Stamps `expand` paths onto an already-fetched model. Does not query.
  when T is FastormModel:
    rememberExpand(value, paths)
  elif T is seq:
    for item in value:
      when typeof(item) is FastormModel:
        rememberExpand(item, paths)
  elif T is Option:
    type Inner = typeof(get(value))
    when Inner is FastormModel:
      if isSome(value):
        rememberExpand(get(value), paths)
  value

proc modelJson*[T](value: T): string {.raises: [].} =
  ## JSON for a model, `seq[Model]`, or `Option[Model]`, including `expand`.
  when T is FastormModel:
    $toJsonHook(value)
  elif T is seq:
    var parts = newSeqOfCap[string](value.len)
    for item in value:
      when typeof(item) is FastormModel:
        parts.add $toJsonHook(item)
      else:
        parts.add "null"
    "[" & parts.join(",") & "]"
  elif T is Option:
    type Inner = typeof(get(value))
    when Inner is FastormModel:
      if isNone(value):
        "null"
      else:
        $toJsonHook(get(value))
    else:
      "null"
  else:
    "null"

proc collectStrings(n: NimNode, into: var seq[string]) =
  if n.kind in {nnkStrLit, nnkTripleStrLit}:
    into.add n.strVal
  elif n.kind in {nnkBracket, nnkHiddenStdConv, nnkStmtList, nnkPrefix, nnkCall}:
    for c in n:
      collectStrings(c, into)

proc ignoredNames(call: NimNode): seq[string] =
  ## Field names sit after the value, inside the varargs conversion Nim inserts.
  for i in 2 ..< call.len:
    collectStrings(call[i], result)

proc isIgnoredCall(n: NimNode): bool =
  n.kind == nnkCall and n.len >= 1 and (
    if n[0].kind in {nnkSym, nnkIdent, nnkOpenSymChoice, nnkClosedSymChoice}:
      ($n[0]).startsWith("fastormIgnored")
    else: false
  )

macro omit*(value: typed, fields: varargs[untyped]): untyped =
  ## Marks fields to drop from a later `serialize`. Names are the model field
  ## (`id`, `author`) or the stored foreign key (`authorId`).
  ##
  ## ```nim
  ## echo author.omit(id, createdAt).serialize()
  ## ```
  let typ = getTypeInst(value)
  let modelName = typeTailName(typ)
  if modelName notin modelCache:
    error("fastorm: ignore applies to a model, seq[Model], or Option[Model]", value)
  var names: seq[string]
  var base = value
  if isIgnoredCall(value):
    base = value[1]
    names = ignoredNames(value)
  for field in fields:
    names.add inputFieldName(field)
  discard ignoredFields(
    readModel(modelName),
    names,
    if fields.len > 0:
      fields[0]
    else:
      value,
  )
  result = newCall(bindSym"fastormIgnored", base)
  for name in names:
    result.add newLit(name)

proc expandQuery(qs: NimNode, rels: NimNode): NimNode =
  rejectProjectionWithEager(qs, eager = true)
  if rels.len == 0:
    error("fastorm: expand() needs at least one relation", qs)
  let (_, spec) = querySetModel(qs)
  result = qs
  for r in rels:
    let path = relPath(r)
    let reversed = walkRelation(spec.name, path, r, forwardOnly = false)
    if reversed:
      result = newCall(bindSym"addPrefetch", result, newLit(path))
    else:
      result = newCall(bindSym"addSelect", result, newLit(path))
    result = newCall(bindSym"addExpand", result, newLit(path))

macro expand*(qs: QuerySet, rels: varargs[untyped]): untyped =
  ## Eager-loads relations and nests them into JSON (`ok`, `created`,
  ## `serialize`, `toJson`). Forward-only paths use `selectRelated`; a
  ## reverse hop uses `prefetchRelated`. Dotted paths write every prefix:
  ## `expand(author.publisher)` writes `author` and `author.publisher`.
  ##
  ## ```nim
  ## ok await Book.objects.expand(author).all()
  ## ok await Book.objects.expand(author.publisher).all()
  ## ok await Author.objects.expand(articles).all()
  ## ```
  expandQuery(qs, rels)

macro expand*(value: typed, rels: varargs[untyped]): untyped =
  ## Nests already-loaded relations into JSON. Paths are compile-checked.
  ## A QuerySet argument also eager-loads them.
  ##
  ## ```nim
  ## echo book.expand(author).serialize()
  ## ```
  let typ = getTypeInst(value)
  if typeHead(typ) == "QuerySet":
    return expandQuery(value, rels)
  let modelName = typeTailName(typ)
  if modelName notin modelCache:
    error("fastorm: expand applies to a model, seq[Model], or Option[Model]", value)
  if rels.len == 0:
    error("fastorm: expand() needs at least one relation", value)
  var paths: seq[string]
  var base = value
  if value.kind == nnkCall and value.len >= 1 and
      value[0].kind in {nnkSym, nnkIdent, nnkOpenSymChoice, nnkClosedSymChoice} and
      ($value[0]).startsWith("fastormExpanded"):
    base = value[1]
    collectStrings(value, paths)
  for r in rels:
    let path = relPath(r)
    discard walkRelation(modelName, path, r, forwardOnly = false)
    if path notin paths:
      paths.add path
  result = newCall(bindSym"fastormExpanded", base)
  for path in paths:
    result.add newLit(path)

macro serialize*(value: typed): untyped =
  ## Serializes a model, `seq[Model]`, or `Option[Model]` to a JSON string.
  ## Relations listed by `expand` are nested. Chain `.omit` to drop fields.
  ##
  ## ```nim
  ## echo author.serialize()
  ## echo author.omit(id, createdAt).serialize()
  ## echo book.expand(author).serialize()
  ## ```
  ##
  ## `id` and `Author.id` name the same field. A foreign key is written as its
  ## key (`authorId`). UUIDs and datetimes are strings; null fields are `null`.
  let typ = getTypeInst(value)
  let modelName = typeTailName(typ)
  if modelName notin modelCache:
    error("fastorm: serialize expects a model, seq[Model], or Option[Model]", value)
  newCall(bindSym"modelJson", value)
