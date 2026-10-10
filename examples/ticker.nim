## Run with: nim c -r --path:src examples/ticker.nim

import chronos
import std/[json, strutils]

import fastnim

let app = initFastNim()

app.get("/"):
  text("Connect an EventSource to /ticker/FASTNIM")

app.sse("/ticker/{symbol}"):
  let symbol = request.pathParam("symbol").toUpperAscii()
  for i in 1 .. 10:
    let price = 101.25 + i.float / 10
    await send(
      sseEvent(
        $(%*{"symbol": symbol, "price": price}), event = "price", id = $i, retry = 3000
      )
    )
    if i < 10:
      await sleepAsync(1.seconds)

let server = app.serve(port = 8000)
echo "Ticker endpoint: http://127.0.0.1:8000/ticker/FASTNIM"
waitFor server.join()
