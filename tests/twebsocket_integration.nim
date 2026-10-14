when defined(websocketIntegration):
  import std/assertions

  import chronos
  import chronicles
  import chronos/apps/http/httpserver as chronosHttp
  import stew/byteutils
  import websock/websock as rawWs

  import fastnim

  var rejectedOversizedMessage {.global.}: bool

  proc serveForTest(
      app: Application, port: uint16
  ): chronosHttp.HttpServerRef {.gcsafe, raises: [Exception].} =
    {.gcsafe.}:
      result = app.serve(port = port)

  proc exerciseWebSocket() {.async: (raises: [CancelledError, Exception]).} =
    let app = initFastNim()
    app.websocket("/echo/{room}"):
      await websocket.accept()
      let message = await websocket.receiveText()
      await websocket.sendText(request.pathParam("room") & ": " & message)

    let server = serveForTest(app, 18080)
    try:
      let client =
        await rawWs.WebSocket.connect("127.0.0.1:18080", path = "/echo/general")
      await client.send("hello")
      doAssert string.fromBytes(await client.recvMsg()) == "general: hello"
      await client.close()
    finally:
      await chronosHttp.stop(server)

  proc exerciseBroadcast() {.async: (raises: [CancelledError, Exception]).} =
    let app = initFastNim()
    let clients = newWebSocketGroup()
    app.websocket("/chat"):
      await websocket.accept()
      clients.addWebSocket(websocket)
      try:
        while true:
          discard await websocket.receiveText()
          discard await clients.broadcastText("Hello everyone")
      finally:
        discard clients.removeWebSocket(websocket)

    let server = serveForTest(app, 18081)
    var first: rawWs.WSSession
    var second: rawWs.WSSession
    try:
      first = await rawWs.WebSocket.connect("127.0.0.1:18081", path = "/chat")
      second = await rawWs.WebSocket.connect("127.0.0.1:18081", path = "/chat")
      await first.send("broadcast")
      doAssert string.fromBytes(await first.recvMsg()) == "Hello everyone"
      doAssert string.fromBytes(await second.recvMsg()) == "Hello everyone"
    finally:
      if not first.isNil:
        await first.close()
      if not second.isNil:
        await second.close()
      await chronosHttp.stop(server)

  proc exerciseMessageLimit() {.async: (raises: [CancelledError, Exception]).} =
    rejectedOversizedMessage = false
    let wsLimits = initWebSocketLimits(
      maxMessageSize = 4,
      idleTimeout = 1.seconds,
      heartbeatInterval = InfiniteDuration,
    )
    let app = initFastNim(
      logs = false, limits = initRequestLimits(websocket = wsLimits)
    )
    app.websocket("/limited"):
      await websocket.accept()
      try:
        discard await websocket.receiveText()
      except rawWs.WebSocketError:
        rejectedOversizedMessage = true

    let server = serveForTest(app, 18083)
    var client: rawWs.WSSession
    try:
      client = await rawWs.WebSocket.connect("127.0.0.1:18083", path = "/limited")
      await client.send("hello")
      await sleepAsync(100.milliseconds)
      doAssert rejectedOversizedMessage
    finally:
      if not client.isNil:
        try:
          await client.close()
        except CatchableError:
          discard
      await chronosHttp.stop(server)

  waitFor exerciseWebSocket()
  waitFor exerciseBroadcast()
  waitFor exerciseMessageLimit()
