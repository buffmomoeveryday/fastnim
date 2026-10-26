## Chronos-facing SQLite connections.
##
## SQLite's C API is blocking, so every connection lives on a dedicated
## worker thread. Requests are sent over a channel and processed one at a
## time; the worker fires a per-request `ThreadSignalPtr` when the response
## is ready, which completes the awaiting Chronos future. Callers never
## block the event loop and a connection is never used from two threads at
## once.
##
## A `Database` is a *handle* onto a pool of such connections. The base
## handle always talks to the pool's main connection; `beginTransaction`
## (and the `atomic` template) leases a separate connection for the duration
## of a transaction, so an open transaction never swallows statements issued
## concurrently by other tasks.

import std/[tables, strutils]
import chronos, chronos/threadsync
import chronos/asyncsync
import db_connector/sqlite3
import ./values

# `db_connector/sqlite3` doesn't bind `sqlite3_extended_errcode` /
# `sqlite3_extended_result_codes` / `sqlite3_get_autocommit`, so declare them
# ourselves against the same library it already links (statically when
# `-d:staticSqlite`, otherwise dynamically, mirroring that module's own
# platform selection).
when defined(staticSqlite):
  {.pragma: sqlite3lib.}
else:
  when defined(windows):
    when defined(nimOldDlls):
      const sqlite3Lib = "sqlite3.dll"
    elif defined(cpu64):
      const sqlite3Lib = "sqlite3_64.dll"
    else:
      const sqlite3Lib = "sqlite3_32.dll"
  elif defined(macosx):
    const sqlite3Lib = "libsqlite3(|.0).dylib"
  else:
    const sqlite3Lib = "libsqlite3.so(|.0)"
  {.pragma: sqlite3lib, dynlib: sqlite3Lib.}

proc extendedErrcode(
  conn: PSqlite3
): int32 {.cdecl, sqlite3lib, importc: "sqlite3_extended_errcode".}

proc extendedResultCodes(
  conn: PSqlite3, onoff: int32
): int32 {.cdecl, sqlite3lib, importc: "sqlite3_extended_result_codes".}

proc getAutocommit(
  conn: PSqlite3
): int32 {.cdecl, sqlite3lib, importc: "sqlite3_get_autocommit".}

type
  Statement* = object
    sql*: string
    params*: seq[DbValue]

  ExecResult* = object
    changes*: int64
    lastInsertId*: int64

  QueryResult* = object
    columns*: seq[string]
    rows*: seq[seq[DbValue]]

  RequestKind = enum
    rkExec
    rkQuery
    rkBatch
    rkClose

  Request = object
    id: int
    kind: RequestKind
    stmts: seq[Statement]
    savepoint: string ## non-empty: `rkBatch` uses SAVEPOINT, not BEGIN
    signal: ThreadSignalPtr

  Response = object
    id: int
    ok: bool
    error: string
    errorCode: int32 ## SQLite extended result code for `error`, or 0
    columns: seq[string]
    rows: seq[seq[DbValue]]
    changes: int64
    lastInsertId: int64
    inTransaction: bool ## the connection had an open transaction afterwards

  WorkerArgs = object
    path: string
    requests: ptr Channel[Request]
    responses: ptr Channel[Response]
    ready: ThreadSignalPtr

  Connection = ref object ## One worker thread holding one SQLite connection.
    thread: Thread[WorkerArgs]
    requests: ptr Channel[Request]
    responses: ptr Channel[Response]
    pending: Table[int, Response]
    nextId: int
    closed: bool
    inTx: bool ## last transaction state the worker reported

  Pool = ref object ## Every connection to one database file, shared by all its handles.
    path: string
    main: Connection
    all: seq[Connection]
    idle: seq[Connection]
    slots: AsyncSemaphore ## caps the number of concurrent transactions
    shared: bool ## false when extra connections see another database
    mainLock: AsyncLock ## serializes transactions when `shared` is false
    txOpen: int
    ops: int ## statements handed to a worker
    closed: bool

  Database* = ref object
    ## A handle onto a connection pool. `pinned` is set only on the handle
    ## `beginTransaction` returns, which routes every statement to the one
    ## connection holding the transaction.
    path*: string
    pool: Pool
    pinned: Connection
    depth: int ## 0 for the outermost transaction, >0 for a savepoint
    finished: bool

proc operationCount*(db: Database): int =
  ## How many statements have been submitted on this database, including
  ## ones that failed, across every connection in its pool. Transaction
  ## control statements (`BEGIN`, `COMMIT`, `SAVEPOINT`, ...) are not
  ## counted, so the number still reflects the queries a request ran.
  db.pool.ops

proc inTransaction*(db: Database): bool =
  ## Whether `db` is a transaction handle with an unfinished transaction.
  db.pinned != nil and not db.finished

var defaultDb {.threadvar.}: Database

proc setDefaultDatabase*(db: Database) =
  defaultDb = db

proc defaultDatabase*(): Database {.raises: [DatabaseError].} =
  if defaultDb.isNil:
    raise newException(
      DatabaseError,
      "no default database; call openDatabase(path) or setDefaultDatabase(db) first",
    )
  defaultDb

proc resolveDb*(db: Database): Database {.raises: [DatabaseError].} =
  if db.isNil:
    defaultDatabase()
  else:
    db

# -- worker thread -----------------------------------------------------------

proc lastError(conn: PSqlite3): string =
  $errmsg(conn)

proc dbError(conn: PSqlite3, msg: string): ref DatabaseError =
  ## Builds a `DatabaseError` tagged with SQLite's extended result code for
  ## the connection's last failure (e.g. `SQLITE_CONSTRAINT_UNIQUE`), so
  ## callers can classify the failure without parsing `msg`.
  result = newException(DatabaseError, msg)
  result.sqliteCode = extendedErrcode(conn)

proc bindParams(
    conn: PSqlite3, stmt: PStmt, params: seq[DbValue]
) {.raises: [DatabaseError].} =
  for i, p in params:
    let idx = int32(i + 1)
    let rc =
      case p.kind
      of dvNull:
        bind_null(stmt, idx)
      of dvInt:
        bind_int64(stmt, idx, p.i)
      of dvFloat:
        bind_double(stmt, idx, p.f)
      of dvText:
        bind_text(stmt, idx, p.s.cstring, int32(p.s.len), SQLITE_TRANSIENT)
      of dvBlob:
        bind_blob(
          stmt,
          idx,
          (if p.b.len > 0: p.b[0].unsafeAddr else: nil),
          int32(p.b.len),
          SQLITE_TRANSIENT,
        )
    if rc != SQLITE_OK:
      raise dbError(conn, "bind failed: " & lastError(conn))

proc readColumn(stmt: PStmt, col: int32): DbValue =
  case column_type(stmt, col)
  of SQLITE_INTEGER:
    DbValue(kind: dvInt, i: column_int64(stmt, col))
  of SQLITE_FLOAT:
    DbValue(kind: dvFloat, f: column_double(stmt, col))
  of SQLITE_TEXT:
    DbValue(kind: dvText, s: $column_text(stmt, col))
  of SQLITE_BLOB:
    let n = column_bytes(stmt, col)
    var bytes = newSeq[byte](n)
    if n > 0:
      copyMem(bytes[0].addr, column_blob(stmt, col), n)
    DbValue(kind: dvBlob, b: bytes)
  else:
    DbValue(kind: dvNull)

proc run(
    conn: PSqlite3, s: Statement, resp: var Response, collect: bool
) {.raises: [DatabaseError].} =
  var stmt: PStmt
  if prepare_v2(conn, s.sql.cstring, int32(s.sql.len), stmt, nil) != SQLITE_OK:
    raise dbError(conn, lastError(conn) & " in: " & s.sql)
  try:
    bindParams(conn, stmt, s.params)
    if collect:
      let n = column_count(stmt)
      resp.columns.setLen(0)
      for c in 0'i32 ..< n:
        resp.columns.add $column_name(stmt, c)
    while true:
      let rc = step(stmt)
      if rc == SQLITE_ROW:
        if collect:
          var row = newSeq[DbValue](resp.columns.len)
          for c in 0 ..< resp.columns.len:
            row[c] = readColumn(stmt, int32(c))
          resp.rows.add row
      elif rc == SQLITE_DONE:
        break
      else:
        raise dbError(conn, lastError(conn) & " in: " & s.sql)
    resp.changes = changes(conn)
    resp.lastInsertId = last_insert_rowid(conn)
  finally:
    discard finalize(stmt)

proc execRaw(conn: PSqlite3, sql: string) {.raises: [DatabaseError].} =
  var resp: Response
  run(conn, Statement(sql: sql), resp, false)

proc handle(conn: PSqlite3, req: Request): Response =
  result = Response(id: req.id, ok: true)
  try:
    case req.kind
    of rkExec:
      run(conn, req.stmts[0], result, false)
    of rkQuery:
      run(conn, req.stmts[0], result, true)
    of rkBatch:
      # Inside a transaction the batch nests as a savepoint, since SQLite
      # has no nested BEGIN.
      let nested = req.savepoint.len > 0
      let opening =
        if nested:
          "SAVEPOINT " & req.savepoint
        else:
          "BEGIN IMMEDIATE"
      let closing =
        if nested:
          "RELEASE " & req.savepoint
        else:
          "COMMIT"
      let undo =
        if nested:
          @["ROLLBACK TO " & req.savepoint, "RELEASE " & req.savepoint]
        else:
          @["ROLLBACK"]
      execRaw(conn, opening)
      try:
        var scratch: Response
        for s in req.stmts:
          run(conn, s, scratch, false)
        execRaw(conn, closing)
      except DatabaseError as e:
        for sql in undo:
          try:
            execRaw(conn, sql)
          except DatabaseError:
            discard
        raise e
    of rkClose:
      discard
  except DatabaseError as e:
    result.ok = false
    result.error = e.msg
    result.errorCode = e.sqliteCode
  result.inTransaction = getAutocommit(conn) == 0

proc worker(args: WorkerArgs) {.thread.} =
  var conn: PSqlite3
  var opened = Response(id: 0, ok: true)
  if open(args.path.cstring, conn) != SQLITE_OK:
    opened.ok = false
    opened.error = "unable to open " & args.path & ": " & lastError(conn)
  else:
    discard extendedResultCodes(conn, 1)
    discard busy_timeout(conn, 5000)
    try:
      execRaw(conn, "PRAGMA foreign_keys = ON")
      # WAL lets readers on other connections keep working while a
      # transaction holds the write lock. It is a no-op (and harmless) for
      # in-memory and temporary databases.
      execRaw(conn, "PRAGMA journal_mode = WAL")
    except DatabaseError as e:
      opened.ok = false
      opened.error = e.msg
  args.responses[].send(opened)
  discard args.ready.fireSync()
  if not opened.ok:
    discard close(conn)
    return
  while true:
    let req = args.requests[].recv()
    let resp = handle(conn, req)
    args.responses[].send(resp)
    discard req.signal.fireSync()
    if req.kind == rkClose:
      discard close(conn)
      break

# -- event-loop side ---------------------------------------------------------

proc newSignal(): ThreadSignalPtr {.raises: [DatabaseError].} =
  let s = ThreadSignalPtr.new()
  if s.isErr:
    raise newException(DatabaseError, "cannot create thread signal: " & s.error)
  s.get

proc drain(conn: Connection) =
  while true:
    let (ok, resp) = conn.responses[].tryRecv()
    if not ok:
      break
    conn.pending[resp.id] = resp

proc freeChannels(conn: Connection) =
  conn.requests[].close()
  conn.responses[].close()
  deallocShared(conn.requests)
  deallocShared(conn.responses)

proc send(
    conn: Connection, kind: RequestKind, stmts: seq[Statement], savepoint = ""
): Future[Response] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Hands one request to `conn`'s worker and waits for its response.
  if conn.closed:
    raise newException(DatabaseError, "the database connection is closed")
  let signal = newSignal()
  inc conn.nextId
  let id = conn.nextId
  conn.requests[].send(
    Request(id: id, kind: kind, stmts: stmts, savepoint: savepoint, signal: signal)
  )
  try:
    # The worker always fires the signal, so this wait must not be cancelled
    # or the signal would be closed while still in use.
    await noCancel signal.wait()
  except AsyncError as e:
    raise newException(DatabaseError, "waiting for SQLite worker failed: " & e.msg)
  finally:
    discard signal.close()
  conn.drain()
  var resp: Response
  if not conn.pending.pop(id, resp):
    raise newException(DatabaseError, "SQLite worker returned no response")
  conn.inTx = resp.inTransaction
  if not resp.ok:
    let e = newException(DatabaseError, resp.error)
    e.sqliteCode = resp.errorCode
    raise e
  resp

proc target(db: Database): Connection =
  if db.pinned != nil: db.pinned else: db.pool.main

proc submit(
    db: Database, kind: RequestKind, stmts: seq[Statement], savepoint = ""
): Future[Response] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## A counted statement: one of the queries the caller asked for.
  if db.pool.closed:
    raise newException(DatabaseError, "database " & db.path & " is closed")
  when defined(fastormStrictTx):
    if db.pinned.isNil and db.pool.txOpen > 0 and kind != rkQuery:
      raise newException(
        DatabaseError,
        "fastormStrictTx: a write went to the main connection while a " &
          "transaction is open on " & db.path & ". Pass the `tx` handle " &
          "(`save(tx)`, `objects.withDb(tx)`) so it joins the transaction",
      )
  inc db.pool.ops
  await db.target.send(kind, stmts, savepoint)

proc control(
    db: Database, sql: string
): Future[void] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## A transaction control statement. Not counted in `operationCount`, which
  ## is there to spot extra *queries*.
  discard await db.target.send(rkExec, @[Statement(sql: sql)])

# -- pool --------------------------------------------------------------------

proc openConnection(
    path: string
): Future[Connection] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Spawns a worker thread holding a new connection to `path`.
  let conn = Connection()
  conn.requests = cast[ptr Channel[Request]](allocShared0(sizeof(Channel[Request])))
  conn.responses = cast[ptr Channel[Response]](allocShared0(sizeof(Channel[Response])))
  conn.requests[].open()
  conn.responses[].open()
  let ready = newSignal()
  try:
    createThread(
      conn.thread,
      worker,
      WorkerArgs(
        path: path, requests: conn.requests, responses: conn.responses, ready: ready
      ),
    )
  except ResourceExhaustedError as e:
    discard ready.close()
    conn.freeChannels()
    raise newException(DatabaseError, "cannot start SQLite worker: " & e.msg)
  try:
    await noCancel ready.wait()
  except AsyncError as e:
    raise newException(DatabaseError, "waiting for SQLite worker failed: " & e.msg)
  finally:
    discard ready.close()
  let (_, opened) = conn.responses[].tryRecv()
  if not opened.ok:
    joinThread(conn.thread)
    conn.freeChannels()
    raise newException(DatabaseError, opened.error)
  conn

proc closeConnection(
    conn: Connection
) {.async: (raises: [DatabaseError, CancelledError]).} =
  if conn.closed:
    return
  discard await conn.send(rkClose, @[])
  conn.closed = true
  joinThread(conn.thread)
  conn.freeChannels()

proc isPrivate(path: string): bool =
  ## Whether a second connection to `path` would see a *different* database.
  ## Each `:memory:` (and each temporary) connection gets its own, so those
  ## pools cannot hand a transaction a connection of its own.
  if path.len == 0 or path == ":memory:":
    return true
  if path.startsWith("file:") and "mode=memory" in path:
    return "cache=shared" notin path
  false

proc lease(
    pool: Pool
): Future[Connection] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## A connection to run a transaction on. For a private database there is
  ## only one, so transactions queue on `mainLock` instead.
  if not pool.shared:
    await pool.mainLock.acquire()
    return pool.main
  await pool.slots.acquire()
  try:
    if pool.idle.len > 0:
      return pool.idle.pop()
    let conn = await openConnection(pool.path)
    pool.all.add conn
    return conn
  except DatabaseError as e:
    try:
      pool.slots.release()
    except AsyncSemaphoreError:
      discard
    raise e
  except CancelledError as e:
    try:
      pool.slots.release()
    except AsyncSemaphoreError:
      discard
    raise e

proc unlease(pool: Pool, conn: Connection) {.async: (raises: [CancelledError]).} =
  ## Returns a connection to the pool, dropping it if it is in an unknown
  ## state (a transaction the worker could not roll back).
  if not pool.shared:
    try:
      pool.mainLock.release()
    except AsyncLockError:
      discard
    return
  if conn.closed or conn.inTx:
    try:
      await closeConnection(conn)
    except DatabaseError:
      discard
    conn.closed = true
    let i = pool.all.find(conn)
    if i >= 0:
      pool.all.delete(i)
  else:
    pool.idle.add conn
  try:
    pool.slots.release()
  except AsyncSemaphoreError:
    discard

proc openDatabase*(
    path: string, setDefault = true, maxConnections = 4
): Future[Database] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Opens (creating if needed) the SQLite database at `path`. Use
  ## `":memory:"` for a private in-memory database. By default the connection
  ## also becomes the default database used by `Model.objects` and `save`.
  ##
  ## `maxConnections` caps how many connections the pool may open. The first
  ## is the main connection every non-transactional statement uses; the rest
  ## are leased one at a time by `atomic` / `beginTransaction`, so at most
  ## `maxConnections - 1` transactions run at once. A `":memory:"` database
  ## is private to its connection, so its pool always has exactly one and
  ## transactions on it are serialized instead.
  if maxConnections < 1:
    raise newException(DatabaseError, "maxConnections must be at least 1")
  let shared = not isPrivate(path)
  let pool = Pool(
    path: path,
    shared: shared,
    slots: newAsyncSemaphore(max(1, maxConnections - 1)),
    mainLock: newAsyncLock(),
  )
  pool.main = await openConnection(path)
  pool.all.add pool.main
  let db = Database(path: path, pool: pool)
  if setDefault:
    setDefaultDatabase(db)
  db

proc close*(
    db: Database
): Future[void] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Closes every connection in the pool. An open transaction is rolled back.
  let pool = db.pool
  if pool.closed:
    return
  pool.closed = true
  pool.idle.setLen(0)
  let conns = pool.all
  pool.all.setLen(0)
  for conn in conns:
    if conn.closed:
      continue
    if conn.inTx:
      try:
        discard await conn.send(rkExec, @[Statement(sql: "ROLLBACK")])
      except DatabaseError:
        discard
    try:
      await closeConnection(conn)
    except DatabaseError:
      discard
    conn.closed = true
  if defaultDb != nil and defaultDb.pool == pool:
    defaultDb = nil

proc execute*(
    db: Database, sql: string, params: seq[DbValue] = @[]
): Future[ExecResult] {.async: (raises: [DatabaseError, CancelledError]).} =
  let resp = await db.submit(rkExec, @[Statement(sql: sql, params: params)])
  ExecResult(changes: resp.changes, lastInsertId: resp.lastInsertId)

proc query*(
    db: Database, sql: string, params: seq[DbValue] = @[]
): Future[QueryResult] {.async: (raises: [DatabaseError, CancelledError]).} =
  let resp = await db.submit(rkQuery, @[Statement(sql: sql, params: params)])
  QueryResult(columns: resp.columns, rows: resp.rows)

proc quoteIdent*(name: string): string =
  '"' & name.replace("\"", "\"\"") & '"'

proc savepointName(depth: int): string =
  quoteIdent("fastorm_sp" & $depth)

proc batch*(
    db: Database, stmts: seq[Statement]
): Future[void] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Runs all statements inside a single transaction; any failure rolls the
  ## whole batch back. On a transaction handle it nests as a savepoint, so
  ## only the batch is undone and the surrounding transaction stays open.
  let savepoint =
    if db.pinned != nil:
      quoteIdent("fastorm_batch" & $(db.depth + 1))
    else:
      ""
  discard await db.submit(rkBatch, stmts, savepoint)

# -- transactions ------------------------------------------------------------

proc beginTransaction*(
    db: Database
): Future[Database] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Opens a transaction and returns the handle to run its statements on:
  ## `await author.save(tx)`, `Author.objects.withDb(tx)`. Finish it with
  ## `commit` or `rollback` — the `atomic` template does that for you.
  ##
  ## On a handle that is already in a transaction this nests as a savepoint,
  ## so rolling the inner one back leaves the outer one open.
  if db.pool.closed:
    raise newException(DatabaseError, "database " & db.path & " is closed")
  if db.pinned != nil:
    if db.finished:
      raise newException(DatabaseError, "this transaction has already finished")
    let tx =
      Database(path: db.path, pool: db.pool, pinned: db.pinned, depth: db.depth + 1)
    await tx.control("SAVEPOINT " & savepointName(tx.depth))
    return tx
  let conn = await db.pool.lease()
  let tx = Database(path: db.path, pool: db.pool, pinned: conn)
  try:
    # IMMEDIATE takes the write lock up front, so a transaction cannot fail
    # partway through on a lock upgrade, and the rows it reads are the rows
    # it may write (which is what `selectForUpdate` relies on).
    await tx.control("BEGIN IMMEDIATE")
  except DatabaseError as e:
    await db.pool.unlease(conn)
    raise e
  except CancelledError as e:
    await db.pool.unlease(conn)
    raise e
  inc db.pool.txOpen
  tx

proc finish(
    tx: Database, commit: bool
): Future[void] {.async: (raises: [DatabaseError, CancelledError]).} =
  let conn = tx.pinned
  tx.finished = true
  var failure: ref DatabaseError
  if tx.depth > 0:
    let name = savepointName(tx.depth)
    if conn.inTx:
      try:
        if commit:
          await tx.control("RELEASE " & name)
        else:
          await tx.control("ROLLBACK TO " & name)
          await tx.control("RELEASE " & name)
      except DatabaseError as e:
        failure = e
    if failure != nil:
      raise failure
    return
  if conn.inTx:
    try:
      await tx.control(if commit: "COMMIT" else: "ROLLBACK")
    except DatabaseError as e:
      failure = e
  if failure != nil and conn.inTx:
    # A failed COMMIT (a deferred constraint, say) leaves the transaction
    # open; undo it so the connection can go back into the pool.
    try:
      await tx.control("ROLLBACK")
    except DatabaseError:
      discard
  dec tx.pool.txOpen
  await tx.pool.unlease(conn)
  if failure != nil:
    raise failure

proc commit*(
    tx: Database
): Future[void] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Commits the transaction (or releases the savepoint, when nested) and
  ## returns its connection to the pool.
  if tx.pinned.isNil:
    raise newException(DatabaseError, "commit on a handle that is not a transaction")
  if tx.finished:
    raise newException(DatabaseError, "this transaction has already finished")
  await tx.finish(commit = true)

proc rollback*(
    tx: Database
): Future[void] {.async: (raises: [DatabaseError, CancelledError]).} =
  ## Undoes everything the transaction did (or everything since the
  ## savepoint, when nested). Does nothing if it has already finished, so it
  ## is safe to call on an error path after a failed `commit`.
  if tx.pinned.isNil:
    raise newException(DatabaseError, "rollback on a handle that is not a transaction")
  if tx.finished:
    return
  await tx.finish(commit = false)

template atomic*(db, body: untyped) =
  ## Runs `body` in a transaction on the `Database` `db`, committing when it finishes and
  ## rolling back if it raises or is cancelled. The transaction handle is
  ## injected as `tx`; pass it to everything that should take part:
  ##
  ## ```nim
  ## atomic db:
  ##   await author.save(tx)
  ##   discard await Article.objects.withDb(tx).filter(views < 0).update(views = 0)
  ## ```
  ##
  ## Nests: an `atomic tx:` inside the body becomes a savepoint. Statements
  ## that *don't* take `tx` run on the main connection, outside the
  ## transaction — build with `-d:fastormStrictTx` to have those raise.
  block:
    # A body ending in `raise` or `return` makes the commit below
    # unreachable, which is fine and not worth a warning at every call site.
    {.push warning[UnreachableCode]: off.}
    let tx {.inject.} = await beginTransaction(db)
    try:
      body
      await tx.commit()
    except CancelledError as e:
      try:
        await noCancel tx.rollback()
      except CatchableError:
        discard
      raise e
    except CatchableError as e:
      try:
        await noCancel tx.rollback()
      except CatchableError:
        discard
      raise e
    {.pop.}

template atomic*(body: untyped) =
  ## `atomic` on the default database.
  ##
  ## Spelled out rather than delegating to the two-argument `atomic`: a
  ## symbol injected by a nested template expansion is not visible to a
  ## body passed down from the outer one. For the same reason the other
  ## overload takes `db` as `untyped` — overloading an injecting template on
  ## a *typed* first parameter stops this arity from resolving at all.
  block:
    {.push warning[UnreachableCode]: off.}
    let tx {.inject.} = await beginTransaction(defaultDatabase())
    try:
      body
      await tx.commit()
    except CancelledError as e:
      try:
        await noCancel tx.rollback()
      except CatchableError:
        discard
      raise e
    except CatchableError as e:
      try:
        await noCancel tx.rollback()
      except CatchableError:
        discard
      raise e
    {.pop.}
