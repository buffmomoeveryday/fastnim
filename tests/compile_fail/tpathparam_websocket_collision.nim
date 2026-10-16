import fastnim

let app = initFastNim()
app.websocket("/socket/{websocket:int}"):
  discard websocket
