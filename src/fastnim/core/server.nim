## Chronos HTTP server adapter for fastnim applications.

import std/[json, logging, monotimes, strutils, times, uri]

import chronos/apps/http/httpserver as chronosHttp
import chronos/streams/asyncstream
import chronos/timer as chronosTimer
import websock/websock as rawWs

import fastnim/routing/router
import fastnim/context/http as fastnimHttp
import fastnim/core/limits
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

type IncomingRequest = object
  request: fastnimHttp.Request
  status: int
  detail: string

type BodyReadBudget = ref object
  startedAt: chronosTimer.Moment
  bytesRead: int

proc raiseBodyReadLimit(detail: string) {.noreturn.} =
  var exc = newException(BodyReadLimitError, detail)
  exc.detail = detail
  raise exc

proc bodyReadWait(
    budget: BodyReadBudget, limits: RequestLimits
): tuple[timeout: chronosTimer.Duration, detail: string] =
  let elapsed = chronosTimer.Moment.now() - budget.startedAt
  result.timeout =
    if limits.bodyReadTimeout.isInfinite():
      chronosTimer.InfiniteDuration
    else:
      limits.bodyReadTimeout - elapsed
  result.detail = BodyReadTimeoutDetail
  if limits.minBodyBytesPerSecond > 0:
    let rateAllowance =
      limits.bodyReadGracePeriod +
      chronosTimer.milliseconds(
        (int64(budget.bytesRead) + 1) * 1000 div
          int64(limits.minBodyBytesPerSecond)
      )
    let rateRemaining = rateAllowance - elapsed
    if result.timeout.isInfinite() or rateRemaining < result.timeout:
      result.timeout = rateRemaining
      result.detail = BodyRateTooLowDetail
  if result.timeout <= chronosTimer.ZeroDuration:
    raiseBodyReadLimit(result.detail)

proc readBodyChunk(
    reader: chronosHttp.HttpBodyReader,
    budget: BodyReadBudget,
    limits: RequestLimits,
    maxBytes: int,
): Future[string] {.
    async: (
      raises: [CancelledError, AsyncStreamError, BodyReadLimitError]
    )
.} =
  if maxBytes <= 0:
    return ""
  var chunk = newString(maxBytes)
  let allowance = budget.bodyReadWait(limits)
  let pending = reader.readOnce(addr chunk[0], maxBytes)
  if not await pending.withTimeout(allowance.timeout):
    raiseBodyReadLimit(allowance.detail)
  let count = await pending
  chunk.setLen(count)
  budget.bytesRead += count
  if limits.minBodyBytesPerSecond > 0:
    let measured =
      (chronosTimer.Moment.now() - budget.startedAt) - limits.bodyReadGracePeriod
    if measured > chronosTimer.ZeroDuration and
        int64(budget.bytesRead) * 1000 <
          int64(limits.minBodyBytesPerSecond) * measured.milliseconds:
      raiseBodyReadLimit(BodyRateTooLowDetail)
  chunk

proc copyHeaders(request: chronosHttp.HttpRequestRef): fastnimHttp.Headers =
  result = initHeaders()
  for key, value in request.headers.stringItems():
    result.addHeader(key, value)

proc transportStatus(code: chronosHttp.HttpCode): int =
  parseInt(($code)[0 .. 2])

proc toFastnimRequest(
    app: Application, request: chronosHttp.HttpRequestRef
): Future[IncomingRequest] {.
    async: (
      raises:
        [CancelledError, chronosHttp.HttpTransportError,
          chronosHttp.HttpProtocolError, BodyReadLimitError]
    )
.} =
  let headers = copyHeaders(request)
  result.request = fastnimHttp.initRequest(
    toFastnimMethod(request.meth), request.rawPath, headers
  )
  let headerDetail = headerLimitDetail(headers, app.requestLimits)
  if headerDetail.len > 0:
    result.status = 431
    result.detail = headerDetail
    return
  let declaredDetail = bodyLimitDetail(headers, "", app.requestLimits)
  if declaredDetail.len > 0:
    result.status = 413
    result.detail = declaredDetail
    return

  let contentType = headers.getOrDefault("content-type").toLowerAscii()
  let streamsMultipart =
    request.hasBody() and contentType.startsWith("multipart/form-data")
  if request.hasBody() and not streamsMultipart:
    let bodyResult = request.getBodyReader()
    if bodyResult.isErr():
      raise newException(
        chronosHttp.HttpProtocolError,
        "Unable to open request body: " & $bodyResult.error,
      )
    let reader = bodyResult.get()
    let budget = BodyReadBudget(startedAt: chronosTimer.Moment.now())
    var body = ""
    try:
      await request.handleExpect()
      while true:
        let chunk = await readBodyChunk(reader, budget, app.requestLimits, 65536)
        if chunk.len == 0:
          break
        body.add(chunk)
      if reader.hasOverflow():
        chronosHttp.raiseHttpRequestBodyTooLargeError()
    except AsyncStreamError as exc:
      raise newException(
        chronosHttp.HttpReadError, "Unable to read request body: " & exc.msg
      )
    finally:
      await reader.closeWait()
    let bodyDetail = bodyLimitDetail(headers, body, app.requestLimits)
    if bodyDetail.len > 0:
      result.status = 413
      result.detail = bodyDetail
      return
    result.request.body = body
  elif streamsMultipart:
    let bodyResult = request.getBodyReader()
    if bodyResult.isErr():
      raise newException(
        chronosHttp.HttpProtocolError,
        "Unable to open multipart request body: " & $bodyResult.error,
      )
    let reader = bodyResult.get()
    let budget = BodyReadBudget(startedAt: chronosTimer.Moment.now())
    await request.handleExpect()
    let read: fastnimHttp.BodyReadProc = proc(
        maxBytes: int
    ): Future[string] {.async: (raises: [CatchableError]).} =
      try:
        let chunk = await readBodyChunk(reader, budget, app.requestLimits, maxBytes)
        if reader.hasOverflow():
          chronosHttp.raiseHttpRequestBodyTooLargeError()
        return chunk
      except CancelledError as exc:
        raise exc
      except AsyncStreamError as exc:
        raise newException(IOError, "Unable to read multipart body: " & exc.msg)
    let close: fastnimHttp.BodyCloseProc = proc(): Future[void] {.async: (raises: []).} =
      await reader.closeWait()
    result.request.attachBodySource(newRequestBodySource(read, close))

proc toChronosResponse(
    request: chronosHttp.HttpRequestRef, response: fastnimHttp.Response
): Future[chronosHttp.HttpResponseRef] {.
    async: (raises: [CancelledError, chronosHttp.HttpWriteError])
.} =
  var headers = chronosHttp.HttpTable.init()
  for key, value in response.headers:
    headers.add(key, value)
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
    return await toChronosResponse(
      chronosRequest, fastnimHttp.text(statusNotFound, "Not Found")
    )
  let cresp = chronosRequest.getResponse()
  cresp.status = toChronosStatus(response.status)
  for key, value in response.headers:
    if key.toLowerAscii() != "content-length":
      cresp.addHeader(key, value)
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
    limits: SseLimits,
): Future[chronosHttp.HttpResponseRef] {.
    async: (raises: [CancelledError, chronosHttp.HttpWriteError, ValueError])
.} =
  let response = chronosRequest.getResponse()
  response.setHeader("content-type", "text/event-stream; charset=utf-8")
  response.setHeader("cache-control", "no-cache")
  await response.prepareSSE()
  let writeLock = newAsyncLock()
  proc sendPayload(payload: string): Future[void] {.
      async: (raises: [CancelledError, chronosHttp.HttpWriteError])
  .} =
    await writeLock.acquire()
    try:
      if response.getResponseState() notin
          {chronosHttp.HttpResponseState.Prepared, chronosHttp.HttpResponseState.Sending}:
        raise newException(chronosHttp.HttpWriteError, "SSE connection is closed")
      try:
        if limits.idleTimeout.isInfinite():
          await response.send(payload)
        else:
          await response.send(payload).wait(limits.idleTimeout)
      except AsyncTimeoutError:
        raise newException(chronosHttp.HttpWriteError, "SSE write timed out")
    finally:
      try:
        writeLock.release()
      except AsyncLockError:
        raiseAssert "SSE write lock was released unexpectedly"

  let eventSender: SseSend = proc(
      event: ServerSentEvent
  ): Future[void] {.async: (raises: [CancelledError, chronosHttp.HttpWriteError]).} =
    let payload = formatSseEvent(event)
    if payload.len > limits.maxEventSize:
      raise newException(chronosHttp.HttpWriteError, "SSE event exceeds configured limit")
    await sendPayload(payload)
  var active = true
  proc heartbeat() {.async: (raises: []).} =
    while active:
      try:
        await sleepAsync(limits.heartbeatInterval)
        if active:
          await sendPayload(": heartbeat\n\n")
      except CancelledError:
        return
      except CatchableError:
        active = false
        return
  var heartbeatFuture: Future[void]
  if not limits.heartbeatInterval.isInfinite():
    heartbeatFuture = heartbeat()
    asyncSpawn heartbeatFuture
  try:
    await app.handleSse(request, eventSender)
  except chronosHttp.HttpWriteError:
    return chronosHttp.dropResponse()
  finally:
    active = false
    if not heartbeatFuture.isNil and not heartbeatFuture.finished():
      heartbeatFuture.cancelSoon()
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
    limits: WebSocketLimits,
): Future[chronosHttp.HttpResponseRef] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, rawWs.WebSocketError,
        WebSocketDisconnectError, JsonParsingError, ValueError,
      ]
    )
.} =
  let rawRequest = chronosRequest.toWebSocketRequest()
  let frameSize = min(limits.maxMessageSize, 64 * 1024)
  let session = await rawWs.WSServer.new(frameSize = frameSize).handleRequest(rawRequest)
  let websocket = newWebSocket(session, limits.maxMessageSize, limits.idleTimeout)
  var active = true
  proc heartbeat() {.async: (raises: []).} =
    while active:
      try:
        await sleepAsync(limits.heartbeatInterval)
        if active:
          await websocket.sendHeartbeat()
      except CancelledError:
        return
      except CatchableError:
        active = false
        try:
          await websocket.close(1001, "heartbeat failed")
        except CancelledError:
          discard
        return
  var heartbeatFuture: Future[void]
  if not limits.heartbeatInterval.isInfinite():
    heartbeatFuture = heartbeat()
    asyncSpawn heartbeatFuture
  try:
    await app.handleWebSocket(request, websocket)
  finally:
    active = false
    if not heartbeatFuture.isNil and not heartbeatFuture.finished():
      heartbeatFuture.cancelSoon()
    await websocket.close()
  chronosRequest.getResponse()

proc safeHandle(
    app: Application, request: fastnimHttp.Request
): Future[fastnimHttp.Response] {.async: (raises: [CancelledError]).} =
  let startedAt = getMonoTime()
  try:
    {.gcsafe.}:
      result = await app.handle(request)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    app.logError("Unhandled request error: " & exc.msg)
    result = app.errorResponse(request, 500)
    app.logRequest(request, result.status, (getMonoTime() - startedAt).inMicroseconds)
  except:
    app.logError("Unhandled request defect")
    result = app.errorResponse(request, 500)
    app.logRequest(request, result.status, (getMonoTime() - startedAt).inMicroseconds)

proc sendLimit(
    app: Application,
    chronosRequest: chronosHttp.HttpRequestRef,
    request: fastnimHttp.Request,
    status: int,
    detail: string,
    startedAt: MonoTime,
): Future[chronosHttp.HttpResponseRef] {.
    async: (raises: [CancelledError, chronosHttp.HttpWriteError])
.} =
  let response = app.limitResponse(request, status, detail)
  app.logRequest(request, response.status, (getMonoTime() - startedAt).inMicroseconds)
  await toChronosResponse(chronosRequest, response)

proc serve*(
    app: Application,
    address = "127.0.0.1",
    port: uint16 = 8000,
    maxRequestBodySize = 0,
): chronosHttp.HttpServerRef =
  ## Creates and starts a Chronos server. Use ``waitFor server.join()`` to keep it running.
  ##
  ## Request limits come from ``requestLimits``. A positive ``maxRequestBodySize``
  ## overrides ``maxBodySize`` for this server. Zero uses the application limit.
  ## Bodies above the cap return ``413`` before parsing. Header name, value,
  ## count, and raw block limits return ``431``. A client that stalls while
  ## sending headers or a body returns ``408``. Slow body rates also return
  ## ``408``. A handler that exceeds ``handlerTimeout`` returns ``503`` and is
  ## cancelled; excess concurrent handlers are rejected with ``503``.
  ##
  ## Accepted connections and the TCP backlog are bounded at server startup.
  ## The effective wait for any header block, including keep-alive requests,
  ## is the lower of ``headersTimeout`` and ``keepAliveTimeout``. SSE and
  ## WebSocket routes use their separate connection, idle, size, and heartbeat
  ## limits. Multipart body deadlines remain active while the handler parses.
  if maxRequestBodySize < 0:
    raise newException(ValueError, "maxRequestBodySize must be positive")
  if maxRequestBodySize > 0:
    var limits = app.requestLimits
    limits.maxBodySize = maxRequestBodySize
    app.configureRequestLimits(limits)
  echo fastNimStartupBanner
  app.load()
  let limits = app.requestLimits
  let handlerSlots = newAsyncSemaphore(limits.maxConcurrentHandlers)
  var activeSseConnections = 0
  var activeWebSocketConnections = 0
  proc process(
      requestFence: chronosHttp.RequestFence
  ): Future[chronosHttp.HttpResponseRef] {.async: (raises: [CancelledError]).} =
    try:
      if requestFence.isErr():
        let status = transportStatus(requestFence.error().code)
        app.log(lvlWarn, "rejected " & $status & " 0 μs")
        return chronosHttp.defaultResponse(requestFence.error())
      let chronosRequest = requestFence.get()
      let startedAt = getMonoTime()
      try:
        let incoming = await toFastnimRequest(app, chronosRequest)
        if incoming.status != 0:
          return await sendLimit(
            app, chronosRequest, incoming.request, incoming.status, incoming.detail,
            startedAt,
          )
        let request = incoming.request
        if app.isWebSocketRoute(request):
          if activeWebSocketConnections >= limits.websocket.maxConnections:
            return await sendLimit(
              app, chronosRequest, request, 503, WebSocketCapacityDetail, startedAt
            )
          inc activeWebSocketConnections
          try:
            let response = await serveWebSocket(
              app, request, chronosRequest, limits.websocket
            )
            app.logRequest(request, 101, (getMonoTime() - startedAt).inMicroseconds)
            return response
          finally:
            dec activeWebSocketConnections
        if app.isSseRoute(request):
          if activeSseConnections >= limits.sse.maxConnections:
            return await sendLimit(
              app, chronosRequest, request, 503, SseCapacityDetail, startedAt
            )
          inc activeSseConnections
          try:
            let response = await sendSse(app, request, chronosRequest, limits.sse)
            app.logRequest(request, 200, (getMonoTime() - startedAt).inMicroseconds)
            return response
          finally:
            dec activeSseConnections
        when defined(fastnimTiming):
          let handlerStartedAt = getMonoTime()
        if not handlerSlots.tryAcquire():
          await request.closeBodySource()
          return await sendLimit(
            app, chronosRequest, request, 503, HandlerCapacityDetail, startedAt
          )
        let response =
          try:
            try:
              await app.safeHandle(request)
            finally:
              await request.closeBodySource()
          finally:
            try:
              handlerSlots.release()
            except AsyncSemaphoreError:
              raiseAssert "HTTP handler slot was released unexpectedly"
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
      except chronosHttp.HttpRequestBodyTooLargeError:
        let request = fastnimHttp.initRequest(
          toFastnimMethod(chronosRequest.meth),
          chronosRequest.rawPath,
          copyHeaders(chronosRequest),
        )
        return await sendLimit(
          app, chronosRequest, request, 413, BodyTooLargeDetail, startedAt
        )
      except BodyReadLimitError as exc:
        let request = fastnimHttp.initRequest(
          toFastnimMethod(chronosRequest.meth),
          chronosRequest.rawPath,
          copyHeaders(chronosRequest),
        )
        return await sendLimit(
          app, chronosRequest, request, 408, exc.detail, startedAt
        )
    except CancelledError as exc:
      raise exc
    except chronosHttp.HttpWriteError:
      return chronosHttp.dropResponse()
    except CatchableError as exc:
      app.logError("Unhandled server error: " & exc.msg)
      return chronosHttp.defaultResponse(exc)

  let effectiveHeadersTimeout =
    if limits.headersTimeout.isInfinite():
      limits.keepAliveTimeout
    elif limits.keepAliveTimeout.isInfinite():
      limits.headersTimeout
    else:
      min(limits.headersTimeout, limits.keepAliveTimeout)
  result = chronosHttp.HttpServerRef
    .new(
      initTAddress(address, Port(port)),
      process,
      serverFlags = {chronosHttp.HttpServerFlags.Http11Pipeline},
      socketFlags = {chronosHttp.ReuseAddr, chronosHttp.TcpNoDelay},
      httpHeadersTimeout = effectiveHeadersTimeout,
      maxHeadersSize = limits.maxHeadersSize,
      maxRequestBodySize = limits.maxBodySize,
      maxConnections = limits.maxConnections,
      backlogSize = limits.backlog,
    )
    .get()
  let createConnection = result.createConnCallback
  var activeConnections = 0
  result.createConnCallback = proc(
      server: chronosHttp.HttpServerRef, transport: StreamTransport
  ): Future[chronosHttp.HttpConnectionRef] {.
      async: (raises: [CancelledError, chronosHttp.HttpConnectionError])
  .} =
    if activeConnections >= limits.maxConnections:
      await transport.closeWait()
      raise newException(
        chronosHttp.HttpConnectionError, "maximum HTTP connections reached"
      )
    let connection = await createConnection(server, transport)
    inc activeConnections
    let closeConnection = connection.closeCb
    var counted = true
    connection.closeCb = proc(
        closing: chronosHttp.HttpConnectionRef
    ): Future[void] {.async: (raises: []).} =
      if counted:
        counted = false
        dec activeConnections
      await closeConnection(closing)
    connection
  result.start()
  let baseUrl = "http://" & address & ":" & $port
  app.log(lvlInfo, "Listening at " & baseUrl)
  if app.openApiSettings.enabled:
    let docsPath =
      if app.openApiSettings.docsPath.startsWith('/'):
        app.openApiSettings.docsPath
      else:
        "/" & app.openApiSettings.docsPath
    app.log(lvlInfo, "Docs served at " & baseUrl & docsPath)

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
