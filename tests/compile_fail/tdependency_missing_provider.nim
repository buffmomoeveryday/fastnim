import fastnim

type Dependencies = object
  db: string

let app = initFastNim()
app.dependencies(Dependencies):
  cleanup db:
    discard db
