## HTTP request and response values used by fastnim applications.

import std/[json, jsonutils, macros, strutils, tables, uri]

import fastnim/context/state

export tables

type
  HttpMethod* {.pure.} = enum ## HTTP methods supported by fastnim routing.
    Get = "GET"
    Post = "POST"
    Put = "PUT"
    Patch = "PATCH"
    Delete = "DELETE"
    Head = "HEAD"
    Options = "OPTIONS"
    Query = "QUERY"

  Headers* = Table[string, string] ## HTTP header mapping with lowercase names.

  Request* = object
    ## An incoming HTTP request after route matching.
    ## ``method`` holds the request method.
    `method`*: HttpMethod ## Request method.
    path*: string ## Request path without the query string.
    pathParams*: Table[string, string] ## ``{name}`` segments matched by the route.
    queryParams*: Table[string, string] ## Decoded query parameters.
    headers*: Headers ## Request headers with lowercase names.
    body*: string ## Raw request body.
    context*: Context ## Application-scoped values for handlers.

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

proc initResponse*(
    body: string = "", status = 200, headers: Headers = initTable[string, string]()
): Response =
  ## Creates an HTTP response. Text responses default to UTF-8 plain text.
  result = Response(status: status, headers: headers, body: body)
  if "content-type" notin result.headers:
    result.headers["content-type"] = "text/plain; charset=utf-8"

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

proc eventStream*(events: openArray[ServerSentEvent], status = 200): Response =
  ## Creates a finite Server-Sent Events response.
  for event in events:
    result.body.add(formatSseEvent(event))
  result.status = status
  result.headers = initTable[string, string]()
  result.headers["content-type"] = "text/event-stream; charset=utf-8"
  result.headers["cache-control"] = "no-cache"

proc setHeader*(response: var Response, name, value: string) {.raises: [].} =
  ## Sets a response header before the response is returned.
  response.headers[name.toLowerAscii()] = value

proc text*(body: string, status = 200): Response =
  ## Creates a UTF-8 plain-text response.
  initResponse(body, status)

proc html*(body: string, status = 200): Response =
  ## Creates a UTF-8 HTML response.
  ##
  ## ```nim
  ## app.get("/"):
  ##   html "<h1>Hello from FastNim</h1>"
  ## ```
  ##
  ## Template libraries such as Karax render server-side markup to a plain
  ## string; stringify the node (for example with ``$node``) and pass it here.
  result = initResponse(body, status)
  result.headers["content-type"] = "text/html; charset=utf-8"

proc json*(body: string, status = 200): Response =
  ## Creates a JSON response. ``body`` must already contain valid JSON.
  result = initResponse(body, status)
  result.headers["content-type"] = "application/json; charset=utf-8"

proc json*(body: JsonNode, status = 200): Response =
  ## Creates a JSON response from a value built with ``%*``.
  json($body, status)

proc json*[T](body: T, status = 200): Response =
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
        node[key] = toJson(value)
      json(node, status)
    else:
      json(toJson(body), status)
  else:
    json(toJson(body), status)

proc json*[V](body: Table[string, V], status = 200): Response =
  ## Creates a JSON object response from a string-keyed table.
  var node = newJObject()
  for key, value in body:
    node[key] = toJson(value)
  json(node, status)

proc response*[T](status: int, model: T): Response =
  ## Serializes a typed response model as JSON with ``status``.
  json(toJson(model), status)

proc response*(status: int, model: JsonNode): Response {.raises: [].} =
  ## Creates a JSON response from an already-encoded JSON value.
  json(model, status)

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
    initResponse(status = 204)

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
  text("Not Found", 404)

proc isFileResponse*(response: Response): bool {.inline, raises: [].} =
  ## Returns whether the Chronos adapter should stream ``sendFile``
  ## instead of sending ``body`` inline.
  response.sendFile.len > 0
