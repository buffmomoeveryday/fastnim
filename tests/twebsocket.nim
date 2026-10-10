import std/assertions

import chronos

import fastnim

block registersWebSocketRoutes:
  let app = initFastNim()
  app.websocket("/chat/{room}"):
    await websocket.accept()

  doAssert app.isWebSocketRoute(initRequest(HttpMethod.Get, "/chat/general"))
  doAssert not app.isWebSocketRoute(initRequest(HttpMethod.Get, "/chat"))

block createsEmptyWebSocketGroup:
  let group = newWebSocketGroup()
  doAssert group.len == 0
  let delivered = waitFor group.broadcastText("hello")
  doAssert delivered == 0
