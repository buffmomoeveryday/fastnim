## Run with: nim c -r --path:src examples/websocket_broadcast.nim
import fastnim

let app = initFastNim()
let clients = newWebSocketGroup()

app.websocket("/chat"):
  await websocket.accept()
  {.gcsafe.}:
    clients.addWebSocket(websocket)
  try:
    while true:
      let message = await websocket.receiveText()
      {.gcsafe.}:
        discard await clients.broadcastText(message)
  finally:
    {.gcsafe.}:
      discard clients.removeWebSocket(websocket)

let server = app.serve(port = 8000)
echo "Connect multiple WebSocket clients to ws://127.0.0.1:8000/chat"
waitFor server.join()
