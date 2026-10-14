## WebSocket connection helpers for fastnim applications.

import std/json

import chronos/[asyncloop, futures]
import ./private/jsonconversion
import stew/byteutils
import websock/websock as rawWs

type
  WebSocketState* {.pure.} = enum ## Lifecycle state of a WebSocket connection.
    Connecting
    Connected
    Disconnected

  WebSocketDisconnectError* = object of CatchableError
    ## Raised when an operation requires an open WebSocket connection.
    code*: int ## Protocol close code carried by the failure.

  WebSocket* = ref object ## An accepted WebSocket connection.
    session: rawWs.WSSession
    state: WebSocketState
    maxMessageSize: int
    idleTimeout: Duration

  WebSocketGroup* = ref object ## A set of WebSocket clients for group broadcasts.
    connections: seq[WebSocket]

proc newWebSocket*(
    session: rawWs.WSSession,
    maxMessageSize = 1024 * 1024,
    idleTimeout = 30.seconds,
): WebSocket =
  ## Wraps an accepted nim-websock session.
  if maxMessageSize <= 0:
    raise newException(ValueError, "WebSocket maximum message size must be positive")
  if not idleTimeout.isInfinite() and idleTimeout <= ZeroDuration:
    raise newException(ValueError, "WebSocket idle timeout must be positive or infinite")
  WebSocket(
    session: session,
    state: WebSocketState.Connecting,
    maxMessageSize: maxMessageSize,
    idleTimeout: idleTimeout,
  )

proc newWebSocketGroup*(): WebSocketGroup =
  ## Creates an empty group of WebSocket connections.
  WebSocketGroup(connections: @[])

proc ensureConnected(websocket: WebSocket) =
  if websocket.state != WebSocketState.Connected:
    raise newException(WebSocketDisconnectError, "WebSocket is not connected")

proc raiseDisconnect(message: string, code: int) {.noreturn.} =
  var exc = newException(WebSocketDisconnectError, message)
  exc.code = code
  raise exc

proc waitForIo(
    websocket: WebSocket, pending: rawWs.WSSendFuture
): Future[void] {.
    async: (
      raises: [CancelledError, AsyncStreamError, rawWs.WebSocketError,
        WebSocketDisconnectError]
    )
.} =
  if websocket.idleTimeout.isInfinite():
    await pending
    return
  try:
    await pending.wait(websocket.idleTimeout)
  except AsyncTimeoutError:
    raiseDisconnect("WebSocket I/O timed out", 1001)

proc addWebSocket*(group: WebSocketGroup, websocket: WebSocket) =
  ## Adds an accepted connection to a group if it is not already present.
  websocket.ensureConnected()
  if websocket notin group.connections:
    group.connections.add(websocket)

proc removeWebSocket*(group: WebSocketGroup, websocket: WebSocket): bool =
  ## Removes a connection from a group and reports whether it was present.
  for index, candidate in group.connections:
    if candidate == websocket:
      group.connections.delete(index)
      return true

proc len*(group: WebSocketGroup): int {.inline.} =
  ## Returns the number of connections currently in the group.
  group.connections.len

proc state*(websocket: WebSocket): WebSocketState {.inline.} =
  ## Returns the connection state.
  websocket.state

proc accept*(websocket: WebSocket): Future[void] {.async: (raises: []).} =
  ## Marks a successfully upgraded connection as ready for application traffic.
  ##
  ## The HTTP upgrade handshake is performed by the Chronos adapter before the
  ## route handler starts.
  if websocket.state == WebSocketState.Connecting:
    websocket.state = WebSocketState.Connected

proc sendText*(
    websocket: WebSocket, data: string
): Future[void] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError, WebSocketDisconnectError
      ]
    )
.} =
  ## Sends a UTF-8 text message.
  websocket.ensureConnected()
  if data.len > websocket.maxMessageSize:
    raiseDisconnect("WebSocket message exceeds configured limit", 1009)
  await websocket.waitForIo(websocket.session.send(data))

proc broadcastText*(
    group: WebSocketGroup, data: string
): Future[int] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError, WebSocketDisconnectError
      ]
    )
.} =
  ## Sends a text message to each current member and returns the delivery count.
  ## Connections that fail to send are removed. Cancellation still propagates.
  var connections = newSeqOfCap[WebSocket](group.connections.len)
  for websocket in group.connections:
    connections.add(websocket)

  for websocket in connections:
    try:
      await websocket.sendText(data)
      inc result
    except CancelledError as exc:
      raise exc
    except CatchableError:
      discard group.removeWebSocket(websocket)

proc sendBytes*(
    websocket: WebSocket, data: seq[byte]
): Future[void] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError, WebSocketDisconnectError
      ]
    )
.} =
  ## Sends a binary message.
  websocket.ensureConnected()
  if data.len > websocket.maxMessageSize:
    raiseDisconnect("WebSocket message exceeds configured limit", 1009)
  await websocket.waitForIo(websocket.session.send(data, rawWs.Opcode.Binary))

proc sendJson*[T](
    websocket: WebSocket, value: T
): Future[void] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError, WebSocketDisconnectError
      ]
    )
.} =
  ## Serializes and sends a JSON text message.
  await websocket.sendText($toJsonValue(value))

proc receiveBytes*(
    websocket: WebSocket
): Future[seq[byte]] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError, WebSocketDisconnectError
      ]
    )
.} =
  ## Receives the next complete message as bytes.
  websocket.ensureConnected()
  let pending = websocket.session.recvMsg(websocket.maxMessageSize)
  if websocket.idleTimeout.isInfinite():
    return await pending
  try:
    return await pending.wait(websocket.idleTimeout)
  except AsyncTimeoutError:
    raiseDisconnect("WebSocket I/O timed out", 1001)

proc sendHeartbeat*(websocket: WebSocket): Future[void] {.
    async: (
      raises: [CancelledError, AsyncStreamError, rawWs.WebSocketError,
        WebSocketDisconnectError]
    )
.} =
  ## Sends one WebSocket ping frame, subject to the connection idle timeout.
  websocket.ensureConnected()
  await websocket.waitForIo(websocket.session.ping())

proc receiveText*(
    websocket: WebSocket
): Future[string] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError, WebSocketDisconnectError
      ]
    )
.} =
  ## Receives the next UTF-8 text message.
  let data = await websocket.receiveBytes()
  if websocket.session.binary:
    raise newException(WebSocketDisconnectError, "expected a text WebSocket message")
  result = string.fromBytes(data)

proc receiveJson*[T](
    websocket: WebSocket
): Future[T] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError,
        WebSocketDisconnectError, JsonParsingError,
      ]
    )
.} =
  ## Receives and decodes the next JSON text message.
  result = jsonToValue(parseJson(await websocket.receiveText()), T)

proc close*(
    websocket: WebSocket, code = 1000, reason = ""
): Future[void] {.async: (raises: [CancelledError]).} =
  ## Closes the connection with a WebSocket close frame.
  if websocket.state != WebSocketState.Disconnected:
    websocket.state = WebSocketState.Disconnected
    await websocket.session.close(rawWs.StatusCodes(code), reason)
