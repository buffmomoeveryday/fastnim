import fastnim

let app = initFastNim()
app.get("/items/{request:int}"):
  text($request)
