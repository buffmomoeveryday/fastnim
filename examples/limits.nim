## Request body, header, and handler limits.
##
## Run with: nim c -r --path:src examples/limits.nim

import fastnim
import json

let app = initFastNim(
  limits = initRequestLimits(
    maxBodySize = 1024 * 1024, maxHeaderCount = 40, handlerTimeout = 5.seconds
  )
)

type Message = object
  ok: bool
  message: string

app.get("/", responses = @[(200, Message)]):
  ok Message(ok: true, message: "Hello world")

app.post("/items"):
  ok Message(ok: true, message: $request.body.len)


let server = app.serve(port = 8091)
waitFor server.join()
