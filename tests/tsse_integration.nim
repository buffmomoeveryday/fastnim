## Run with: nim c -r --path:src -d:sseIntegration tests/tsse_integration.nim
##
## Proves the server survives SSE clients that vanish mid-stream. Without the
## disconnect guard in `sendSse`, broadcasting into a dead subscription made
## `finish()` trip Chronos' response-state assertion, killing the whole
## server process. Like `twebsocket_integration`, this needs real loopback
## sockets, so it only runs with `-d:sseIntegration`.

when defined(sseIntegration):
  import std/[assertions, strutils]

  import chronos
  import chronos/apps/http/httpserver as chronosHttp
  import chronos/asyncsync

  import fastnim
  import fastnim/plugins/datastar

  proc serveForTest(
      app: Application, port: uint16
  ): chronosHttp.HttpServerRef {.gcsafe, raises: [Exception].} =
    {.gcsafe.}:
      result = app.serve(port = port)

  proc readAvailable(transp: StreamTransport): Future[string] {.async.} =
    var chunk = newSeq[byte](4096)
    result = ""
    for _ in 0 ..< 8:
      let n = await transp.readOnce(addr chunk[0], chunk.len)
      if n <= 0:
        break
      var part = newString(n)
      copyMem(addr part[0], addr chunk[0], n)
      result.add(part)
      if n < chunk.len:
        break

  # Module level so plain (nimcall) route blocks can use it: those cannot
  # capture enclosing proc state, while SSE handlers reach it with casts.
  let feed = newLiveFeed()

  proc exerciseDisconnect() {.async: (raises: [CancelledError, Exception]).} =
    let app = initFastNim(logs = false)
    app.get("/ping"):
      text("pong")
    app.sse("/notes/stream"):
      var queue: AsyncQueue[DatastarEvent]
      {.gcsafe.}:
        queue = feed.subscribe()
      try:
        var firstHtml = ""
        {.gcsafe.}:
          firstHtml = feed.snapshot()
        if firstHtml.len > 0:
          await send(patchElements(firstHtml))
        while true:
          {.gcsafe.}:
            await feed.relay(queue, send)
      except CatchableError:
        discard # client disconnected
      finally:
        {.gcsafe.}:
          feed.unsubscribe(queue)
    app.post("/notes/add"):
      let html = """<ul id="feed"><li>ping</li></ul>"""
      let event = patchElements(html)
      feed.setSnapshot(html)
      feed.broadcast(event)
      datastarStream([event])

    let server = serveForTest(app, 18082)
    let noFlags: set[SocketFlags] = {}
    try:
      # 1. Open a stream and vanish mid-stream, like a closed browser tab.
      var stream =
        await connect(initTAddress("127.0.0.1", Port(18082)), flags = noFlags)
      discard await stream.write(
        "GET /notes/stream HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
          "Accept: text/event-stream\r\nConnection: close\r\n\r\n"
      )
      await sleepAsync(300.milliseconds)
      await stream.closeWait()
      await sleepAsync(300.milliseconds)

      # 2. Broadcast into the dead subscription twice: the first write may
      #    still land in kernel buffers, the second deterministically fails.
      for _ in 1 .. 2:
        var poster =
          await connect(initTAddress("127.0.0.1", Port(18082)), flags = noFlags)
        discard await poster.write(
          "POST /notes/add HTTP/1.1\r\nHost: 127.0.0.1\r\n" &
            "Content-Type: application/json\r\nContent-Length: 0\r\n" &
            "Connection: close\r\n\r\n"
        )
        let posted = await readAvailable(poster)
        doAssert "200" in posted
        await poster.closeWait()

      # 3. The server must still be alive.
      var check = await connect(initTAddress("127.0.0.1", Port(18082)), flags = noFlags)
      discard await check.write(
        "GET /ping HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
      )
      let pong = await readAvailable(check)
      doAssert "pong" in pong
      await check.closeWait()
    finally:
      await chronosHttp.stop(server)

  waitFor exerciseDisconnect()
