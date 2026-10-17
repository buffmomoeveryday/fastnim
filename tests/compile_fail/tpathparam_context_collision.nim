import fastnim

let app = initFastNim()
app.get("/items/{c_tx:int}"):
  text($c_tx)
