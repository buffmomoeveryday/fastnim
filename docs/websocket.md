# WebSockets

FastNim WebSocket routes run on the Chronos HTTP server and use nim-websock for
framing. The adapter completes the HTTP upgrade before invoking the route. The
handler must call `websocket.accept()` before sending or receiving messages.

## Echo server

```nim
import chronos
import fastnim

let app = initFastNim()

app.websocket("/echo"):
  await websocket.accept()
  while true:
    await websocket.sendText(await websocket.receiveText())

let server = app.serve(port = 8009)
waitFor server.join()
```

Run the complete example with:

```text
nim c -r examples/websocket_echo.nim
```

Then connect to `ws://127.0.0.1:8009/echo`. Route paths support the same path
parameters as HTTP routes, available through `request.pathParam`.

## Text, binary, and JSON messages

The connection API provides matching send and receive operations:

| Payload | Receive | Send |
| --- | --- | --- |
| UTF-8 text | `receiveText()` | `sendText(value)` |
| Bytes | `receiveBytes()` | `sendBytes(value)` |
| Typed JSON | `receiveJson(T)` | `sendJson(value)` |

`sendJson` and `receiveJson` use FastNim's JSON field metadata, including
`jsonName`. A typed JSON loop can be written as:

```nim
type ChatMessage = object
  text: string

app.websocket("/json"):
  await websocket.accept()
  while true:
    let incoming = await websocket.receiveJson(ChatMessage)
    await websocket.sendJson(ChatMessage(text: incoming.text))
```

`receiveText` rejects a binary frame with `WebSocketDisconnectError`.
`receiveJson` can additionally raise `JsonParsingError` for malformed or
incompatible JSON.

## Connection groups and broadcast

`WebSocketGroup` tracks accepted connections. `broadcastText` sends to a
snapshot of the current group, removes connections whose send fails, and
returns the successful delivery count.

```nim
let clients = newWebSocketGroup()

app.websocket("/chat"):
  await websocket.accept()
  clients.addWebSocket(websocket)
  try:
    while true:
      let text = await websocket.receiveText()
      discard await clients.broadcastText(text)
  finally:
    discard clients.removeWebSocket(websocket)
```

Adding a connection that has not been accepted raises
`WebSocketDisconnectError`. Adding the same connection more than once has no
effect.

## Closing and disconnects

Close normally with an optional WebSocket status code and reason:

```nim
await websocket.close(code = 1000, reason = "complete")
```

Message operations require a connected socket. A peer disconnect, timeout,
wrong frame type, or operation on a closed connection surfaces as a WebSocket
error. Long-running handlers should use `try`/`finally` for group removal and
other application cleanup. Chronos cancellation must be allowed to propagate.

## Limits and heartbeats

Configure WebSocket capacity, I/O timeouts, message size, and automatic ping
interval through `RequestLimits` before starting the server:

```nim
let limits = initRequestLimits(
  websocket = initWebSocketLimits(
    maxConnections = 256,
    idleTimeout = 45.seconds,
    maxMessageSize = 2 * 1024 * 1024,
    heartbeatInterval = 15.seconds,
  )
)

let app = initFastNim(limits = limits)
```

Use `InfiniteDuration` to disable the I/O deadline or heartbeat. An oversized
message closes with code 1009. `sendHeartbeat` is available when an application
needs an explicit ping in addition to adapter-managed heartbeats.

## Middleware and authentication

WebSocket routes have their own upgraded-connection lifecycle. They bypass the
ordinary HTTP middleware chain and `handlerTimeout`. Authenticate during the
upgrade with the auth plugin's WebSocket support, or validate headers and
request context at the beginning of the WebSocket handler. Apply
`WebSocketLimits` to bound long-lived connection resource usage.

