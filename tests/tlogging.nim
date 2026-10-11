import std/[assertions, logging, strutils]

import fastnim

var handlerCalls {.global.}: int
var receivedLevel {.global.}: Level
var receivedResponseTime {.global.}: bool

proc countingHandler(level: Level, message: string) {.gcsafe, raises: [].} =
  handlerCalls.inc
  receivedLevel = level
  receivedResponseTime = message.endsWith(" μs")

block sendsRequestEventsToCustomHandler:
  handlerCalls = 0
  receivedResponseTime = false
  let app = initFastNim(logHandler = countingHandler)
  app.get("/"):
    "ok"

  discard app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert handlerCalls == 1
  doAssert receivedLevel == lvlInfo
  doAssert receivedResponseTime

block canDisableLogs:
  handlerCalls = 0
  let app = initFastNim(logs = false, logHandler = countingHandler)

  discard app.handleSync(initRequest(HttpMethod.Get, "/missing"))
  doAssert handlerCalls == 0

block settingsCanDisableLogs:
  let app = initFastNim(initApplicationSettings(logs = false))
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/missing")).status == 404
