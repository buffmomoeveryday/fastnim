import std/assertions

import fastnim

block exposesChronosTransport:
  let app = initFastNim()
  app.get(
    "/",
    proc(request: Request): Response {.raises: [].} =
      text("ok"),
  )
  doAssert app.routes.len == 1
