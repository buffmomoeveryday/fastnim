import std/[assertions, logging, strutils]

import fastnim

var handlerCalls {.global.}: int
var receivedLevel {.global.}: Level
var receivedResponseTime {.global.}: bool
var receivedListeningLog {.global.}: bool
var receivedDocsLog {.global.}: bool

proc countingHandler(level: Level, message: string) {.gcsafe, raises: [].} =
  handlerCalls.inc
  receivedLevel = level
  receivedResponseTime = message.endsWith(" μs")

proc startupHandler(level: Level, message: string) {.gcsafe, raises: [].} =
  if level == lvlInfo and message == "Listening at http://127.0.0.1:0":
    receivedListeningLog = true
  if level == lvlInfo and message == "Docs served at http://127.0.0.1:0/reference":
    receivedDocsLog = true

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

block logsDocumentationUrlWhenServerStarts:
  receivedListeningLog = false
  receivedDocsLog = false
  let app = initFastNim(
    logHandler = startupHandler, openApi = initOpenApiSettings(docsPath = "reference")
  )
  let server = app.serve(port = 0)
  waitFor server.stop()
  doAssert receivedListeningLog
  doAssert receivedDocsLog

block omitsDocumentationUrlWhenOpenApiIsDisabled:
  receivedDocsLog = false
  let app = initFastNim(
    logHandler = startupHandler,
    openApi = initOpenApiSettings(docsPath = "reference", enabled = false),
  )
  let server = app.serve(port = 0)
  waitFor server.stop()
  doAssert not receivedDocsLog
