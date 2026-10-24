# WebSocket, SSE, and gRPC

Streaming routes have their own lifecycles: they bypass HTTP middleware and the ordinary
handler timeout, and use separate connection, idle, size, and heartbeat limits.

## SSE

```nim
app.sse("/events"):
  await send(sseEvent("connected", event = "status", id = "1"))
  await send(sseEvent("ready"))
```

- `sseEvent(data, event = "", id = "", retry = -1)` builds a `ServerSentEvent`.
- `send(event)` writes one event; the adapter emits `text/event-stream`.
- Programmatic registration: `app.addSseRoute(path, handler)`.
- Response helpers: `eventStream(events)` / `eventStream(status, events)` for finite streams.

See `docs/sse.md`, `examples/sse.nim`, `examples/ticker.nim`.

## WebSocket

```nim
app.websocket("/echo"):
  await websocket.accept()
  while true:
    await websocket.sendText(await websocket.receiveText())
```

Connection API (`src/fastnim/websocket.nim`):

| Call | Purpose |
| --- | --- |
| `websocket.accept()` | Complete the upgrade handshake |
| `websocket.receiveText()` / `receiveBytes()` | Read a frame |
| `websocket.receiveJson[T]()` | Read and parse a JSON frame |
| `websocket.sendText(s)` / `sendBytes(b)` | Write a frame |
| `websocket.sendJson(value)` | Write a JSON frame |
| `websocket.sendHeartbeat()` | Keep the connection alive |
| `websocket.close(...)` | Close the connection |
| `websocket.state` | Current `WebSocketState` |

Broadcast groups:

```nim
let clients = newWebSocketGroup()
clients.addWebSocket(websocket)
discard await clients.broadcastText(message)
discard clients.removeWebSocket(websocket)
```

`newWebSocketGroup()`, `group.addWebSocket`, `group.removeWebSocket`, `group.broadcastText`,
`group.len`.

See `docs/websocket.md`, `examples/websocket_echo.nim`, `examples/websocket_broadcast.nim`.

## gRPC

Native gRPC listener with unary, server-streaming, client-streaming, and bidirectional RPCs.
It implements HTTP/2 framing, HPACK, protobuf framing, metadata, and standard gRPC status
trailers without depending on nghttp2 or OpenSSL.

```nim
import fastnim/plugins/grpc

# register a method with the same typed-block shape as an HTTP route
```

The protobuf service definition lives in `examples/hello.proto`; the runnable server is
`examples/grpc.nim`. Supporting modules: `src/fastnim/grpc/{types,protobuf,schema}.nim`.

See `docs/grpc.md`.

## MQTT

`fastnim/plugins/mqtt` provides a Chronos-based broker with publication routing, topic
captures, subscriptions, and retained messages. See `docs/mqtt.md`.

## Rule of thumb

Inside a streaming handler, never assume HTTP middleware ran, never rely on the handler
timeout, and always close the connection on the `finally` path.
