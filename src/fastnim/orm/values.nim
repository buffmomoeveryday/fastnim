## Error types and conversions between Nim values and SQLite values.

import std/[options, times, strutils, json, base64]
import ./uuids

type
  FastOrmError* = object of CatchableError
  DatabaseError* = object of FastOrmError
    sqliteCode*: int32
      ## SQLite's extended result code for the failure (e.g. 2067 for
      ## `SQLITE_CONSTRAINT_UNIQUE`), or 0 when the error didn't come from a
      ## SQLite call that reports one. See `fastorm/outcome` for a classifier
      ## built on top of this.
  QueryError* = object of FastOrmError
  MultipleObjectsReturned* = object of QueryError
  MigrationError* = object of FastOrmError

  FieldIssue* = object
    field*: string
    message*: string

  ValidationError* = object of FastOrmError
    errors*: seq[FieldIssue]

  DbValueKind* = enum
    dvNull, dvInt, dvFloat, dvText, dvBlob

  DbValue* = object
    case kind*: DbValueKind
    of dvNull: discard
    of dvInt: i*: int64
    of dvFloat: f*: float64
    of dvText: s*: string
    of dvBlob: b*: seq[byte]

const timeFormat = initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'.'ffffff'Z'")

proc storedNow*(): Time =
  ## The current time truncated to the microsecond precision SQLite stores,
  ## so an instance compares equal to its reloaded copy.
  let t = getTime()
  initTime(t.toUnix, (t.nanosecond div 1000) * 1000)

proc newValidationError*(errors: seq[FieldIssue]): ref ValidationError =
  var parts: seq[string]
  for e in errors: parts.add e.field & ": " & e.message
  result = newException(ValidationError, "validation failed: " & parts.join("; "))
  result.errors = errors

proc `$`*(v: DbValue): string =
  case v.kind
  of dvNull: "NULL"
  of dvInt: $v.i
  of dvFloat: $v.f
  of dvText: v.s.escape
  of dvBlob: "<blob " & $v.b.len & " bytes>"

proc `==`*(a, b: DbValue): bool =
  if a.kind != b.kind: return false
  case a.kind
  of dvNull: true
  of dvInt: a.i == b.i
  of dvFloat: a.f == b.f
  of dvText: a.s == b.s
  of dvBlob: a.b == b.b

proc dbNull*(): DbValue = DbValue(kind: dvNull)

proc toDbValue*(v: DbValue): DbValue = v
proc toDbValue*(v: string): DbValue = DbValue(kind: dvText, s: v)
proc toDbValue*(v: SomeInteger): DbValue = DbValue(kind: dvInt, i: int64(v))
proc toDbValue*(v: SomeFloat): DbValue = DbValue(kind: dvFloat, f: float64(v))
proc toDbValue*(v: bool): DbValue = DbValue(kind: dvInt, i: int64(ord(v)))
proc toDbValue*(v: UUID): DbValue = DbValue(kind: dvText, s: $v)
proc toDbValue*(v: Time): DbValue = DbValue(kind: dvText, s: v.utc.format(timeFormat))
proc toDbValue*(v: seq[byte]): DbValue = DbValue(kind: dvBlob, b: v)

proc binaryText*(b: seq[byte]): string =
  ## Base64 form used when a `BinaryField` is serialized to JSON.
  encode(b)
proc toDbValue*[T](v: Option[T]): DbValue =
  if v.isSome: toDbValue(v.get) else: dbNull()

proc mismatch(v: DbValue, expected: string): ref DatabaseError =
  newException(DatabaseError, "cannot convert SQLite value " & $v & " to " & expected)

proc fromDbValue*(v: DbValue, t: typedesc[string]): string {.raises: [DatabaseError].} =
  case v.kind
  of dvText: v.s
  of dvInt: $v.i
  of dvFloat: $v.f
  else: raise mismatch(v, "string")

proc fromDbValue*(v: DbValue, t: typedesc[int]): int {.raises: [DatabaseError].} =
  if v.kind != dvInt: raise mismatch(v, "int")
  int(v.i)

proc fromDbValue*(v: DbValue, t: typedesc[int64]): int64 {.raises: [DatabaseError].} =
  if v.kind != dvInt: raise mismatch(v, "int64")
  v.i

proc fromDbValue*(v: DbValue, t: typedesc[float]): float {.raises: [DatabaseError].} =
  case v.kind
  of dvFloat: v.f
  of dvInt: float(v.i)
  else: raise mismatch(v, "float")

proc fromDbValue*(v: DbValue, t: typedesc[bool]): bool {.raises: [DatabaseError].} =
  if v.kind != dvInt: raise mismatch(v, "bool")
  v.i != 0

proc fromDbValue*(v: DbValue, t: typedesc[UUID]): UUID {.raises: [DatabaseError].} =
  if v.kind != dvText: raise mismatch(v, "UUID")
  try: parseUUID(v.s)
  except ValueError: raise mismatch(v, "UUID")

proc fromDbValue*(v: DbValue, t: typedesc[Time]): Time {.raises: [DatabaseError].} =
  if v.kind != dvText: raise mismatch(v, "Time")
  try: parse(v.s, timeFormat, utc()).toTime
  except ValueError: raise mismatch(v, "Time")

proc fromDbValue*[T](v: DbValue, t: typedesc[Option[T]]): Option[T] {.raises: [DatabaseError].} =
  if v.kind == dvNull: none(T) else: some(fromDbValue(v, T))

# -- decimal, date, time of day, duration ------------------------------------

type
  Decimal* = distinct string
    ## Exact decimal text, produced by `decimal`. Stored as `TEXT`.
  Date* = object
    ## A calendar date. `year`, `month` (1..12) and `day` are public; `initDate`
    ## rejects dates that are not on the calendar.
    year*, month*, day*: int
  TimeOfDay* = object
    ## A clock time, independent of a date. `microsecond` is 0..999999.
    hour*, minute*, second*, microsecond*: int
  TimeSpan* = distinct int64
    ## A duration in microseconds. Named `TimeSpan` so it does not clash with
    ## Chronos' `Duration`, which `import fastnim/orm` also exports.

proc `$`*(d: Decimal): string {.borrow.}
proc `==`*(a, b: Decimal): bool {.borrow.}

proc inspectDecimal(s: string): tuple[msg, canon: string, digits, places: int] =
  ## `msg` is empty when `s` is a plain decimal (no exponent). `canon` drops
  ## leading zeros on the integer part. `places` is -1 when the check is only
  ## syntactic and the caller passes that sentinel; here it is the fractional
  ## length actually written.
  if s.len == 0: return ("decimal is empty", "", 0, 0)
  var i = 0
  var negative = false
  if s[0] == '-':
    negative = true
    i = 1
  elif s[0] == '+':
    return ("decimal cannot start with '+'", "", 0, 0)
  if i >= s.len: return ("decimal is empty", "", 0, 0)
  var whole = ""
  while i < s.len and s[i] in {'0'..'9'}:
    whole.add s[i]
    inc i
  var frac = ""
  if i < s.len and s[i] == '.':
    inc i
    if i >= s.len: return ("decimal has a trailing decimal point", "", 0, 0)
    while i < s.len and s[i] in {'0'..'9'}:
      frac.add s[i]
      inc i
  if i != s.len or whole.len == 0:
    return ("decimal must be digits with an optional fraction", "", 0, 0)
  while whole.len > 1 and whole[0] == '0':
    whole = whole[1 .. ^1]
  result.canon = (if negative: "-" else: "") & whole
  if frac.len > 0: result.canon.add '.' & frac
  result.digits = whole.len + frac.len
  result.places = frac.len

proc decimal*(s: string): Decimal {.raises: [ValueError].} =
  ## Parses `s` into a `Decimal`. Leading zeros on the integer part are
  ## dropped (`"00.50"` becomes `"0.50"`). Exponents are rejected.
  let info = inspectDecimal(s)
  if info.msg.len > 0: raise newException(ValueError, info.msg)
  Decimal(info.canon)

proc decimalInfo*(d: Decimal): tuple[msg, canon: string, digits, places: int] =
  inspectDecimal($d)

proc initDate*(year, month, day: int): Date {.raises: [ValueError].} =
  ## A calendar date. `year` is 0..9999 and `month` is 1..12, so the stored
  ## form is always `YYYY-MM-DD`.
  if year < 0 or year > 9999:
    raise newException(ValueError, "year must be 0..9999")
  if month < 1 or month > 12:
    raise newException(ValueError, "month must be 1..12")
  let days = getDaysInMonth(Month(month), year)
  if day < 1 or day > days:
    raise newException(ValueError, "day " & $day & " is not valid for month " & $month)
  Date(year: year, month: month, day: day)

proc `$`*(d: Date): string =
  ## `YYYY-MM-DD`.
  align($d.year, 4, '0') & "-" & align($d.month, 2, '0') & "-" & align($d.day, 2, '0')

proc today*(): Date {.raises: [].} =
  ## Today's date in UTC, at the same precision `DateTimeField` stores.
  let t = storedNow().utc
  try: initDate(t.year, ord(t.month), t.monthday)
  except ValueError: raiseAssert("today produced a date that is not on the calendar")

proc initTimeOfDay*(hour, minute, second: int, microsecond: int = 0): TimeOfDay {.
    raises: [ValueError].} =
  if hour notin 0 .. 23 or minute notin 0 .. 59 or second notin 0 .. 59 or
      microsecond notin 0 .. 999_999:
    raise newException(ValueError, "clock time is out of range")
  TimeOfDay(hour: hour, minute: minute, second: second, microsecond: microsecond)

proc `$`*(t: TimeOfDay): string =
  ## `HH:MM:SS.ffffff`.
  align($t.hour, 2, '0') & ":" & align($t.minute, 2, '0') & ":" &
    align($t.second, 2, '0') & "." & align($t.microsecond, 6, '0')

proc clockNow*(): TimeOfDay {.raises: [].} =
  ## The current UTC clock time, truncated to microseconds.
  let t = storedNow().utc
  try: initTimeOfDay(t.hour, t.minute, t.second, t.nanosecond div 1000)
  except ValueError: raiseAssert("clockNow produced a time that is out of range")

proc timeSpan*(microseconds: int64): TimeSpan = TimeSpan(microseconds)
proc microseconds*(d: TimeSpan): int64 = int64(d)
proc timeSpanMillis*(ms: int64): TimeSpan = TimeSpan(ms * 1000)
proc timeSpanSeconds*(s: int64): TimeSpan = TimeSpan(s * 1_000_000)
proc `$`*(d: TimeSpan): string = $int64(d)
proc `==`*(a, b: TimeSpan): bool = int64(a) == int64(b)

proc toDbValue*(v: Decimal): DbValue =
  let info = inspectDecimal($v)
  DbValue(kind: dvText, s: (if info.msg.len == 0: info.canon else: $v))

proc toDbValue*(v: Date): DbValue = DbValue(kind: dvText, s: $v)
proc toDbValue*(v: TimeOfDay): DbValue = DbValue(kind: dvText, s: $v)
proc toDbValue*(v: TimeSpan): DbValue = DbValue(kind: dvInt, i: int64(v))
proc toDbValue*(v: JsonNode): DbValue =
  if v.isNil: dbNull() else: DbValue(kind: dvText, s: $v)
proc toDbValue*[E: enum](v: E): DbValue = toDbValue($v)

proc fromDbValue*(v: DbValue, t: typedesc[Decimal]): Decimal {.raises: [DatabaseError].} =
  if v.kind != dvText: raise mismatch(v, "Decimal")
  Decimal(v.s)

proc fromDbValue*(v: DbValue, t: typedesc[Date]): Date {.raises: [DatabaseError].} =
  if v.kind != dvText or v.s.len != 10 or v.s[4] != '-' or v.s[7] != '-':
    raise mismatch(v, "Date")
  try: initDate(parseInt(v.s[0 .. 3]), parseInt(v.s[5 .. 6]), parseInt(v.s[8 .. 9]))
  except ValueError: raise mismatch(v, "Date")

proc fromDbValue*(v: DbValue, t: typedesc[TimeOfDay]): TimeOfDay {.raises: [DatabaseError].} =
  if v.kind != dvText or v.s.len != 15 or v.s[2] != ':' or v.s[5] != ':' or v.s[8] != '.':
    raise mismatch(v, "TimeOfDay")
  try:
    initTimeOfDay(parseInt(v.s[0 .. 1]), parseInt(v.s[3 .. 4]), parseInt(v.s[6 .. 7]),
                  parseInt(v.s[9 .. 14]))
  except ValueError: raise mismatch(v, "TimeOfDay")

proc fromDbValue*(v: DbValue, t: typedesc[TimeSpan]): TimeSpan {.raises: [DatabaseError].} =
  if v.kind != dvInt: raise mismatch(v, "TimeSpan")
  TimeSpan(v.i)

proc fromDbValue*(v: DbValue, t: typedesc[seq[byte]]): seq[byte] {.raises: [DatabaseError].} =
  if v.kind != dvBlob: raise mismatch(v, "seq[byte]")
  v.b

proc fromDbValue*(v: DbValue, t: typedesc[JsonNode]): JsonNode {.raises: [DatabaseError].} =
  if v.kind != dvText: raise mismatch(v, "JsonNode")
  try: parseJson(v.s)
  except CatchableError: raise mismatch(v, "JsonNode")

proc fromDbValue*[E: enum](v: DbValue, t: typedesc[E]): E {.raises: [DatabaseError].} =
  if v.kind != dvText: raise mismatch(v, $E)
  try: parseEnum[E](v.s)
  except ValueError: raise mismatch(v, $E)
