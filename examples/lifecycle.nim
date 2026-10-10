## Run with: nim c -r --path:src examples/lifecycle.nim
import fastnim



type Database = ref object of RootObj
  connectionString: string
  closed: bool

proc loadDatabase(ctx: Context) =
  echo "opening database connection"
  ctx.setContext("db", Database(connectionString: "sqlite://app.db"))

proc unloadDatabase(ctx: Context) =
  let database = Database(ctx.db)
  database.closed = true
  echo "closed database connection to ", database.connectionString

let app = initFastNim()
app.onLoad(loadDatabase)
app.onUnload(unloadDatabase)

app.get("/health"):
  if ctx.db == nil: "database unavailable" else: "database ready"

let server = app.serve(port = 8000)
echo "Listening at http://127.0.0.1:8000"
try:
  waitFor server.join()
finally:
  waitFor app.stop(server)
