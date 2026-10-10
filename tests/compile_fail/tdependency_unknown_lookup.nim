import fastnim

type Dependencies = object
  db: string

let app = initFastNim()
app.dependencies(Dependencies):
  provide db: "ready"

app.get("/"):
  ctx.get("cache")
