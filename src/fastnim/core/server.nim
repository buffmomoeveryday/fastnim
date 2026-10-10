## Chronos HTTP server adapter for fastnim applications.

import std/[json, logging, monotimes, strutils, tables, times, uri]

import chronos/apps/http/httpserver as chronosHttp
import websock/websock as rawWs

import fastnim/routing/router
import fastnim/context/http as fastnimHttp
import fastnim/websocket

const fastNimStartupBanner = """
----------------------------------------
░█▀▀░█▀█░█▀▀░▀█▀░█▀█░▀█▀░█▄█
░█▀▀░█▀█░▀▀█░░█░░█░█░░█░░█░█
░▀░░░▀░▀░▀▀▀░░▀░░▀░▀░▀▀▀░▀░▀

"""

proc toFastnimMethod(`method`: chronosHttp.HttpMethod): fastnimHttp.HttpMethod =
  case `method`
  of chronosHttp.MethodGet: fastnimHttp.HttpMethod.Get
  of chronosHttp.MethodPost: fastnimHttp.HttpMethod.Post
  of chronosHttp.MethodPut: fastnimHttp.HttpMethod.Put
  of chronosHttp.MethodPatch: fastnimHttp.HttpMethod.Patch
  of chronosHttp.MethodDelete: fastnimHttp.HttpMethod.Delete
  of chronosHttp.MethodHead: fastnimHttp.HttpMethod.Head
  of chronosHttp.MethodOptions: fastnimHttp.HttpMethod.Options
  else: fastnimHttp.HttpMethod.Options

proc toChronosStatus(status: int): chronosHttp.HttpCode =
  let code = chronosHttp.toHttpCode(status)
  if code.isSome():
    code.get()
  else:
    chronosHttp.Http500

proc toFastnimRequest(
    request: chronosHttp.HttpRequestRef
): Future[fastnimHttp.Request] {.
    async: (
      raises:
        [CancelledError, chronosHttp.HttpTransportError, chronosHttp.HttpProtocolError]
    )
.} =
  var headers = initTable[string, string]()
  for key, value in request.headers.stringItems():
    headers[key.toLowerAscii()] = value

  let body =
    if request.hasBody():
      bytesToString(await request.getBody())
    else:
      ""
  result = fastnimHttp.initRequest(
    toFastnimMethod(request.meth), request.rawPath, headers, body
  )
  for key, value in request.query.stringItems():
    result.queryParams[key] = value

proc toChronosResponse(
    request: chronosHttp.HttpRequestRef, response: fastnimHttp.Response
): Future[chronosHttp.HttpResponseRef] {.
    async: (raises: [CancelledError, chronosHttp.HttpWriteError])
.} =
  var headers = chronosHttp.HttpTable.init()
  for key, value in response.headers:
    headers.set(key, value)
  result =
    await request.respond(toChronosStatus(response.status), response.body, headers)

proc sendStaticFile(
    app: Application,
    chronosRequest: chronosHttp.HttpRequestRef,
    response: fastnimHttp.Response,
): Future[chronosHttp.HttpResponseRef] {.
    async: (raises: [CancelledError, chronosHttp.HttpWriteError])
.} =
  ## Streams a ``sendFile`` marker response in 64 KiB chunks.
  ##
  ## Chunked encoding is used so large files never sit fully in memory.
  ## ``content-length`` is stripped because HTTP forbids combining it with
  ## chunked framing; ``content-range`` and validators are preserved.
  var opened: File
  if not open(opened, response.sendFile, fmRead):
    app.logError("Static file is no longer readable: " & response.sendFile)
    return await toChronosResponse(chronosRequest, fastnimHttp.text("Not Found", 404))
  let cresp = chronosRequest.getResponse()
  cresp.status = toChronosStatus(response.status)
  for key, value in response.headers:
    if key.toLowerAscii() != "content-length":
      cresp.setHeader(key, value)
  try:
    await cresp.prepareChunked()
    setFilePos(opened, response.fileOffset)
    var remaining =
      if response.fileLength < 0:
        getFileSize(opened) - response.fileOffset
      else:
        response.fileLength
    var chunk = newString(65536)
    while remaining > 0:
      let want = min(remaining, 65536'i64).int
      let got = readBuffer(opened, addr chunk[0], want)
      if got <= 0:
        break
      chunk.setLen(got)
      await cresp.send(chunk)
      chunk.setLen(65536)
      remaining -= got.int64
    await cresp.finish()
  except CatchableError as exc:
    app.logError("Static file streaming failed: " & exc.msg)
    return chronosHttp.dropResponse()
  finally:
    close(opened)
  cresp

proc sendSse(
    app: Application,
    request: fastnimHttp.Request,
    chronosRequest: chronosHttp.HttpRequestRef,
): Future[chronosHttp.HttpResponseRef] {.
    async: (raises: [CancelledError, chronosHttp.HttpWriteError, ValueError])
.} =
  let response = chronosRequest.getResponse()
  response.setHeader("content-type", "text/event-stream; charset=utf-8")
  response.setHeader("cache-control", "no-cache")
  await response.prepareSSE()
  let eventSender: SseSend = proc(
      event: ServerSentEvent
  ): Future[void] {.async: (raises: [CancelledError, chronosHttp.HttpWriteError]).} =
    if response.getResponseState() notin
        {chronosHttp.HttpResponseState.Prepared, chronosHttp.HttpResponseState.Sending}:
      # The peer went away after an earlier write failed. Report it as a
      # regular write error (which callers and `process` handle by dropping
      # the connection) instead of letting Chronos trip its internal response
      # state assertion, which would crash the whole server.
      raise newException(chronosHttp.HttpWriteError, "SSE connection is closed")
    await response.send(formatSseEvent(event))
  try:
    await app.handleSse(request, eventSender)
  except chronosHttp.HttpWriteError as exc:
    return chronosHttp.dropResponse()
  if response.getResponseState() in
      {chronosHttp.HttpResponseState.Prepared, chronosHttp.HttpResponseState.Sending}:
    await response.finish()
  else:
    # The handler swallowed a send error (for example to unsubscribe a dead
    # client) and returned normally. There is nothing left to flush; dropping
    # avoids tripping the response state assertion in `finish`.
    return chronosHttp.dropResponse()
  response

proc toWebSocketRequest(request: chronosHttp.HttpRequestRef): rawWs.HttpRequest =
  var headers = rawWs.HttpTable.init()
  for key, value in request.headers.stringItems():
    headers.add(key, value)
  rawWs.HttpRequest(
    headers: headers,
    stream: request.upgradeStream(),
    uri: parseUri(request.rawPath),
    meth: rawWs.MethodGet,
  )

proc serveWebSocket(
    app: Application,
    request: fastnimHttp.Request,
    chronosRequest: chronosHttp.HttpRequestRef,
): Future[chronosHttp.HttpResponseRef] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError,
        WebSocketDisconnectError, JsonParsingError, ValueError,
      ]
    )
.} =
  let rawRequest = chronosRequest.toWebSocketRequest()
  let session = await rawWs.WSServer.new().handleRequest(rawRequest)
  let websocket = newWebSocket(session)
  try:
    await app.handleWebSocket(request, websocket)
  finally:
    await websocket.close()
  chronosRequest.getResponse()

proc safeHandle(
    app: Application, request: fastnimHttp.Request
): fastnimHttp.Response {.gcsafe, raises: [].} =
  let startedAt = getMonoTime()
  try:
    {.cast(gcsafe).}:
      result = app.handle(request)
  except CatchableError as exc:
    app.logError("Unhandled request error: " & exc.msg)
    result = app.errorResponse(request, 500)
    app.logRequest(request, result.status, (getMonoTime() - startedAt).inMicroseconds)
  except:
    app.logError("Unhandled request defect")
    result = app.errorResponse(request, 500)
    app.logRequest(request, result.status, (getMonoTime() - startedAt).inMicroseconds)

proc serve*(
    app: Application, address = "127.0.0.1", port: uint16 = 8000
): chronosHttp.HttpServerRef =
  ## Creates and starts a Chronos server. Use ``waitFor server.join()`` to keep it running.
  echo fastNimStartupBanner
  app.load()
  proc process(
      requestFence: chronosHttp.RequestFence
  ): Future[chronosHttp.HttpResponseRef] {.async: (raises: [CancelledError]).} =
    try:
      if requestFence.isErr():
        return chronosHttp.defaultResponse(requestFence.error())
      let chronosRequest = requestFence.get()
      let request = await toFastnimRequest(chronosRequest)
      let startedAt = getMonoTime()
      if app.isWebSocketRoute(request):
        let response = await serveWebSocket(app, request, chronosRequest)
        app.logRequest(request, 101, (getMonoTime() - startedAt).inMicroseconds)
        return response
      if app.isSseRoute(request):
        let response = await sendSse(app, request, chronosRequest)
        app.logRequest(request, 200, (getMonoTime() - startedAt).inMicroseconds)
        return response
      when defined(fastnimTiming):
        let handlerStartedAt = getMonoTime()
      let response = app.safeHandle(request)
      when defined(fastnimTiming):
        echo "[fastnim timing] handler ",
          (getMonoTime() - handlerStartedAt).inMicroseconds, " us"
        let responseStartedAt = getMonoTime()
      if response.isFileResponse and request.method != fastnimHttp.HttpMethod.Head:
        return await sendStaticFile(app, chronosRequest, response)
      let sentResponse = await toChronosResponse(chronosRequest, response)
      when defined(fastnimTiming):
        echo "[fastnim timing] response write ",
          (getMonoTime() - responseStartedAt).inMicroseconds, " us"
      return sentResponse
    except CancelledError as exc:
      raise exc
    except chronosHttp.HttpWriteError:
      return chronosHttp.dropResponse()
    except CatchableError as exc:
      app.logError("Unhandled server error: " & exc.msg)
      return chronosHttp.defaultResponse(exc)

  result =
    chronosHttp.HttpServerRef.new(initTAddress(address, Port(port)), process).get()
  result.start()
  app.log(lvlInfo, "Listening at http://" & address & ":" & $port)

proc stop*(server: chronosHttp.HttpServerRef): auto =
  ## Stops a server created by ``serve``.
  chronosHttp.stop(server)

proc stop*(app: Application, server: chronosHttp.HttpServerRef): auto =
  ## Stops the server and runs the application's unload hooks.
  result = chronosHttp.stop(server)
  app.unload()

proc join*(server: chronosHttp.HttpServerRef): auto =
  ## Waits until a server created by ``serve`` stops.
  chronosHttp.join(server)
