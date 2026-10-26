## Field descriptors and model metadata.
##
## The field constructors (`CharField`, `ForeignKey`, ...) are evaluated at
## compile time by the `model` macro, so invalid option combinations are
## reported as compile errors.

import std/[options, strutils, json]
import ./values

type
  FieldKind* = enum
    fkUUID
    fkChar
    fkText
    fkInteger
    fkFloat
    fkBoolean
    fkDateTime
    fkDate
    fkTime
    fkDuration
    fkDecimal
    fkJson
    fkBinary
    fkForeignKey

  FieldFormat* = enum
    ## Extra shape check on a string field. `ffNone` is an ordinary string.
    ffNone
    ffEmail
    ffUrl
    ffSlug

  OnDelete* = enum
    Cascade
    SetNull
    Restrict
    NoAction

  FieldDef* = object
    name*: string ## Nim field name on the model object
    column*: string ## SQLite column name
    kind*: FieldKind
    format*: FieldFormat
    primaryKey*: bool
    null*: bool
    unique*: bool
    index*: bool
    maxLength*: int ## 0 means unlimited
    minLength*: int
    maxDigits*: int
    decimalPlaces*: int
    hasDefault*: bool
    default*: DbValue
    autoNow*: bool
    autoNowAdd*: bool
    choices*: seq[DbValue]
    target*: string ## referenced model name (foreign keys)
    targetTable*: string
    targetColumn*: string
    targetKind*: FieldKind ## kind of the referenced primary key
    onDelete*: OnDelete
    relatedName*: string ## reverse accessor; empty when none was set

  ManyToManyDef* = object
    ## Metadata for an implicit many-to-many junction table. Unlike a
    ## ``FieldDef``, this relation does not occupy a column on either model.
    name*: string
    target*: string
    table*: string
    ownerColumn*: string
    targetColumn*: string
    ownerTable*: string
    targetTable*: string
    ownerKeyColumn*: string
    targetKeyColumn*: string
    ownerKind*: FieldKind
    targetKind*: FieldKind
    relatedName*: string

  MetaIndex* = object
    ## A model-level index declared in `Meta`. `descending` is parallel to
    ## `columns`; an empty sequence means every column is ascending.
    name*: string
    columns*: seq[string]
    descending*: seq[bool]
    unique*: bool

  ModelMeta* = object
    name*: string
    table*: string
    parent*: string
    fields*: seq[FieldDef]
    pkIndex*: int
    indexes*: seq[MetaIndex]
    ordering*: seq[string] ## column names; a leading `-` means descending
    manyToMany*: seq[ManyToManyDef] ## Virtual many-to-many relations.

proc invalid(msg: string) =
  raise newException(ValueError, "fastorm: " & msg)

proc base(
    kind: FieldKind, primaryKey, null, unique, index: bool, column: string
): FieldDef =
  if primaryKey and null:
    invalid("a primary key field cannot be nullable")
  FieldDef(
    kind: kind,
    primaryKey: primaryKey,
    null: null,
    unique: unique,
    index: index,
    column: column,
  )

proc UUIDField*(
    primaryKey = false, null = false, unique = false, index = false, column = ""
): FieldDef =
  base(fkUUID, primaryKey, null, unique, index, column)

proc CharField*(
    maxLength = 255,
    minLength = 0,
    primaryKey = false,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  if maxLength < 0 or minLength < 0:
    invalid("maxLength and minLength must not be negative")
  if maxLength > 0 and minLength > maxLength:
    invalid(
      "minLength (" & $minLength & ") is greater than maxLength (" & $maxLength & ")"
    )
  result = base(fkChar, primaryKey, null, unique, index, column)
  result.maxLength = maxLength
  result.minLength = minLength

proc TextField*(
    minLength = 0, null = false, unique = false, index = false, column = ""
): FieldDef =
  if minLength < 0:
    invalid("minLength must not be negative")
  result = base(fkText, false, null, unique, index, column)
  result.minLength = minLength

proc IntegerField*(
    primaryKey = false, null = false, unique = false, index = false, column = ""
): FieldDef =
  base(fkInteger, primaryKey, null, unique, index, column)

proc FloatField*(null = false, unique = false, index = false, column = ""): FieldDef =
  base(fkFloat, false, null, unique, index, column)

proc BooleanField*(null = false, index = false, column = ""): FieldDef =
  base(fkBoolean, false, null, false, index, column)

proc DateTimeField*(
    autoNow = false,
    autoNowAdd = false,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  if autoNow and autoNowAdd:
    invalid("autoNow and autoNowAdd are mutually exclusive")
  result = base(fkDateTime, false, null, unique, index, column)
  result.autoNow = autoNow
  result.autoNowAdd = autoNowAdd

proc timed(
    kind: FieldKind, autoNow, autoNowAdd, null, unique, index: bool, column: string
): FieldDef =
  if autoNow and autoNowAdd:
    invalid("autoNow and autoNowAdd are mutually exclusive")
  result = base(kind, false, null, unique, index, column)
  result.autoNow = autoNow
  result.autoNowAdd = autoNowAdd

proc DateField*(
    autoNow = false,
    autoNowAdd = false,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  ## A calendar date, stored as `YYYY-MM-DD`.
  timed(fkDate, autoNow, autoNowAdd, null, unique, index, column)

proc TimeField*(
    autoNow = false,
    autoNowAdd = false,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  ## A clock time, stored as `HH:MM:SS.ffffff` with no date attached.
  timed(fkTime, autoNow, autoNowAdd, null, unique, index, column)

proc DurationField*(
    null = false, unique = false, index = false, column = ""
): FieldDef =
  ## A `TimeSpan` in microseconds, stored as an integer.
  base(fkDuration, false, null, unique, index, column)

proc DecimalField*(
    maxDigits: int,
    decimalPlaces: int,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  ## An exact decimal stored as text. `maxDigits` counts every digit and
  ## `decimalPlaces` is how many of those may follow the decimal point.
  if maxDigits < 1:
    invalid("maxDigits must be at least 1")
  if decimalPlaces < 0 or decimalPlaces > maxDigits:
    invalid(
      "decimalPlaces (" & $decimalPlaces & ") must be between 0 and maxDigits (" &
        $maxDigits & ")"
    )
  result = base(fkDecimal, false, null, unique, index, column)
  result.maxDigits = maxDigits
  result.decimalPlaces = decimalPlaces

proc JSONField*(null = false, unique = false, index = false, column = ""): FieldDef =
  ## A `JsonNode`, stored as compact JSON text. SQL NULL (`null: true`) is
  ## distinct from a JSON `null`.
  base(fkJson, false, null, unique, index, column)

proc BinaryField*(
    maxLength = 0, null = false, unique = false, index = false, column = ""
): FieldDef =
  ## A `seq[byte]`, stored as a blob. `maxLength` of 0 means unlimited.
  if maxLength < 0:
    invalid("maxLength must not be negative")
  result = base(fkBinary, false, null, unique, index, column)
  result.maxLength = maxLength

proc shaped(
    format: FieldFormat,
    maxLength, minLength: int,
    primaryKey, null, unique, index: bool,
    column: string,
): FieldDef =
  result = CharField(maxLength, minLength, primaryKey, null, unique, index, column)
  result.format = format

proc EmailField*(
    maxLength = 254,
    minLength = 0,
    primaryKey = false,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  ## A `CharField` that must contain a single `@` and a dotted domain.
  shaped(ffEmail, maxLength, minLength, primaryKey, null, unique, index, column)

proc URLField*(
    maxLength = 200,
    minLength = 0,
    primaryKey = false,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  ## A `CharField` that must start with `http://` or `https://`.
  shaped(ffUrl, maxLength, minLength, primaryKey, null, unique, index, column)

proc SlugField*(
    maxLength = 50,
    minLength = 0,
    primaryKey = false,
    null = false,
    unique = false,
    index = false,
    column = "",
): FieldDef =
  ## A `CharField` of letters, digits, hyphens and underscores.
  shaped(ffSlug, maxLength, minLength, primaryKey, null, unique, index, column)

proc ForeignKey*(
    target: string,
    targetTable = "",
    targetColumn = "",
    targetKind = fkInteger,
    onDelete = Cascade,
    null = false,
    unique = false,
    index = true,
    column = "",
    relatedName = "",
): FieldDef =
  ## `target`, `targetTable`, `targetColumn` and `targetKind` are filled in by
  ## the `model` macro from the referenced model.
  if onDelete == SetNull and not null:
    invalid("ForeignKey(" & target & ", onDelete: SetNull) requires null: true")
  result = base(fkForeignKey, false, null, unique, index, column)
  result.target = target
  result.targetTable = targetTable
  result.targetColumn = targetColumn
  result.targetKind = targetKind
  result.onDelete = onDelete
  result.relatedName = relatedName

proc ManyToManyField*(
    target: string, relatedName = "", table = ""
): ManyToManyDef =
  ## Describes a many-to-many relation. The ``model`` macro fills the model
  ## and key metadata and creates the implicit junction table.
  ManyToManyDef(target: target, relatedName: relatedName, table: table)

proc named*(f: FieldDef, name, column: string): FieldDef =
  result = f
  result.name = name
  if result.column.len == 0:
    result.column = column

proc withDefault*(f: FieldDef, value: DbValue): FieldDef =
  if f.primaryKey:
    invalid("field '" & f.name & "': a primary key cannot have a default")
  result = f
  result.hasDefault = true
  result.default = value

proc withChoices*(f: FieldDef, values: seq[DbValue]): FieldDef =
  ## Restricts the field to `values`. An empty list is rejected.
  if values.len == 0:
    invalid("choices cannot be empty")
  result = f
  result.choices = values

proc pkField*(m: ModelMeta): FieldDef =
  m.fields[m.pkIndex]

proc findField*(m: ModelMeta, name: string): int =
  for i, f in m.fields:
    if f.name == name:
      return i
  -1

proc toSnakeCase*(s: string): string =
  for i, c in s:
    if c.isUpperAscii:
      if i > 0 and (
        s[i - 1].isLowerAscii or s[i - 1].isDigit or
        (i + 1 < s.len and s[i + 1].isLowerAscii and s[i - 1].isUpperAscii)
      ):
        result.add '_'
      result.add c.toLowerAscii
    else:
      result.add c

# -- runtime validation used by the generated `validate` procs ---------------

proc addIssue(errors: var seq[FieldIssue], field, message: string) =
  errors.add FieldIssue(field: field, message: message)

proc rejectChoice(errors: var seq[FieldIssue], f: FieldDef, got: DbValue) =
  if f.choices.len == 0:
    return
  for c in f.choices:
    if c == got:
      return
  addIssue(errors, f.name, $got & " is not an allowed choice")

proc formatProblem(format: FieldFormat, value: string): string =
  case format
  of ffNone:
    discard
  of ffEmail:
    let at = value.find('@')
    if value.len == 0 or at <= 0 or at != value.rfind('@') or at >= value.len - 1 or
        ' ' in value or '.' notin value[at + 1 .. ^1] or value[at + 1] == '.' or
        value[^1] == '.':
      result = "is not a valid email address"
  of ffUrl:
    let https = value.startsWith("https://") and value.len > "https://".len
    let http = value.startsWith("http://") and value.len > "http://".len
    if not https and not http or ' ' in value:
      result = "is not a valid URL"
  of ffSlug:
    if value.len == 0:
      return "is not a valid slug"
    for i, c in value:
      if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}:
        continue
      if c in {'-', '_'} and i > 0 and i < value.len - 1 and
          value[i - 1] notin {'-', '_'}:
        continue
      return "is not a valid slug"

proc checkField*(errors: var seq[FieldIssue], f: FieldDef, value: string) =
  let shape = formatProblem(f.format, value)
  if shape.len > 0:
    addIssue(errors, f.name, shape)
    return
  if f.maxLength > 0 and value.len > f.maxLength:
    addIssue(
      errors, f.name, "length " & $value.len & " exceeds maxLength " & $f.maxLength
    )
  if value.len < f.minLength:
    addIssue(
      errors, f.name, "length " & $value.len & " is below minLength " & $f.minLength
    )
  rejectChoice(errors, f, toDbValue(value))

proc checkField*(errors: var seq[FieldIssue], f: FieldDef, value: Decimal) =
  let info = decimalInfo(value)
  if info.msg.len > 0:
    addIssue(errors, f.name, info.msg)
    return
  if info.places > f.decimalPlaces:
    addIssue(
      errors,
      f.name,
      $info.places & " decimal places exceeds decimalPlaces " & $f.decimalPlaces,
    )
  elif info.digits - info.places > f.maxDigits - f.decimalPlaces:
    addIssue(errors, f.name, "exceeds maxDigits " & $f.maxDigits)
  else:
    rejectChoice(errors, f, toDbValue(value))

proc checkField*(errors: var seq[FieldIssue], f: FieldDef, value: Date) =
  try:
    discard initDate(value.year, value.month, value.day)
  except ValueError as e:
    addIssue(errors, f.name, e.msg)

proc checkField*(errors: var seq[FieldIssue], f: FieldDef, value: TimeOfDay) =
  try:
    discard initTimeOfDay(value.hour, value.minute, value.second, value.microsecond)
  except ValueError as e:
    addIssue(errors, f.name, e.msg)

proc checkField*(errors: var seq[FieldIssue], f: FieldDef, value: seq[byte]) =
  if f.maxLength > 0 and value.len > f.maxLength:
    addIssue(
      errors, f.name, "length " & $value.len & " exceeds maxLength " & $f.maxLength
    )

proc checkField*(errors: var seq[FieldIssue], f: FieldDef, value: JsonNode) =
  if value.isNil:
    addIssue(errors, f.name, "JSON value is missing")

proc checkField*[E: enum](errors: var seq[FieldIssue], f: FieldDef, value: E) =
  checkField(errors, f, $value)

proc checkField*[T: not string and not Option and not enum](
    errors: var seq[FieldIssue], f: FieldDef, value: T
) =
  rejectChoice(errors, f, toDbValue(value))

proc checkField*[T](errors: var seq[FieldIssue], f: FieldDef, value: Option[T]) =
  if value.isSome:
    checkField(errors, f, value.get)

proc runValidator*(errors: var seq[FieldIssue], field: string, message: string) =
  ## Validators return an empty string when the value is valid, otherwise a
  ## human readable error message.
  if message.len > 0:
    errors.add FieldIssue(field: field, message: message)

# -- registry of concrete models, used to build migration snapshots ----------

var registry: seq[ModelMeta]

proc registerModel*(m: ModelMeta) =
  ## Called from module initialization code generated by `model`.
  for existing in registry:
    if existing.name == m.name:
      return
  registry.add m

proc registeredModels*(): seq[ModelMeta] {.gcsafe.} =
  # The registry is only written while modules initialize, before any async
  # code or worker thread can run, so later reads cannot race with writes.
  {.cast(gcsafe).}:
    result = registry
