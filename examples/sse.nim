## Run with: nim c -r --path:src examples/sse.nim

import chronos

import fastnim

let app = initFastNim()

app.get("/"):
  text("Connect an EventSource to /events")

app.sse("/events"):
  await send(sseEvent("connected", event = "status", id = "1", retry = 3000))
  await send(sseEvent("fastnim is ready", event = "message", id = "2"))

let server = app.serve(port = 8000)
echo "SSE endpoint: http://127.0.0.1:8000/events"
waitFor server.join()
