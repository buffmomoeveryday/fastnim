## Optional, non-raising wrapper for FastORM calls: `attempt(fut)` turns a
## `DatabaseError` / `ValidationError` / `QueryError` /
## `MultipleObjectsReturned` / `MigrationError` into a classified
## `FastormOutcomeError` instead of letting it propagate as an exception,
## for callers (an HTTP handler, say) that want to branch on *why* something
## failed without `try/except`:
##
## ```nim
## let outcome = await attempt(Author.objects.filter(name = name).get())
## if outcome.isErr:
##   if outcome.err.isUniqueViolation:
##     conflict initApiError("author_exists", "an author with that name already exists")
##   else:
##     raise outcome.err.cause
## else:
##   jsonBody(200, outcome.value.serialize())
## ```
##
## **Can this force the caller to check the error?** Not fully — no mainstream
## language without Rust-style linear types can. Nim's rule that a non-`void`
## proc result must be used or explicitly `discard`ed means the *whole*
## result of `attempt(...)` can't be silently dropped, but nothing stops
## `let (v, _) = (await attempt(...)).toPair()`-style code from reaching into
## the value while ignoring the error (and even Rust's `Result` is only
## `#[must_use]`-*warned*, not a hard error — `let _ = result;` compiles
## there too). What `FastormResult` gives you instead is a loud failure on
## misuse: `value`/`err` are fields of a `case` object, so reading the wrong
## one for the current `ok` branch panics immediately — instead of handing
## back something that looks like valid-but-wrong data (an empty `seq` is
## indistinguishable from "zero rows" vs. "the query failed").

import chronos
import ./values

type
  ErrorKind* = enum
    ekUniqueViolation     ## a UNIQUE or PRIMARY KEY constraint was violated
    ekForeignKeyViolation ## a FOREIGN KEY constraint was violated
    ekNotNullViolation    ## a NOT NULL constraint was violated
    ekCheckViolation      ## a CHECK constraint was violated
    ekBusy                ## the database was locked by another transaction
    ekValidation          ## field validation failed before saving
    ekQuery               ## a bad filter/orderBy/get (`QueryError`)
    ekOther                ## anything else (closed connection, I/O, ...)

  FastormOutcomeError* = object
    kind*: ErrorKind
    message*: string
    issues*: seq[FieldIssue]  ## populated when `kind == ekValidation`
    cause*: ref FastOrmError  ## the original exception (to log or re-raise)

  FastormResult*[T] = object
    case ok*: bool
    of true: value*: T
    of false: err*: FastormOutcomeError

  FastormVoidResult* = object
    ## `attempt` on a `Future[void]` call (`save()`, `delete()`, ...): there's
    ## no value to carry, just whether it succeeded.
    case ok*: bool
    of true: discard
    of false: err*: FastormOutcomeError

const
  uniqueOrPkCodes = [2067'i32, 1555'i32]  ## SQLITE_CONSTRAINT_{UNIQUE,PRIMARYKEY}
  foreignKeyCodes = [787'i32]             ## SQLITE_CONSTRAINT_FOREIGNKEY
  notNullCodes = [1299'i32]               ## SQLITE_CONSTRAINT_NOTNULL
  checkCodes = [275'i32]                  ## SQLITE_CONSTRAINT_CHECK
  busyCodes = [5'i32, 261'i32, 517'i32]   ## SQLITE_BUSY{,_RECOVERY,_SNAPSHOT}

proc classify*(e: ref FastOrmError): FastormOutcomeError =
  ## Classifies any FastORM exception. `DatabaseError`s are classified by
  ## SQLite's extended result code (set on the connection automatically),
  ## not by inspecting the message text.
  result.cause = e
  result.message = e.msg
  if e of ValidationError:
    result.kind = ekValidation
    result.issues = (ref ValidationError)(e).errors
  elif e of DatabaseError:
    let code = (ref DatabaseError)(e).sqliteCode
    result.kind =
      if code in uniqueOrPkCodes: ekUniqueViolation
      elif code in foreignKeyCodes: ekForeignKeyViolation
      elif code in notNullCodes: ekNotNullViolation
      elif code in checkCodes: ekCheckViolation
      elif code in busyCodes: ekBusy
      else: ekOther
  elif e of QueryError:
    result.kind = ekQuery
  else:
    result.kind = ekOther

proc isUniqueViolation*(e: FastormOutcomeError): bool {.inline.} = e.kind == ekUniqueViolation
proc isForeignKeyViolation*(e: FastormOutcomeError): bool {.inline.} = e.kind == ekForeignKeyViolation
proc isNotNullViolation*(e: FastormOutcomeError): bool {.inline.} = e.kind == ekNotNullViolation
proc isCheckViolation*(e: FastormOutcomeError): bool {.inline.} = e.kind == ekCheckViolation
proc isBusy*(e: FastormOutcomeError): bool {.inline.} = e.kind == ekBusy
  ## Another transaction held the write lock past the busy timeout. Retrying
  ## the whole transaction is usually the right response.
proc isValidation*(e: FastormOutcomeError): bool {.inline.} = e.kind == ekValidation

proc isOk*[T](r: FastormResult[T]): bool {.inline.} = r.ok
proc isErr*[T](r: FastormResult[T]): bool {.inline.} = not r.ok
proc isOk*(r: FastormVoidResult): bool {.inline.} = r.ok
proc isErr*(r: FastormVoidResult): bool {.inline.} = not r.ok

proc get*[T](r: FastormResult[T]): T =
  ## The value, or re-raises the original exception for an error result.
  if r.ok: r.value else: raise r.err.cause

proc valueOr*[T](r: FastormResult[T], default: T): T =
  if r.ok: r.value else: default

proc attempt*[T](fut: Future[T]): Future[FastormResult[T]] {.async.} =
  ## Awaits `fut`; turns a FastORM error into an err `FastormResult` instead
  ## of raising. Anything that isn't a `FastOrmError` (e.g. `CancelledError`,
  ## a `Defect`) still propagates normally — `attempt` only ever intercepts
  ## the errors FastORM itself documents, not every possible failure.
  try:
    let v = await fut
    return FastormResult[T](ok: true, value: v)
  except FastOrmError as e:
    return FastormResult[T](ok: false, err: classify(e))

proc raiseIfErr*(r: FastormVoidResult) =
  ## Re-raises the original exception if `r` is an error result; the `void`
  ## counterpart to `get()`.
  if not r.ok: raise r.err.cause

proc attempt*(fut: Future[void]): Future[FastormVoidResult] {.async.} =
  ## The `Future[void]` overload, for `save()`/`delete()`-style calls that
  ## have nothing to return on success.
  try:
    await fut
    return FastormVoidResult(ok: true)
  except FastOrmError as e:
    return FastormVoidResult(ok: false, err: classify(e))
