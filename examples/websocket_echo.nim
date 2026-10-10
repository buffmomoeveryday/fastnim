## Run with: nim c -r --path:src examples/websocket_echo.nim

import chronos

import fastnim
import json

let app = initFastNim()

app.websocket("/echo"):
  await websocket.accept()
  while true:
    let text = await websocket.receiveText()
    await websocket.sendText text

let server = app.serve(port = 8009)
echo "WebSocket echo endpoint: ws://127.0.0.1:8000/echo"
waitFor server.join()
