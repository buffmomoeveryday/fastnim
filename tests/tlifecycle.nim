import std/unittest
import fastnim

type Database = ref object of RootObj
  value: string

var events: seq[string]

proc loadDatabase(ctx: Context) =
  events.add("load")
  ctx.setContext("db", Database(value: "ready"))

proc unloadDatabase(ctx: Context) =
  check ctx.db != nil
  events.add("unload")

suite "application lifecycle":
  test "loads dependencies and exposes them as ctx.db":
    events = @[]
    let app = initFastNim(logs = false)
    app.onLoad(loadDatabase)
    app.onUnload(unloadDatabase)
    app.load()
    app.load()

    app.get("/health"):
      if ctx.db != nil: "ready" else: "missing"

    check app.handle(initRequest(HttpMethod.Get, "/health")).body == "ready"
    app.unload()
    app.unload()
    check events == @["load", "unload"]

