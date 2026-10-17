import fastnim

type Payload = object
  value: string

let app = initFastNim()
app.post("/items/{body:int}", body = Payload, responses = @[(200, void)]):
  ok void
