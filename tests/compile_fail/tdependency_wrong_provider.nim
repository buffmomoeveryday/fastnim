import fastnim

type Dependencies = object
  retries: int

let app = initFastNim()
app.dependencies(Dependencies):
  provide retries: "wrong"
