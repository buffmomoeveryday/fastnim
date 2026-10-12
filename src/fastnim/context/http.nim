## HTTP request and response values used by fastnim applications.

import std/[json, macros, strutils, tables, uri]

import chronos

import fastnim/context/state
import fastnim/private/jsonconversion

export tables

type
  BodyReadProc* = proc(maxBytes: int): Future[string] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .}
    ## Reads at most ``maxBytes`` bytes from a request body.
    ##
    ## This is a low-level adapter hook used by streaming body parsers.
  BodyCloseProc* = proc(): Future[void] {.closure, gcsafe, async: (raises: []).}
    ## Closes a streaming request body without raising.
  RequestBodySource* = ref object
    ## Shared, one-shot source for a request body supplied by an HTTP adapter.
    read: BodyReadProc
    close: BodyCloseProc
    consumed: bool
    closed: bool

  HttpMethod* {.pure.} = enum ## HTTP methods supported by fastnim routing.
    Get = "GET"
    Post = "POST"
    Put = "PUT"
    Patch = "PATCH"
    Delete = "DELETE"
    Head = "HEAD"
    Options = "OPTIONS"
    Query = "QUERY"

  HttpStatus* = enum ## Standard HTTP response status codes.
    statusContinue = 100
    statusSwitchingProtocols = 101
    statusProcessing = 102
    statusEarlyHints = 103
    statusCreated = 201
    statusAccepted = 202
    statusNonAuthoritativeInformation = 203
    statusNoContent = 204
    statusResetContent = 205
    statusPartialContent = 206
    statusMultiStatus = 207
    statusAlreadyReported = 208
    statusImUsed = 226
    statusMultipleChoices = 300
    statusMovedPermanently = 301
    statusFound = 302
    statusSeeOther = 303
    statusNotModified = 304
    statusUseProxy = 305
    statusTemporaryRedirect = 307
    statusPermanentRedirect = 308
    statusBadRequest = 400
    statusUnauthorized = 401
    statusPaymentRequired = 402
    statusForbidden = 403
    statusNotFound = 404
    statusMethodNotAllowed = 405
    statusNotAcceptable = 406
    statusProxyAuthenticationRequired = 407
    statusRequestTimeout = 408
    statusConflict = 409
    statusGone = 410
    statusLengthRequired = 411
    statusPreconditionFailed = 412
    statusContentTooLarge = 413
    statusUriTooLong = 414
    statusUnsupportedMediaType = 415
    statusRangeNotSatisfiable = 416
    statusExpectationFailed = 417
    statusImATeapot = 418
    statusMisdirectedRequest = 421
    statusUnprocessableContent = 422
    statusLocked = 423
    statusFailedDependency = 424
    statusTooEarly = 425
    statusUpgradeRequired = 426
    statusPreconditionRequired = 428
    statusTooManyRequests = 429
    statusRequestHeaderFieldsTooLarge = 431
    statusUnavailableForLegalReasons = 451
    statusInternalServerError = 500
    statusNotImplemented = 501
    statusBadGateway = 502
    statusServiceUnavailable = 503
    statusGatewayTimeout = 504
    statusHttpVersionNotSupported = 505
    statusVariantAlsoNegotiates = 506
    statusInsufficientStorage = 507
    statusLoopDetected = 508
    statusNotExtended = 510
    statusNetworkAuthenticationRequired = 511

  Headers* = Table[string, string] ## HTTP header mapping with lowercase names.

  Request* = object
    ## An incoming HTTP request after route matching.
    ## ``method`` holds the request method.
    `method`*: HttpMethod ## Request method.
    path*: string ## Request path without the query string.
    pathParams*: Table[string, string] ## ``{name}`` segments matched by the route.
    queryParams*: Table[string, string] ## Decoded query parameters.
    headers*: Headers ## Request headers with lowercase names.
    body*: string ## Buffered raw body; empty for streaming multipart requests.
    context*: Context ## Application-scoped values for handlers.
    bodySource: RequestBodySource

  Response* = object ## A complete HTTP response ready for the Chronos adapter to send.
    status*: int ## HTTP status code.
    headers*: Headers ## Response headers with lowercase names.
    body*: string ## Inline response body, empty for streamed files.
    sendFile*: string
      ## When non-empty, the Chronos adapter streams this file instead of
      ## ``body``. ``fileOffset`` and ``fileLength`` select the byte range to
      ## send (``fileLength < 0`` streams to end of file). In-process
      ## ``app.handle`` calls return the marker without reading the file.
    fileOffset*: int64 ## First byte of ``sendFile`` to stream.
    fileLength*: int64 ## Number of ``sendFile`` bytes to stream, or -1 to the end.

  ServerSentEvent* = object ## One message in a Server-Sent Events response.
    data*: string ## Event payload, split across ``data:`` lines on the wire.
    event*: string ## Optional event name, omitted when empty.
    id*: string ## Optional event ID for client-side replay, omitted when empty.
    retry*: int ## Reconnection delay in milliseconds, omitted when negative.

proc decodeComponent(value: string): string =
  decodeUrl(value.replace("+", " "))

proc parseQuery*(query: string): Table[string, string] =
  ## Splits a query string or form body into decoded fields.
  ##
  ## Also used by ``params/extract`` to decode form request bodies.
  result = initTable[string, string]()
  for field in query.split('&'):
    if field.len > 0:
      let separator = field.find('=')
      if separator < 0:
        result[decodeComponent(field)] = ""
      else:
        result[decodeComponent(field[0 ..< separator])] =
          decodeComponent(field[separator + 1 ..^ 1])

proc initRequest*(
    `method`: HttpMethod,
    target: string,
    headers: Headers = initTable[string, string](),
    body = "",
): Request =
  ## Creates a request value. ``target`` may include a query string.
  let separator = target.find('?')
  result = Request(
    `method`: `method`,
    pathParams: initTable[string, string](),
    headers: headers,
    body: body,
    context: newContext(),
  )
  if separator < 0:
    result.path = target
    result.queryParams = initTable[string, string]()
  else:
    result.path = target[0 ..< separator]
    result.queryParams = parseQuery(target[separator + 1 ..^ 1])

proc newRequestBodySource*(
    read: BodyReadProc, close: BodyCloseProc
): RequestBodySource =
  ## Creates a one-shot streaming body source for an HTTP adapter.
  RequestBodySource(read: read, close: close)

proc attachBodySource*(
    request: var Request, source: RequestBodySource
) {.inline, raises: [].} =
  ## Attaches a streaming body source. Intended for HTTP adapter implementations.
  request.bodySource = source

proc hasBodySource*(request: Request): bool {.inline, raises: [].} =
  ## Returns whether the request body is available as an unread stream.
  not request.bodySource.isNil and not request.bodySource.consumed

proc beginBodyRead*(request: Request): RequestBodySource =
  ## Claims and returns the request's one-shot streaming body source.
  ##
  ## Raises ``ValueError`` when the source was already consumed or unavailable.
  if request.bodySource.isNil:
    raise newException(ValueError, "request does not have a streaming body")
  if request.bodySource.consumed:
    raise newException(ValueError, "request body has already been consumed")
  request.bodySource.consumed = true
  request.bodySource

proc readChunk*(
    source: RequestBodySource, maxBytes: Positive
): Future[string] {.async: (raises: [CatchableError]).} =
  ## Reads the next body chunk, returning an empty string at end of input.
  return await source.read(maxBytes)

proc closeBodySource*(request: Request): Future[void] {.async: (raises: []).} =
  ## Closes an attached request body source. Calling it more than once is safe.
  if not request.bodySource.isNil and not request.bodySource.closed and
      not request.bodySource.close.isNil:
    request.bodySource.closed = true
    await request.bodySource.close()

proc initResponse*(
    body = "", headers: Headers = initTable[string, string]()
): Response =
  ## Creates a 200 HTTP response. Text responses default to UTF-8 plain text.
  result = Response(status: 200, headers: headers, body: body)
  if "content-type" notin result.headers:
    result.headers["content-type"] = "text/plain; charset=utf-8"

proc statusCode*(status: HttpStatus): int {.inline, raises: [].} =
  ## Returns the numeric wire value for a named HTTP status.
  ord(status)

macro defineStatusResponse(name: untyped, code: static[int]): untyped =
  let exportedName = nnkPostfix.newTree(ident("*"), name)
  result = quote do:
    template `exportedName`(model: untyped): Response =
      ## Creates a JSON response using the corresponding HTTP status.
      response(`code`, model)

defineStatusResponse(ok, 200)
template ok*(responseType: typedesc[Response], model: untyped): Response =
  ## Supports command-style ``ok %*{...}`` inside route blocks.
  response(200, model)
defineStatusResponse(created, 201)
defineStatusResponse(accepted, 202)
defineStatusResponse(switchingProtocols, 101)
defineStatusResponse(processing, 102)
defineStatusResponse(earlyHints, 103)
defineStatusResponse(nonAuthoritativeInformation, 203)
defineStatusResponse(resetContent, 205)
defineStatusResponse(partialContent, 206)
defineStatusResponse(multiStatus, 207)
defineStatusResponse(alreadyReported, 208)
defineStatusResponse(imUsed, 226)
defineStatusResponse(multipleChoices, 300)
defineStatusResponse(movedPermanently, 301)
defineStatusResponse(found, 302)
defineStatusResponse(seeOther, 303)
defineStatusResponse(notModified, 304)
defineStatusResponse(temporaryRedirect, 307)
defineStatusResponse(permanentRedirect, 308)
defineStatusResponse(badRequest, 400)
defineStatusResponse(unauthorized, 401)
defineStatusResponse(paymentRequired, 402)
defineStatusResponse(forbidden, 403)
defineStatusResponse(notFound, 404)
defineStatusResponse(methodNotAllowed, 405)
defineStatusResponse(notAcceptable, 406)
defineStatusResponse(proxyAuthenticationRequired, 407)
defineStatusResponse(requestTimeout, 408)
defineStatusResponse(conflict, 409)
defineStatusResponse(gone, 410)
defineStatusResponse(lengthRequired, 411)
defineStatusResponse(preconditionFailed, 412)
defineStatusResponse(contentTooLarge, 413)
defineStatusResponse(uriTooLong, 414)
defineStatusResponse(unsupportedMediaType, 415)
defineStatusResponse(rangeNotSatisfiable, 416)
defineStatusResponse(expectationFailed, 417)
defineStatusResponse(imATeapot, 418)
defineStatusResponse(misdirectedRequest, 421)
defineStatusResponse(unprocessableContent, 422)
defineStatusResponse(locked, 423)
defineStatusResponse(failedDependency, 424)
defineStatusResponse(tooEarly, 425)
defineStatusResponse(upgradeRequired, 426)
defineStatusResponse(preconditionRequired, 428)
defineStatusResponse(tooManyRequests, 429)
defineStatusResponse(requestHeaderFieldsTooLarge, 431)
defineStatusResponse(unavailableForLegalReasons, 451)
defineStatusResponse(internalServerError, 500)
defineStatusResponse(notImplemented, 501)
defineStatusResponse(badGateway, 502)
defineStatusResponse(serviceUnavailable, 503)
defineStatusResponse(gatewayTimeout, 504)
defineStatusResponse(httpVersionNotSupported, 505)
defineStatusResponse(variantAlsoNegotiates, 506)
defineStatusResponse(insufficientStorage, 507)
defineStatusResponse(loopDetected, 508)
defineStatusResponse(notExtended, 510)
defineStatusResponse(networkAuthenticationRequired, 511)

proc initResponse*(
    status: HttpStatus, body = "", headers: Headers = initTable[string, string]()
): Response =
  ## Creates a response with a named HTTP status first.
  result = initResponse(body, headers)
  result.status = statusCode(status)

proc sseEvent*(data: string, event = "", id = "", retry = -1): ServerSentEvent =
  ## Creates a Server-Sent Event. ``retry`` is omitted when it is negative.
  if '\r' in event or '\n' in event or '\r' in id or '\n' in id:
    raise newException(ValueError, "SSE event names and IDs cannot contain line breaks")
  if retry < -1:
    raise newException(ValueError, "SSE retry must be non-negative")
  ServerSentEvent(data: data, event: event, id: id, retry: retry)

proc formatSseEvent*(event: ServerSentEvent): string =
  ## Encodes an event using the Server-Sent Events wire format.
  if event.id.len > 0:
    result.add("id: " & event.id & "\n")
  if event.event.len > 0:
    result.add("event: " & event.event & "\n")
  if event.retry >= 0:
    result.add("retry: " & $event.retry & "\n")
  for line in event.data.splitLines():
    result.add("data: " & line & "\n")
  if event.data.len == 0:
    result.add("data:\n")
  result.add('\n')

proc eventStream*(events: openArray[ServerSentEvent]): Response =
  ## Creates a finite Server-Sent Events response.
  for event in events:
    result.body.add(formatSseEvent(event))
  result.status = 200
  result.headers = initTable[string, string]()
  result.headers["content-type"] = "text/event-stream; charset=utf-8"
  result.headers["cache-control"] = "no-cache"

proc eventStream*(status: HttpStatus, events: openArray[ServerSentEvent]): Response =
  ## Creates a finite SSE response with the named status first.
  result = eventStream(events)
  result.status = statusCode(status)

proc setHeader*(response: var Response, name, value: string) {.raises: [].} =
  ## Sets a response header before the response is returned.
  response.headers[name.toLowerAscii()] = value

proc text*(body: string): Response =
  ## Creates a UTF-8 plain-text response.
  initResponse(body)

proc text*(status: HttpStatus, body: string): Response =
  ## Creates a plain-text response with a named HTTP status first.
  initResponse(status, body)

proc html*(body: string): Response =
  ## Creates a UTF-8 HTML response.
  ##
  ## ```nim
  ## app.get("/"):
  ##   html "<h1>Hello from FastNim</h1>"
  ## ```
  ##
  ## Template libraries such as Karax render server-side markup to a plain
  ## string; stringify the node (for example with ``$node``) and pass it here.
  result = initResponse(body)
  result.headers["content-type"] = "text/html; charset=utf-8"

proc html*(status: HttpStatus, body: string): Response =
  ## Creates an HTML response with a named HTTP status first.
  result = initResponse(status, body)
  result.headers["content-type"] = "text/html; charset=utf-8"

proc json*(body: string): Response =
  ## Creates a JSON response. ``body`` must already contain valid JSON.
  result = initResponse(body)
  result.headers["content-type"] = "application/json; charset=utf-8"

proc json*(body: JsonNode): Response =
  ## Creates a JSON response from a value built with ``%*``.
  json($body)

proc json*(status: HttpStatus, body: JsonNode): Response =
  ## Creates a JSON response from a JSON node with status first.
  result = initResponse(status, $body)
  result.headers["content-type"] = "application/json; charset=utf-8"

proc json*[T](body: T): Response =
  ## Creates a JSON response from any ``%*``-serializable value.
  ##
  ## ```nim
  ## userRouter.get("/list", responses = @[(200, seq[User])]):
  ##   let users = @[User(name: "Alice", age: 30)]
  ##   json users
  ## ```
  ##
  ## ``{key: value}`` pair arrays with string keys become JSON objects:
  ##
  ## ```nim
  ## app.get("/items/{itemId}"):
  ##   json {"itemId": request.pathParam("itemId")}
  ## ```
  ##
  ## All pair values must share one type; mix types with ``%*`` instead.
  when compiles(body[0]) and compiles(body[0][0]) and compiles(body[0][1]):
    when typeof(body[0][0]) is string:
      var node = newJObject()
      for (key, value) in body:
        node[key] = toJsonValue(value)
      json(node)
    else:
      json(toJsonValue(body))
  else:
    json(toJsonValue(body))

proc json*[V](body: Table[string, V]): Response =
  ## Creates a JSON object response from a string-keyed table.
  var node = newJObject()
  for key, value in body:
    node[key] = toJsonValue(value)
  json(node)

proc response*[T](status: int, model: T): Response =
  ## Serializes a typed response model as JSON with ``status``.
  result = initResponse(body = $toJsonValue(model))
  result.status = status
  result.setHeader("content-type", "application/json; charset=utf-8")

proc response*(status: int, model: JsonNode): Response {.raises: [].} =
  ## Creates a JSON response from an already-encoded JSON value.
  result = initResponse(body = $model)
  result.status = status
  result.setHeader("content-type", "application/json; charset=utf-8")

proc response*[T](status: HttpStatus, model: T): Response =
  ## Serializes a typed response model using a named HTTP status.
  json(status, toJsonValue(model))

proc respondOk*[T](model: T): Response =
  ## Creates a 200 response from a typed JSON model.
  response(200, model)

proc created*[T](model: T): Response =
  ## Creates a 201 response from a typed JSON model.
  response(201, model)

proc badRequest*[T](model: T): Response =
  ## Creates a 400 response from a typed JSON model.
  response(400, model)

proc conflict*[T](model: T): Response =
  ## Creates a 409 response from a typed JSON model.
  response(409, model)

proc unprocessableEntity*[T](model: T): Response =
  ## Creates a 422 response from a typed JSON model.
  response(422, model)

proc notFound*[T](model: T): Response =
  ## Creates a 404 response from a typed JSON model.
  response(404, model)

macro noContent*(value: untyped): untyped =
  ## Creates an empty 204 response. Use as ``noContent void`` in a typed route.
  if not (value.kind == nnkIdent and eqIdent(value, "void")):
    error("noContent expects `void`", value)
  quote:
    initResponse(statusNoContent)

template checkedResponse*[T](status: static[int], model: typed): Response =
  ## Creates a response only when ``model`` has the route-declared type ``T``.
  when typeof(model) is T:
    response(status, model)
  else:
    {.error: "response model does not match the type declared for this status".}

proc toResponse*(value: Response): Response {.inline, raises: [].} =
  ## Leaves an explicit response unchanged.
  value

proc toResponse*(value: string): Response {.inline, raises: [].} =
  ## Converts a route's string result into a text response.
  text(value)

proc toResponse*(value: JsonNode): Response {.inline, raises: [].} =
  ## Converts a route's ``%*`` JSON value into a JSON response.
  json(value)

proc notFound*(): Response =
  ## Creates the framework's default 404 response.
  text(statusNotFound, "Not Found")

proc isFileResponse*(response: Response): bool {.inline, raises: [].} =
  ## Returns whether the Chronos adapter should stream ``sendFile``
  ## instead of sending ``body`` inline.
  response.sendFile.len > 0
