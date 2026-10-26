## HTMX request details and response headers.
##
## ``htmxPlugin()`` and ``htmxPlugin(version = 2)`` select the htmx 2 headers.
## ``htmxPlugin(version = 4)`` selects the htmx 4 headers. A helper that the
## selected version does not send is a compile error. Helpers that exist in
## both versions can be used before the plugin is selected.
##
## The plugin also adds ``Vary: HX-Request`` so caches can keep full pages
## and fragments apart.

import std/[json, macros, strutils, uri]

import chronos

import ../context/http, ../params/extract, ../plugin, ../routing/router

type HtmxTriggerTiming* {.pure.} = enum
  ## When the browser should run an ``HX-Trigger`` event.
  Receive ## ``HX-Trigger``, as the response is received.
  Settle ## ``HX-Trigger-After-Settle``, after the settle phase.
  Swap ## ``HX-Trigger-After-Swap``, after the swap.

proc htmxFlag(request: Request, name: string): bool {.inline.} =
  request.header(name) == "true"

proc isHtmx*(request: Request): bool {.inline.} =
  ## Returns whether this request was made by HTMX.
  request.htmxFlag("hx-request")

proc htmxBoosted*(request: Request): bool {.inline.} =
  ## Returns whether the request came from an element with ``hx-boost``.
  request.htmxFlag("hx-boosted")

proc htmxCurrentUrl*(request: Request): string {.inline.} =
  ## Returns ``HX-Current-URL``, or an empty string when it is absent.
  request.header("hx-current-url")

proc htmxCurrentUrlPath*(request: Request): string =
  ## Returns the path and query of ``HX-Current-URL``.
  let current = request.htmxCurrentUrl
  if current.len == 0:
    return ""
  let parsed = parseUri(current)
  result = parsed.path
  if parsed.query.len > 0:
    result.add '?'
    result.add parsed.query

proc htmxHistoryRestoreRequest*(request: Request): bool {.inline.} =
  ## Returns whether HTMX is restoring this request from its history cache.
  request.htmxFlag("hx-history-restore-request")

proc htmxTarget*(request: Request): string {.inline.} =
  ## Returns ``HX-Target``.
  ##
  ## htmx 2 sends the element id. htmx 4 sends ``tag#id``, which
  ## ``htmxTargetTag`` and ``htmxTargetId`` split.
  request.header("hx-target")

proc htmxPromptImpl(request: Request): string {.inline.} =
  request.header("hx-prompt")

proc htmxTriggerImpl(request: Request): string {.inline.} =
  request.header("hx-trigger")

proc htmxTriggerNameImpl(request: Request): string {.inline.} =
  request.header("hx-trigger-name")

proc htmxSourceImpl(request: Request): string {.inline.} =
  request.header("hx-source")

proc htmxRequestTypeImpl(request: Request): string {.inline.} =
  request.header("hx-request-type")

proc htmxElementParts(raw: string): tuple[tag, id: string] =
  let hash = raw.find('#')
  if hash < 0:
    return (raw, "")
  (raw[0 ..< hash], raw[hash + 1 .. ^1])

proc requireText(value, label: string) =
  if value.len == 0:
    raise newException(ValueError, label & " cannot be empty")

proc htmxHeaderResponse(status: int, name, value: string): Response =
  result = initResponse()
  result.status = status
  result.setHeader(name, value)

proc htmxRedirect*(url: string): Response =
  ## Creates a response that makes HTMX navigate the browser to ``url``.
  requireText(url, "HTMX redirect URL")
  htmxHeaderResponse(200, "HX-Redirect", url)

proc htmxRefresh*(): Response =
  ## Creates a response that makes HTMX reload the current page.
  htmxHeaderResponse(200, "HX-Refresh", "true")

proc htmxLocation*(url: string): Response =
  ## Creates a response that asks HTMX for an ``hx-boost`` style navigation.
  requireText(url, "HTMX location URL")
  htmxHeaderResponse(200, "HX-Location", url)

proc htmxLocation*(spec: JsonNode): Response =
  ## Creates an ``HX-Location`` response from a JSON object.
  ##
  ## HTMX accepts ``path``, ``target``, ``swap``, and the other location fields.
  if spec.kind != JObject:
    raise newException(ValueError, "HTMX location must be a JSON object")
  htmxHeaderResponse(200, "HX-Location", $spec)

proc htmxStopPolling*(): Response =
  ## Creates the ``286`` response HTMX uses to stop polling.
  result = initResponse()
  result.status = 286

proc setHtmxHeader(response: var Response, name, value: string) =
  requireText(value, name)
  response.setHeader(name, value)

proc htmxPushUrl*(response: var Response, url: string) =
  ## Sets ``HX-Push-Url`` so HTMX pushes ``url`` into browser history.
  setHtmxHeader(response, "HX-Push-Url", url)

proc htmxReplaceUrl*(response: var Response, url: string) =
  ## Sets ``HX-Replace-Url`` so HTMX replaces the current history entry.
  setHtmxHeader(response, "HX-Replace-Url", url)

proc htmxReswap*(response: var Response, strategy: string) =
  ## Sets ``HX-Reswap`` to override how HTMX swaps this response.
  setHtmxHeader(response, "HX-Reswap", strategy)

proc htmxRetarget*(response: var Response, target: string) =
  ## Sets ``HX-Retarget`` to override the element HTMX swaps.
  setHtmxHeader(response, "HX-Retarget", target)

proc htmxReselect*(response: var Response, selector: string) =
  ## Sets ``HX-Reselect`` so HTMX swaps only the matching part of the response.
  setHtmxHeader(response, "HX-Reselect", selector)

proc triggerHeader(after: HtmxTriggerTiming): string =
  case after
  of HtmxTriggerTiming.Receive: "HX-Trigger"
  of HtmxTriggerTiming.Settle: "HX-Trigger-After-Settle"
  of HtmxTriggerTiming.Swap: "HX-Trigger-After-Swap"

proc existingTriggers(raw: string): JsonNode =
  if raw.len == 0:
    return newJObject()
  try:
    let parsed = parseJson(raw)
    if parsed.kind == JObject:
      return parsed
  except JsonParsingError:
    discard
  result = newJObject()
  result[raw] = newJNull()

proc htmxTriggerImpl(
    response: var Response,
    name: string,
    params: JsonNode = nil,
    after = HtmxTriggerTiming.Receive,
) =
  ## Adds a client event to ``HX-Trigger`` or one of its after-swap headers.
  ##
  ## A single event with no parameters is sent as the event name. Further
  ## events are merged into a JSON object, which is how HTMX accepts several
  ## events on one response.
  requireText(name, "HTMX event name")
  let header = triggerHeader(after)
  let current = response.headers.getOrDefault(header)
  if current.len == 0 and params.isNil:
    response.setHeader(header, name)
    return
  var events = existingTriggers(current)
  if params.isNil:
    events[name] = newJNull()
  else:
    events[name] = params
  response.setHeader(header, $events)

proc addVary(response: var Response, name: string) =
  let current = response.headers.getOrDefault("vary")
  for value in current.split(','):
    if value.strip().toLowerAscii() == name.toLowerAscii():
      return
  if current.len == 0:
    response.setHeader("vary", name)
  else:
    response.setHeader("vary", current & ", " & name)

proc htmxMiddleware(): Middleware =
  result = proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    result = await next(request)
    addVary(result, "HX-Request")

proc initHtmxPlugin(version: int): Plugin =
  initPlugin(
    "htmx",
    $version,
    proc(app: Application) =
      app.addMiddleware(htmxMiddleware()),
  )

var htmxVersion {.compileTime.} = 0

proc v2Only(helper, detail: string): string {.compileTime.} =
  if htmxVersion == 4:
    helper & " is not available for htmx 4. " & detail
  else:
    if htmxVersion == 0:
      htmxVersion = 2
    ""

proc v4Only(helper, detail: string): string {.compileTime.} =
  if htmxVersion == 4:
    ""
  else:
    helper & " is not available for htmx " & $(if htmxVersion == 0: 2 else: htmxVersion) &
      ". " & detail

macro htmxV2(anchor: typed, helper: static[string], detail: static[string]): untyped =
  let problem = v2Only(helper, detail)
  if problem.len > 0:
    error(problem, anchor)
  result = newEmptyNode()

macro htmxV4(anchor: typed, helper: static[string], detail: static[string]): untyped =
  let problem = v4Only(helper, detail)
  if problem.len > 0:
    error(problem, anchor)
  result = newEmptyNode()

template htmxPrompt*(request: Request): string =
  ## Returns the user's reply to ``hx-prompt``. htmx 2 only.
  ##
  ## htmx 4 sends this header from the ``hx-prompt`` extension.
  htmxV2(
    request,
    "htmxPrompt",
    "htmx 4 does not send HX-Prompt unless the hx-prompt extension is loaded.",
  )
  htmxPromptImpl(request)

template htmxTrigger*(request: Request): string =
  ## Returns the id of the element that triggered the request. htmx 2 only.
  ##
  ## htmx 4 sends that element as ``HX-Source``. Use ``htmxSource``.
  htmxV2(
    request,
    "htmxTrigger",
    "htmx 4 sends the triggering element as HX-Source. Use htmxSource.",
  )
  htmxTriggerImpl(request)

template htmxTriggerName*(request: Request): string =
  ## Returns the ``name`` of the element that triggered the request. htmx 2 only.
  ##
  ## htmx 4 folds this into ``HX-Source``. Use ``htmxSource``.
  htmxV2(
    request,
    "htmxTriggerName",
    "htmx 4 does not send HX-Trigger-Name. Use htmxSource.",
  )
  htmxTriggerNameImpl(request)

template htmxSource*(request: Request): string =
  ## Returns ``HX-Source`` in ``tag#id`` form. htmx 4 only.
  htmxV4(
    request,
    "htmxSource",
    "Select htmx 4 with htmxPlugin(version = 4). htmx 2 sends the element id in HX-Trigger.",
  )
  htmxSourceImpl(request)

template htmxSourceTag*(request: Request): string =
  ## Returns the tag from ``HX-Source``, such as ``button`` in ``button#save``.
  ## htmx 4 only.
  htmxV4(
    request,
    "htmxSourceTag",
    "Select htmx 4 with htmxPlugin(version = 4).",
  )
  htmxElementParts(htmxSourceImpl(request)).tag

template htmxSourceId*(request: Request): string =
  ## Returns the id from ``HX-Source``, such as ``save`` in ``button#save``.
  ## htmx 4 only.
  htmxV4(
    request,
    "htmxSourceId",
    "Select htmx 4 with htmxPlugin(version = 4).",
  )
  htmxElementParts(htmxSourceImpl(request)).id

template htmxRequestType*(request: Request): string =
  ## Returns ``HX-Request-Type``: ``partial`` or ``full``. htmx 4 only.
  htmxV4(
    request,
    "htmxRequestType",
    "Select htmx 4 with htmxPlugin(version = 4). htmx 2 does not send HX-Request-Type.",
  )
  htmxRequestTypeImpl(request)

template htmxTargetTag*(request: Request): string =
  ## Returns the tag from htmx 4's ``HX-Target`` value. htmx 4 only.
  htmxV4(
    request,
    "htmxTargetTag",
    "Select htmx 4 with htmxPlugin(version = 4). htmx 2 sends the target id in HX-Target.",
  )
  htmxElementParts(request.htmxTarget).tag

template htmxTargetId*(request: Request): string =
  ## Returns the id from htmx 4's ``HX-Target`` value. htmx 4 only.
  htmxV4(
    request,
    "htmxTargetId",
    "Select htmx 4 with htmxPlugin(version = 4). htmx 2 sends the target id in HX-Target.",
  )
  htmxElementParts(request.htmxTarget).id

proc triggerNodeIsReceive(node: NimNode): bool =
  case node.kind
  of nnkIntLit, nnkUIntLit:
    node.intVal == 0
  of nnkSym, nnkIdent, nnkOpenSymChoice:
    node.eqIdent("Receive")
  of nnkDotExpr, nnkHiddenStdConv, nnkConv, nnkCast, nnkObjConstr:
    triggerNodeIsReceive(node[^1])
  else:
    false

macro rejectDelayedTrigger(after: typed): untyped =
  if not triggerNodeIsReceive(after):
    if htmxVersion == 4:
      error(
        "HX-Trigger-After-Settle and HX-Trigger-After-Swap are not available for htmx 4. htmx 4 only sends HX-Trigger, which runs after the swap.",
        after,
      )
    elif htmxVersion == 0:
      htmxVersion = 2
  result = newEmptyNode()

template htmxTrigger*(
    response: var Response,
    name: string,
    params: JsonNode = nil,
    after = HtmxTriggerTiming.Receive,
) =
  ## Adds a client event to ``HX-Trigger``.
  ##
  ## ``HtmxTriggerTiming.Settle`` and ``Swap`` set the htmx 2 after-swap
  ## headers. htmx 4 removed those headers, so those timings are a compile
  ## error after ``htmxPlugin(version = 4)``.
  rejectDelayedTrigger(after)
  htmxTriggerImpl(response, name, params, after)

proc bindHtmxVersion(version: int): NimNode {.compileTime.} =
  if htmxVersion != 0 and htmxVersion != version:
    error(
      "htmxPlugin(version = " & $version &
        ") conflicts with htmx " & $htmxVersion &
        " helpers already used. Call htmxPlugin before those helpers."
    )
  htmxVersion = version
  let versionNode = newLit(version)
  quote do:
    initHtmxPlugin(`versionNode`)

macro htmxPlugin*(version: static[int]): untyped =
  ## Selects the htmx 2 or htmx 4 header set and installs ``Vary: HX-Request``.
  ##
  ## ``htmxPlugin(version = 4)`` makes htmx 2 helpers such as ``htmxPrompt``
  ## and ``htmxTriggerName`` a compile error. ``htmxPlugin(version = 2)`` does
  ## the same for ``htmxSource`` and ``htmxRequestType``.
  if version notin {2, 4}:
    error("htmxPlugin version must be 2 or 4, got " & $version)
  bindHtmxVersion(version)

macro htmxPlugin*(): untyped =
  ## Selects htmx 2 and installs ``Vary: HX-Request``.
  result = quote do:
    htmxPlugin(2)
