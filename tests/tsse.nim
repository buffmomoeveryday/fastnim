import std/[assertions, tables]

import chronos

import fastnim

block formatsEvents:
  let event = sseEvent("first\nsecond", event = "update", id = "42", retry = 1500)
  doAssert formatSseEvent(event) ==
    "id: 42\nevent: update\nretry: 1500\ndata: first\ndata: second\n\n"

block createsEventStreamResponse:
  let response = eventStream([sseEvent("hello")])
  doAssert response.status == 200
  doAssert response.headers["content-type"] == "text/event-stream; charset=utf-8"
  doAssert response.headers["cache-control"] == "no-cache"
  doAssert response.body == "data: hello\n\n"

block routesSseRequests:
  let app = initFastNim()
  app.sse("/events/{name}"):
    await send(sseEvent("hello " & request.pathParam("name"), event = "greeting"))

  doAssert app.isSseRoute(initRequest(HttpMethod.Get, "/events/Ada"))
  doAssert not app.isSseRoute(initRequest(HttpMethod.Get, "/events"))

block rejectsInvalidEventFields:
  doAssertRaises ValueError:
    discard sseEvent("hello", event = "bad\nevent")
