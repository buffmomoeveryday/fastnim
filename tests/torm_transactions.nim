import std/[os, tempfiles]
import chronos/unittest2/asynctests
import fastnim/orm

model Account:
  owner: CharField(maxLength: 50)
  balance: IntegerField(default: 0)

model Ledger:
  account: ForeignKey(Account, onDelete: Cascade)
  note: TextField()

proc freshDb(maxConnections = 4): Future[(Database, string)] {.async.} =
  let dir = createTempDir("fastorm_tx_", "_test")
  let db = await openDatabase(dir / "test.sqlite3", maxConnections = maxConnections)
  discard makeMigrations(dir / "migrations")
  discard await db.migrate(dir / "migrations")
  return (db, dir)

proc cleanup(db: Database, dir: string) {.async.} =
  await db.close()
  removeDir(dir)

proc account(owner: string, balance = 0): Future[Account] {.async.} =
  let a = Account(owner: owner, balance: balance)
  await a.save()
  return a

suite "transactions":
  asyncTest "a committed block persists every write":
    let (db, dir) = await freshDb()
    atomic db:
      let ada = Account(owner: "Ada", balance: 100)
      await ada.save(tx)
      let entry = Ledger(note: "opened")
      entry.account = ada
      await entry.save(tx)
    check (await Account.objects.count()) == 1
    check (await Ledger.objects.count()) == 1
    let ada = await Account.objects.get(owner = "Ada")
    check ada.get.balance == 100
    await cleanup(db, dir)

  asyncTest "atomic without a handle uses the default database":
    let (db, dir) = await freshDb()
    atomic:
      await Account(owner: "Ada").save(tx)
    check (await Account.objects.count()) == 1
    expect ValueError:
      atomic:
        await Account(owner: "Grace").save(tx)
        raise newException(ValueError, "boom")
    check (await Account.objects.count()) == 1
    await cleanup(db, dir)

  asyncTest "an exception rolls the whole block back":
    let (db, dir) = await freshDb()
    discard await account("Ada", 100)
    expect ValueError:
      atomic db:
        discard await Account.objects.withDb(tx).filter(owner = "Ada").update(balance = 0)
        await Account(owner: "Grace", balance: 5).save(tx)
        raise newException(ValueError, "boom")
    # Neither the update nor the insert survived.
    let ada = await Account.objects.get(owner = "Ada")
    check ada.get.balance == 100
    check (await Account.objects.count()) == 1
    await cleanup(db, dir)

  asyncTest "an explicit rollback undoes the block":
    let (db, dir) = await freshDb()
    let tx = await db.beginTransaction()
    await Account(owner: "Ada").save(tx)
    check (await Account.objects.withDb(tx).count()) == 1
    await tx.rollback()
    check (await Account.objects.count()) == 0
    check not tx.inTransaction
    await cleanup(db, dir)

  asyncTest "a nested block rolls back to its savepoint":
    let (db, dir) = await freshDb()
    atomic db:
      await Account(owner: "Ada").save(tx)
      expect ValueError:
        atomic tx:
          await Account(owner: "Grace").save(tx)
          raise newException(ValueError, "inner")
      # The inner savepoint went away; the outer transaction is still open
      # and its own write is intact.
      check tx.inTransaction
      check (await Account.objects.withDb(tx).count()) == 1
    check (await Account.objects.count()) == 1
    let ada = await Account.objects.get(owner = "Ada")
    check ada.isSome
    await cleanup(db, dir)

  asyncTest "a committed nested block keeps its writes":
    let (db, dir) = await freshDb()
    atomic db:
      await Account(owner: "Ada").save(tx)
      atomic tx:
        await Account(owner: "Grace").save(tx)
    check (await Account.objects.count()) == 2
    await cleanup(db, dir)

  asyncTest "a cancelled block rolls back":
    let (db, dir) = await freshDb()
    proc work() {.async.} =
      atomic db:
        await Account(owner: "Ada").save(tx)
        await sleepAsync(2.seconds)
        await Account(owner: "Grace").save(tx)
    let fut = work()
    await sleepAsync(50.milliseconds)
    await fut.cancelAndWait()
    check fut.cancelled
    check (await Account.objects.count()) == 0
    await cleanup(db, dir)

  asyncTest "the main connection keeps working while a transaction is open":
    let (db, dir) = await freshDb()
    discard await account("Ada", 100)
    let tx = await db.beginTransaction()
    await Account(owner: "Grace").save(tx)
    # A concurrent reader on the main connection sees the committed state,
    # not the transaction's uncommitted row, and does not block on it.
    check (await Account.objects.count()) == 1
    check (await Account.objects.withDb(tx).count()) == 2
    await tx.commit()
    check (await Account.objects.count()) == 2
    await cleanup(db, dir)

  asyncTest "transactions run one at a time and both commit":
    let (db, dir) = await freshDb()
    proc deposit(owner: string) {.async.} =
      atomic db:
        await Account(owner: owner, balance: 1).save(tx)
    var futs: seq[Future[void]]
    for i in 0 ..< 5: futs.add deposit("owner " & $i)
    await allFutures(futs)
    for f in futs: check f.completed
    check (await Account.objects.count()) == 5
    await cleanup(db, dir)

  asyncTest "transaction control statements are not counted as queries":
    let (db, dir) = await freshDb()
    let mark = db.operationCount
    atomic db:
      await Account(owner: "Ada").save(tx)
    # Exactly one statement: the INSERT. BEGIN and COMMIT are not queries.
    check db.operationCount == mark + 1
    await cleanup(db, dir)

  asyncTest "selectForUpdate needs an open transaction":
    let (db, dir) = await freshDb()
    discard await account("Ada", 100)
    expect QueryError:
      discard await Account.objects.selectForUpdate().all()
    atomic db:
      let locked = await Account.objects.withDb(tx).selectForUpdate().all()
      check locked.len == 1
      locked[0].balance = 50
      await locked[0].save(tx)
    let ada = await Account.objects.get(owner = "Ada")
    check ada.get.balance == 50
    await cleanup(db, dir)

  asyncTest "a finished transaction cannot be reused":
    let (db, dir) = await freshDb()
    let tx = await db.beginTransaction()
    await tx.commit()
    expect DatabaseError:
      await tx.commit()
    # rollback after the fact is a no-op, so error paths stay safe.
    await tx.rollback()
    expect DatabaseError:
      discard await tx.beginTransaction()
    await cleanup(db, dir)

  asyncTest "commit and rollback reject a plain handle":
    let (db, dir) = await freshDb()
    expect DatabaseError:
      await db.commit()
    expect DatabaseError:
      await db.rollback()
    await cleanup(db, dir)

  asyncTest "a batch inside a transaction nests as a savepoint":
    let (db, dir) = await freshDb()
    atomic db:
      await Account(owner: "Ada").save(tx)
      expect DatabaseError:
        await tx.batch(@[
          Statement(sql: "INSERT INTO account (owner, balance) VALUES ('Grace', 1)"),
          Statement(sql: "INSERT INTO nope (x) VALUES (1)")])
      # The failed batch rolled back to its savepoint, not past it.
      check tx.inTransaction
      check (await Account.objects.withDb(tx).count()) == 1
    check (await Account.objects.count()) == 1
    await cleanup(db, dir)

  asyncTest "connections are reused across transactions":
    let (db, dir) = await freshDb(maxConnections = 2)
    for i in 0 ..< 4:
      atomic db:
        await Account(owner: "owner " & $i).save(tx)
    check (await Account.objects.count()) == 4
    await cleanup(db, dir)

  asyncTest "an in-memory database serializes transactions on one connection":
    let dir = createTempDir("fastorm_mem_", "_test")
    let db = await openDatabase(":memory:")
    discard makeMigrations(dir / "migrations")
    discard await db.migrate(dir / "migrations")
    atomic db:
      await Account(owner: "Ada").save(tx)
    check (await Account.objects.count()) == 1
    expect ValueError:
      atomic db:
        await Account(owner: "Grace").save(tx)
        raise newException(ValueError, "boom")
    check (await Account.objects.count()) == 1
    await db.close()
    removeDir(dir)

  when defined(fastormStrictTx):
    asyncTest "strict mode rejects a write that skips the transaction":
      let (db, dir) = await freshDb()
      let tx = await db.beginTransaction()
      expect DatabaseError:
        # No `tx`, so this would quietly go to the main connection.
        await Account(owner: "Ada").save()
      # Reads on the main connection are still fine.
      check (await Account.objects.count()) == 0
      await tx.rollback()
      await cleanup(db, dir)

  asyncTest "closing rolls an open transaction back":
    let dir = createTempDir("fastorm_tx_", "_test")
    let path = dir / "test.sqlite3"
    block:
      let db = await openDatabase(path)
      discard makeMigrations(dir / "migrations")
      discard await db.migrate(dir / "migrations")
      let tx = await db.beginTransaction()
      await Account(owner: "Ada").save(tx)
      await db.close()
    let again = await openDatabase(path)
    check (await Account.objects.count()) == 0
    await again.close()
    removeDir(dir)
