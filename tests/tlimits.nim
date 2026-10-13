import std/[assertions, logging, os, strutils, tables, tempfiles]

import chronos

import fastnim

const Boundary = "fastnim-limit-boundary"

var handlerCalls {.global.}: int
var handlerCancelled {.global.}: bool
var loggedTimeout {.global.}: bool
var loggedElapsed {.global.}: bool
var sawUploadCancel {.global.}: bool

proc timeoutLogger(level: Level, message: string) {.gcsafe, raises: [].} =
  discard level
  if "503" in message:
    loggedTimeout = true
  if message.endsWith(" μs"):
    loggedElapsed = true

proc headersWith(pairs: openArray[(string, string)]): Headers =
  result = initTable[string, string]()
  for pair in pairs:
    result[pair[0]] = pair[1]

block rejectsOversizedBufferedBody:
  handlerCalls = 0
  let app = initFastNim(
    logs = false, limits = initRequestLimits(maxBodySize = 4)
  )
  app.post("/items"):
    handlerCalls.inc
    text("ok")
  let oversized = app.handleSync(
    initRequest(HttpMethod.Post, "/items", body = "abcde")
  )
  doAssert oversized.status == 413
  doAssert "request body exceeds the size limit" in oversized.body
  doAssert handlerCalls == 0
  let allowed = app.handleSync(
    initRequest(HttpMethod.Post, "/items", body = "abcd")
  )
  doAssert allowed.status == 200
  doAssert handlerCalls == 1

block rejectsDeclaredContentLength:
  handlerCalls = 0
  let app = initFastNim(
    logs = false, limits = initRequestLimits(maxBodySize = 4)
  )
  app.post("/items"):
    handlerCalls.inc
    text("ok")
  let response = app.handleSync(
    initRequest(
      HttpMethod.Post,
      "/items",
      headersWith({"content-length": "1000"}),
      "",
    )
  )
  doAssert response.status == 413
  doAssert handlerCalls == 0

block rejectsOversizedHeaders:
  let app = initFastNim(
    logs = false,
    limits = initRequestLimits(
      maxHeaderNameSize = 8,
      maxHeaderValueSize = 8,
      maxHeaderCount = 2,
    ),
  )
  app.get("/"):
    text("ok")
  let longName = app.handleSync(
    initRequest(HttpMethod.Get, "/", headersWith({"toolongname": "x"}))
  )
  doAssert longName.status == 431
  doAssert "header name" in longName.body
  let longValue = app.handleSync(
    initRequest(HttpMethod.Get, "/", headersWith({"accept": "123456789"}))
  )
  doAssert longValue.status == 431
  doAssert "header value" in longValue.body
  let tooMany = app.handleSync(
    initRequest(
      HttpMethod.Get,
      "/",
      headersWith({"a": "1", "b": "2", "c": "3"}),
    )
  )
  doAssert tooMany.status == 431
  doAssert "too many headers" in tooMany.body
  let allowed = app.handleSync(
    initRequest(HttpMethod.Get, "/", headersWith({"accept": "text"}))
  )
  doAssert allowed.status == 200

block normalRequestIsUnaffected:
  let app = initFastNim(logs = false)
  app.post("/items"):
    text(request.body)
  let response = app.handleSync(
    initRequest(
      HttpMethod.Post,
      "/items",
      headersWith({"content-type": "text/plain"}),
      "hello",
    )
  )
  doAssert response.status == 200
  doAssert response.body == "hello"

block cancelsHandlerThatExceedsTimeout:
  handlerCancelled = false
  loggedTimeout = false
  loggedElapsed = false
  let app = initFastNim(
    logHandler = timeoutLogger,
    limits = initRequestLimits(handlerTimeout = 100.milliseconds),
  )
  app.use(responseTime())
  app.get("/slow"):
    try:
      await sleepAsync(5.seconds)
      text("late")
    except CancelledError:
      handlerCancelled = true
      raise
  app.get("/fast"):
    text("ok")
  let timedOut = app.handleSync(initRequest(HttpMethod.Get, "/slow"))
  doAssert timedOut.status == 503
  doAssert "request handler timed out" in timedOut.body
  doAssert "x-response-time-us" in timedOut.headers
  doAssert handlerCancelled
  doAssert loggedTimeout
  doAssert loggedElapsed
  let fast = app.handleSync(initRequest(HttpMethod.Get, "/fast"))
  doAssert fast.status == 200

block rejectsMultipartBeforeParsing:
  handlerCalls = 0
  let app = initFastNim(
    logs = false, limits = initRequestLimits(maxBodySize = 32)
  )
  app.post("/upload"):
    handlerCalls.inc
    discard await request.parseMultipart()
    text("uploaded")
  let body =
    "--" & Boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"image\"; filename=\"a.bin\"\r\n\r\n" &
    repeat("x", 64) & "\r\n--" & Boundary & "--\r\n"
  let response = app.handleSync(
    initRequest(
      HttpMethod.Post,
      "/upload",
      headersWith({
        "content-type": "multipart/form-data; boundary=" & Boundary,
      }),
      body,
    )
  )
  doAssert response.status == 413
  doAssert handlerCalls == 0

block handlerTimeoutRemovesPartialUpload:
  proc exercise() {.async.} =
    sawUploadCancel = false
    let directory = createTempDir("fastnim-limit-", "")
    let options = initMultipartOptions(uploadDir = directory, chunkSize = 1024)
    let app = initFastNim(
      logs = false,
      limits = initRequestLimits(handlerTimeout = 500.milliseconds),
    )
    app.post("/upload"):
      try:
        discard await request.parseMultipart(options)
        text("uploaded")
      except CancelledError:
        sawUploadCancel = true
        raise
    let prefix =
      "--" & Boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"image\"; filename=\"slow.bin\"\r\n" &
      "Content-Type: application/octet-stream\r\n\r\n" & repeat("x", 4096)
    var sent = false
    let read: BodyReadProc = proc(
        maxBytes: int
    ): Future[string] {.async: (raises: [CatchableError]).} =
      if not sent:
        sent = true
        return prefix
      await sleepAsync(1.hours)
      return ""
    let close: BodyCloseProc = proc(): Future[void] {.async: (raises: []).} =
      discard
    var request = initRequest(
      HttpMethod.Post,
      "/upload",
      headersWith({
        "content-type": "multipart/form-data; boundary=\"" & Boundary & "\"",
      }),
    )
    request.attachBodySource(newRequestBodySource(read, close))
    let response = await app.handle(request)
    await request.closeBodySource()
    doAssert response.status == 503
    doAssert sawUploadCancel
    var entries = 0
    for kind, path in walkDir(directory):
      discard kind
      discard path
      inc(entries)
    doAssert entries == 0
    removeDir(directory)

  waitFor exercise()

proc exchange(port: Port, raw: string): Future[string] {.async.} =
  let connection = await connect(initTAddress("127.0.0.1", port))
  try:
    discard await connection.write(raw)
    var chunk = newSeq[byte](4096)
    let count = await connection.readOnce(addr chunk[0], chunk.len)
    result = newString(count)
    if count > 0:
      copyMem(addr result[0], addr chunk[0], count)
  finally:
    await connection.closeWait()

block loopbackEnforcesTransportLimitsAndKeepsServing:
  handlerCancelled = false
  let app = initFastNim(
    logs = false,
    limits = initRequestLimits(
      maxBodySize = 64,
      maxHeadersSize = 128,
      maxHeaderNameSize = 64,
      maxHeaderValueSize = 64,
      handlerTimeout = 200.milliseconds,
    ),
  )
  app.get("/slow"):
    try:
      await sleepAsync(5.seconds)
      text("late")
    except CancelledError:
      handlerCancelled = true
      raise
  app.get("/health"):
    text("ok")
  let server = app.serve(port = 0)
  proc exercise(port: Port) {.async: (raises: [Exception]).} =
    let headers = await exchange(
      port,
      "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Big: " & repeat("a", 200) &
        "\r\nConnection: close\r\n\r\n",
    )
    doAssert headers.startsWith("HTTP/1.1 431"), headers
    let body = await exchange(
      port,
      "POST /health HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 1000\r\n" &
        "Connection: close\r\n\r\n",
    )
    doAssert body.startsWith("HTTP/1.1 413"), body
    let timedOut = await exchange(
      port,
      "GET /slow HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    )
    doAssert timedOut.startsWith("HTTP/1.1 503"), timedOut
    doAssert handlerCancelled
    let health = await exchange(
      port,
      "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
    )
    doAssert health.startsWith("HTTP/1.1 200"), health
  try:
    waitFor exercise(server.address.port)
  finally:
    waitFor server.stop()
