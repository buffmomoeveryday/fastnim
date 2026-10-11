import std/unittest
import fastnim

type Database = ref object of RootObj
  value: string

type Settings = object
  retries: int

type DeclarativeDependencies = object
  db: Database
  settings: Settings

var events: seq[string]

proc loadDatabase(ctx: Context) =
  events.add("load")
  ctx.setContext("db", Database(value: "ready"))

proc unloadDatabase(ctx: Context) =
  check ctx.get("db", Database) != nil
  events.add("unload")

proc provideDatabase(): Database =
  events.add("provide")
  Database(value: "declarative")

proc cleanupDatabase(database: Database) =
  events.add("cleanup:" & database.value)

suite "application lifecycle":
  test "loads dependencies and exposes them through typed lookup":
    events = @[]
    let app = initFastNim(logs = false)
    app.onLoad(loadDatabase)
    app.onUnload(unloadDatabase)
    app.load()
    app.load()

    app.get("/health"):
      if ctx.get("db", Database) != nil: "ready" else: "missing"

    check app.handle(initRequest(HttpMethod.Get, "/health")).body == "ready"
    app.unload()
    app.unload()
    check events == @["load", "unload"]

  test "stores value-typed dependencies":
    let ctx = newContext()
    ctx.setContext("settings", Settings(retries: 3))

    check ctx.get("settings", Settings).retries == 3

  test "rejects lookup with the wrong type":
    let ctx = newContext()
    ctx.setContext("settings", Settings(retries: 3))

    expect ValueError:
      discard ctx.get("settings", string)

  test "declares typed dependencies for route blocks":
    events = @[]
    let app = initFastNim(logs = false)
    app.dependencies(DeclarativeDependencies):
      provide db: provideDatabase()
      cleanup db: cleanupDatabase(db)
      provide settings: Settings(retries: 4)

    app.get("/dependency"):
      let database = ctx.get("db")
      let settings = ctx.get("settings")
      database.value & ":" & $settings.retries

    app.load()
    check app.handle(initRequest(HttpMethod.Get, "/dependency")).body == "declarative:4"
    app.unload()
    check events == @["provide", "cleanup:declarative"]

