## Datastar hypermedia plugin for FastNim applications.
##
## Implements the Nim server SDK for [Datastar](https://data-star.dev/):
## `datastar-patch-elements` and `datastar-patch-signals` Server-Sent Events
## plus inbound signal reading (`?datastar=<json>` on GET/DELETE, JSON body
## otherwise), following the official SDK specification.
##
## Events are SSE-native: every builder returns a ``DatastarEvent`` that
## converts implicitly to ``ServerSentEvent``, so existing streaming keeps
## working:
##
## ```nim
## app.sse("/counter"):
##   await send(patchElements("""<div id="count">1</div>"""))
##   await patchSignals(%*{"count": 2}).send(send)
##   await patchElements("""<div id="count">3</div>""").send()
## ```
##
## Install ``datastarPlugin`` to auto-inject the Datastar CDN ``<script>``
## tag into HTML responses, so handlers never need to add it by hand.

import chronos
from chronos/apps/http/httpserver import HttpWriteError
import std/[json, jsonutils, strutils, tables]

import fastnim/[context/http, params/extract, plugin, routing/router]

const
  DatastarKey* = "datastar"
    ## Request key carrying signals: query param on GET/DELETE, JSON body otherwise.
  DatastarPatchElements* = "datastar-patch-elements"
    ## SSE event type that patches HTML elements into the DOM.
  DatastarPatchSignals* = "datastar-patch-signals"
    ## SSE event type that patches signals into the client signal store.
  DatastarDefaultRetryMs* = 1000
    ## Datastar client reconnect delay; omitted from the wire when default.
  DatastarCdnUrl* = "https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0/bundles/datastar.js"
    ## Default Datastar client bundle injected into HTML responses.

type
  DatastarPatchMode* {.pure.} = enum
    ## How incoming HTML is merged into the DOM.
    Outer = "outer" ## Morphs the outer HTML (default, recommended).
    Inner = "inner" ## Morphs the inner HTML of the target.
    Remove = "remove" ## Removes the target elements.
    Replace = "replace" ## Replaces the outer HTML of the target.
    Prepend = "prepend" ## Prepends to the target's children.
    Append = "append" ## Appends to the target's children.
    Before = "before" ## Inserts before the target as siblings.
    After = "after" ## Inserts after the target as siblings.

  DatastarNamespace* {.pure.} = enum
    ## DOM namespace used when patching elements.
    Html = "html" ## Regular HTML (default, omitted on the wire).
    Svg = "svg" ## Patches into the DOM using the SVG namespace.
    MathMl = "mathml" ## Patches into the DOM using the MathML namespace.

  DatastarEvent* = object
    ## One Datastar SSE event. Converts implicitly to ``ServerSentEvent``.
    sse*: ServerSentEvent

  DatastarOptions* = object
    ## Configuration installed by ``datastarPlugin``.
    cdnUrl*: string ## Client bundle URL injected into HTML responses.
    injectCdn*: bool ## Inject the CDN script tag when true (default).

proc toSseEvent*(event: DatastarEvent): ServerSentEvent {.inline.} =
  ## Returns the underlying ``ServerSentEvent`` for ``event``.
  event.sse

converter toServerSentEvent*(event: DatastarEvent): ServerSentEvent {.inline.} =
  ## Lets ``await send(patchElements(...))`` type-check against ``SseSend``.
  event.sse

proc toSseEvents*(events: openArray[DatastarEvent]): seq[ServerSentEvent] =
  ## Maps Datastar events to plain SSE events for ``eventStream``.
  result = newSeq[ServerSentEvent](events.len)
  for index, event in events:
    result[index] = event.sse

proc datastarRetry(retryMs: int): int {.inline.} =
  if retryMs < 0 or retryMs == DatastarDefaultRetryMs:
    -1
  else:
    retryMs

proc checkEventId(eventId: string) =
  if '\r' in eventId or '\n' in eventId:
    raise newException(ValueError, "Datastar event ID cannot contain line breaks")

proc patchElements*(
    html: string,
    selector = "",
    mode = DatastarPatchMode.Outer,
    namespace = DatastarNamespace.Html,
    useViewTransition = false,
    viewTransitionSelector = "",
    eventId = "",
    retryMs = -1,
): DatastarEvent =
  ## Builds a ``datastar-patch-elements`` event.
  ##
  ## ``html`` must contain complete elements (ids on top-level elements so
  ## the client can morph them). Only non-default options are emitted:
  ## ``selector`` when non-empty, ``mode`` when not ``Outer``, ``namespace``
  ## when not ``Html``, ``useViewTransition`` only when true, and
  ## ``viewTransitionSelector`` only when set. Multiline ``html`` is split
  ## into one ``data: elements`` line per line, as the SSE protocol requires.
  ## ``eventId`` sets the SSE id; ``retryMs`` sets the reconnect delay
  ## unless negative or the 1000ms Datastar default (both omit it).
  checkEventId(eventId)
  var payload: seq[string] = @[]
  if selector.len > 0:
    payload.add("selector " & selector)
  if mode != DatastarPatchMode.Outer:
    payload.add("mode " & $mode)
  if namespace != DatastarNamespace.Html:
    payload.add("namespace " & $namespace)
  if useViewTransition:
    payload.add("useViewTransition true")
    if viewTransitionSelector.len > 0:
      payload.add("viewTransitionSelector " & viewTransitionSelector)
  if html.len > 0:
    for line in html.splitLines():
      payload.add("elements " & line)
  DatastarEvent(
    sse: sseEvent(
      payload.join("\n"), event = DatastarPatchElements, id = eventId,
      retry = datastarRetry(retryMs),
    )
  )

proc removeElements*(
    selector: string, eventId = "", retryMs = -1
): DatastarEvent =
  ## Builds a ``datastar-patch-elements`` event with ``mode remove``.
  ##
  ## ``selector`` is required: it selects the elements removed from the DOM.
  if selector.len == 0:
    raise newException(ValueError, "Datastar remove selector cannot be empty")
  patchElements("", selector = selector, mode = DatastarPatchMode.Remove,
    eventId = eventId, retryMs = retryMs)

proc patchSignals*(
    signals: JsonNode, onlyIfMissing = false, eventId = "", retryMs = -1
): DatastarEvent =
  ## Builds a ``datastar-patch-signals`` event from an encoded JSON value.
  ##
  ## Follows RFC 7386 merge-patch semantics: set a signal to ``null`` to
  ## remove it. ``onlyIfMissing`` patches only signals that do not exist yet.
  if signals.kind != JObject:
    raise newException(ValueError, "Datastar signals must be a JSON object")
  checkEventId(eventId)
  var payload: seq[string] = @[]
  if onlyIfMissing:
    payload.add("onlyIfMissing true")
  for line in ($signals).splitLines():
    payload.add("signals " & line)
  DatastarEvent(
    sse: sseEvent(
      payload.join("\n"), event = DatastarPatchSignals, id = eventId,
      retry = datastarRetry(retryMs),
    )
  )

proc patchSignals*(
    signals: string, onlyIfMissing = false, eventId = "", retryMs = -1
): DatastarEvent =
  ## Builds a ``datastar-patch-signals`` event from a raw JSON string.
  ##
  ## ``signals`` must encode a JSON object; anything else raises ``ValueError``.
  let node =
    try:
      parseJson(signals)
    except CatchableError:
      raise newException(ValueError, "Datastar signals must be valid JSON")
  patchSignals(node, onlyIfMissing = onlyIfMissing, eventId = eventId,
    retryMs = retryMs)

proc marshalPatchSignals*[T](
    value: T, onlyIfMissing = false, eventId = "", retryMs = -1
): DatastarEvent =
  ## Builds a ``datastar-patch-signals`` event from any ``%*``-serializable value.
  patchSignals(toJson(value), onlyIfMissing = onlyIfMissing, eventId = eventId,
    retryMs = retryMs)

proc removeSignals*(
    paths: openArray[string], eventId = "", retryMs = -1
): DatastarEvent =
  ## Builds a ``datastar-patch-signals`` event that removes ``paths``.
  ##
  ## Removal sets each path to ``null`` per RFC 7386 merge-patch semantics.
  if paths.len == 0:
    raise newException(ValueError, "Datastar removeSignals needs at least one path")
  var node = newJObject()
  for path in paths:
    if path.len == 0:
      raise newException(ValueError, "Datastar signal paths cannot be empty")
    node[path] = newJNull()
  patchSignals(node, eventId = eventId, retryMs = retryMs)

proc escapeAttribute(value: string): string =
  value.replace("&", "&amp;").replace("\"", "&quot;")

proc executeScript*(
    script: string,
    autoRemove = true,
    attributes: openArray[string] = [],
    eventId = "",
    retryMs = -1,
): DatastarEvent =
  ## Builds an event that executes JavaScript in the browser.
  ##
  ## Implemented the Datastar-recommended way: a ``datastar-patch-elements``
  ## event appending a ``<script>`` tag to ``<body>``. ``autoRemove`` adds
  ## ``data-effect="el.remove()"`` so the tag is cleaned up after execution.
  ## ``attributes`` are extra raw attribute strings (for example
  ## ``type="module"``). Never interpolate user input into ``script``: doing
  ## so creates an XSS vulnerability.
  if script.len == 0:
    raise newException(ValueError, "Datastar script cannot be empty")
  checkEventId(eventId)
  var tag = "<script"
  if autoRemove:
    tag.add(" data-effect=\"el.remove()\"")
  for attribute in attributes:
    if attribute.len > 0:
      tag.add(" " & attribute)
  tag.add(">")
  DatastarEvent(
    sse: patchElements(
      tag & script.replace("\r\n", "\n") & "</script>",
      selector = "body",
      mode = DatastarPatchMode.Append,
      eventId = eventId,
      retryMs = retryMs,
    ).sse
  )

proc redirect*(url: string, eventId = "", retryMs = -1): DatastarEvent =
  ## Builds an event that redirects the browser to ``url`` via JavaScript.
  ##
  ## The URL is JSON-encoded into the script, preventing script injection.
  if url.len == 0:
    raise newException(ValueError, "Datastar redirect URL cannot be empty")
  executeScript(
    "setTimeout(() => window.location.href = " & $(%* url) & ")",
    eventId = eventId,
    retryMs = retryMs,
  )

proc readSignals*(request: Request): JsonNode =
  ## Reads Datastar signals from ``request``.
  ##
  ## GET and DELETE requests carry URL-encoded JSON in the ``datastar`` query
  ## parameter; all other methods carry raw JSON in the request body. Returns
  ## an empty object when no signals were sent. Raises ``ValueError`` on
  ## malformed JSON.
  if request.method == HttpMethod.Get or request.method == HttpMethod.Delete:
    let raw = request.queryParam(DatastarKey)
    if raw.len == 0:
      return newJObject()
    try:
      result = parseJson(raw)
    except CatchableError:
      raise newException(ValueError, "invalid Datastar signals in query")
    if result.kind != JObject:
      raise newException(ValueError, "Datastar signals must be a JSON object")
  else:
    if request.body.len == 0:
      return newJObject()
    try:
      result = parseJson(request.body)
    except CatchableError:
      raise newException(ValueError, "invalid Datastar signals in body")
    if result.kind != JObject:
      raise newException(ValueError, "Datastar signals must be a JSON object")

proc parseSignals*[T](request: Request, value: var T): bool {.raises: [].} =
  ## Decodes Datastar signals into ``value``; returns false when absent/invalid.
  try:
    let node = readSignals(request)
    if node.len == 0:
      return false
    value = jsonTo(node, T)
    true
  except CatchableError:
    false

proc datastarScriptTag*(cdnUrl = DatastarCdnUrl): string =
  ## Renders the Datastar client ``<script>`` tag for manual page templates.
  ##
  ## Prefer installing ``datastarPlugin`` (CDN auto-injection) over calling
  ## this in every handler; keep this for custom placement or attributes.
  if cdnUrl.len == 0:
    raise newException(ValueError, "Datastar CDN URL cannot be empty")
  "<script type=\"module\" src=\"" & escapeAttribute(cdnUrl) & "\"></script>"

proc datastarStream*(
    events: openArray[DatastarEvent], status = 200
): Response =
  ## Creates a finite ``text/event-stream`` response from Datastar events.
  ##
  ## Useful for non-streaming handlers and tests; streaming handlers should
  ## use ``app.sse`` with ``await send(...)`` instead.
  eventStream(toSseEvents(events), status)

proc sendTo*(
    event: DatastarEvent, sender: SseSend
): Future[void] {.async: (raises: [CancelledError, HttpWriteError]).} =
  ## Sends ``event`` through an explicit SSE sender.
  ##
  ## ```nim
  ## app.sse("/ticker"):
  ##   await patchElements("<div>hi</div>").sendTo(send)
  ## ```
  ##
  ## Note: ``await patchElements("<div>hi</div>").send()`` also works inside
  ## ``app.sse`` blocks and anywhere a ``send`` sender is in scope. The
  ## ``DatastarEvent`` converts implicitly to ``ServerSentEvent``, so the
  ## call forwards to that sender directly.
  await sender(event.sse)

proc initDatastarOptions*(
    cdnUrl = DatastarCdnUrl, injectCdn = true
): DatastarOptions =
  ## Creates Datastar plugin configuration.
  ##
  ## ``injectCdn`` auto-inserts the ``cdnUrl`` script tag into HTML responses
  ## so handlers do not need ``datastarScriptTag``. Empty ``cdnUrl`` disables
  ## injection regardless of ``injectCdn``.
  DatastarOptions(cdnUrl: cdnUrl, injectCdn: injectCdn)

proc datastarMiddleware(options: DatastarOptions): Middleware =
  result = proc(request: Request, next: NextHandler): Response =
    result = next(request)
    if not options.injectCdn or options.cdnUrl.len == 0:
      return
    if result.sendFile.len > 0:
      return
    if not result.headers.getOrDefault("content-type", "").startsWith("text/html"):
      return
    if options.cdnUrl in result.body:
      return
    let tag = datastarScriptTag(options.cdnUrl)
    if "</head>" in result.body:
      result.body = result.body.replace("</head>", tag & "\n</head>")
    elif "</body>" in result.body:
      result.body = result.body.replace("</body>", tag & "\n</body>")
    else:
      result.body = result.body & tag

proc datastarPlugin*(
    options = initDatastarOptions(), name = "datastar", version = "0.1.0"
): Plugin =
  ## Creates the Datastar plugin.
  ##
  ## With default options it injects the Datastar CDN script tag into HTML
  ## responses. Event builders (``patchElements``, ``patchSignals``,
  ## ``executeScript``, ``redirect``) and signal readers (``readSignals``,
  ## ``parseSignals``) work without installing, but installing keeps
  ## ``installedPlugins`` consistent with the other FastNim plugins.
  initPlugin(
    name,
    version,
    proc(app: Application) =
      app.use(datastarMiddleware(options)),
  )
