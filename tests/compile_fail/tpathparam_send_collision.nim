import fastnim

let app = initFastNim()
app.sse("/events/{send:int}"):
  discard send
