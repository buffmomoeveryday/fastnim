## Route registration and dispatch for fastnim applications.

import std/[json, logging, macrocache, macros, monotimes, sequtils, strutils, tables, times]

import chronos/[asyncloop, futures, timer, transport]
from chronos/apps/http/httpserver import HttpRequestBodyTooLargeError, HttpWriteError
from websock/websock import WebSocketError

import ../context/http
import ../context/state
import ../core/limits
import ../logging
import ../openapi/spec
import ../params/extract
import ../params/multipart
import ../params/path
import ../params/validate
import ../websocket

type
  RouteHandler* = proc(request: Request): Future[Response] {.
    closure, async: (raises: [CatchableError])
  .} ## Handles a regular HTTP request asynchronously on the Chronos event loop.
  SyncRouteHandler* =
    proc(request: Request): Response {.nimcall, raises: [CatchableError].}
    ## Legacy synchronous route handler adapted to ``RouteHandler`` at registration.
  ErrorHandler* = proc(request: Request): Response {.
    closure, gcsafe, raises: [CatchableError]
  .}
    ## Creates a response for a framework-generated HTTP error status.
  NextHandler* = proc(request: Request): Future[Response] {.
    closure, async: (raises: [CatchableError])
  .} ## Continues an HTTP request through the remaining middleware and route.
  Middleware* = proc(request: Request, next: NextHandler): Future[Response] {.
    closure, async: (raises: [CatchableError])
  .}
    ## Runs around an HTTP request. It may await ``next(request)`` or return
    ## without calling ``next`` to short-circuit the request.
  MiddlewarePhase* {.pure.} = enum ## When middleware runs relative to routing.
    BeforeRouting
    AfterRouting

  OpenApiContributor* = proc(document: var JsonNode) {.closure.}
    ## Extends the generated OpenAPI document before it is returned.
  PluginInstall* = proc(app: Application) {.closure.}
  Plugin* = object ## A named, compile-time linked FastNim extension.
    name*: string ## Unique plugin name; installing twice is an error.
    version*: string ## Plugin version recorded on the application.
    install*: PluginInstall ## Callback wiring the plugin into the application.

  PluginInfo* = object ## Identity of an extension installed on an application.
    name*: string ## Installed plugin name.
    version*: string ## Installed plugin version.

  MiddlewareRegistration = object
    phase: MiddlewarePhase
    priority: int
    order: int
    handler: Middleware

  SseSend* = proc(event: ServerSentEvent): Future[void] {.
    gcsafe, async: (raises: [CancelledError, HttpWriteError])
  .} ## Sends one event to a connected Server-Sent Events client.
  SseRouteHandler* = proc(request: Request, send: SseSend): Future[void] {.
    gcsafe, async: (raises: [CancelledError, HttpWriteError, ValueError])
  .} ## Handles an SSE route by sending events through ``send``.
  WebSocketHandler* = proc(request: Request, websocket: WebSocket): Future[void] {.
    gcsafe,
    async: (
      raises: [
        CancelledError, AsyncStreamError, WebSocketError, WebSocketDisconnectError,
        JsonParsingError, ValueError,
      ]
    )
  .} ## Handles a WebSocket route after the Chronos adapter upgrades the connection.

  RouteKind* {.pure.} = enum ## Transport a registered route serves.
    Http
    Sse
    WebSocket

  Route* = object
    ## A registered endpoint and its path template.
    ## ``method`` holds the HTTP method the route answers.
    `method`*: HttpMethod ## HTTP method the route answers.
    path*: string ## Path template with ``{name}`` or ``{name:type}`` segments.
    handler*: RouteHandler ## Handler for regular HTTP routes.
    sseHandler*: SseRouteHandler ## Handler for Server-Sent Events routes.
    websocketHandler*: WebSocketHandler ## Handler for WebSocket routes.
    kind*: RouteKind ## Transport selected by the registration macro.
    openApi*: OpenApiOperation ## Generated documentation for the route.
    routerMiddleware: seq[Middleware] ## Router-scoped middleware copied at mount time.

  Router* = ref object
    ## A mountable group of routes with a shared prefix.
    ## Register routes on a router with the same ``router.get(...)`` block
    ## syntax used for applications, then mount it with ``app.addRouter``.
    ## Routes are copied into the application at mount time, so register
    ## everything before mounting.
    prefix*: string ## Path prefix prepended to every route on mount.
    defaultTags*: seq[string] ## OpenAPI tags applied to routes without their own.
    routes: seq[Route]
    middleware: seq[MiddlewareRegistration]
    middlewareOrder: int

  Application* = ref object ## A fastnim application with routes and middleware.
    routes: seq[Route]
    middleware: seq[MiddlewareRegistration]
    middlewareOrder: int
    settings: ApplicationSettings
    context: Context
    loadHooks: seq[LifecycleHook]
    unloadHooks: seq[LifecycleHook]
    lifecycleLoaded: bool
    openApiSettings: OpenApiSettings
    plugins: seq[PluginInfo]
    pluginContexts: Table[string, Context]
    openApiContributors: seq[OpenApiContributor]
    errorHandlers*: Table[int, ErrorHandler]
      ## Custom responses for framework-generated error statuses.
    limits: RequestLimits

proc initFastNim*(
    settings: ApplicationSettings,
    openApi = initOpenApiSettings(),
    limits = initRequestLimits(),
): Application =
  ## Creates an empty application with the supplied settings.
  ##
  ## When logging is enabled and no handler is configured, logs are colorized
  ## on the console. ``limits`` caps request bodies, headers, and handler time.
  validateRequestLimits(limits)
  result = Application(
    routes: @[],
    middleware: @[],
    settings: settings,
    context: newContext(),
    loadHooks: @[],
    unloadHooks: @[],
    openApiSettings: openApi,
    plugins: @[],
    pluginContexts: initTable[string, Context](),
    openApiContributors: @[],
    errorHandlers: initTable[int, ErrorHandler](),
    limits: limits,
  )
  if result.settings.logs and result.settings.logHandler.isNil:
    result.settings.logHandler = colorConsoleLogHandler(result.settings.logLevel)

proc initFastNim*(
    logs = true,
    logHandler: LogHandler = nil,
    logLevel = lvlInfo,
    openApi = initOpenApiSettings(),
    limits = initRequestLimits(),
): Application =
  ## Creates an empty application.
  ##
  ## Set ``logs = false`` to disable framework logs, or provide ``logHandler``
  ## to send them to a custom destination. ``limits`` caps request bodies,
  ## headers, and handler time.
  initFastNim(
    initApplicationSettings(logs, logHandler, logLevel), openApi, limits
  )

proc newApplication*(
    settings: ApplicationSettings,
    openApi = initOpenApiSettings(),
    limits = initRequestLimits(),
): Application {.deprecated: "Use FastNim instead.".} =
  ## Deprecated alias for ``initFastNim``.
  initFastNim(settings, openApi, limits)

proc newApplication*(
    logs = true,
    logHandler: LogHandler = nil,
    logLevel = lvlInfo,
    openApi = initOpenApiSettings(),
    limits = initRequestLimits(),
): Application {.deprecated: "Use FastNim instead.".} =
  ## Deprecated alias for ``initFastNim``.
  initFastNim(
    initApplicationSettings(logs, logHandler, logLevel), openApi, limits
  )

proc initRouter*(prefix = "", tags: seq[string] = @[]): Router =
  ## Creates an empty router with an optional path prefix and default tags.
  ##
  ## ```nim
  ## let userRouter = initRouter(prefix = "/users", tags = @["users"])
  ## userRouter.get("/{id}"):
  ##   ok %*{"id": request.pathParam("id")}
  ## app.addRouter(userRouter)
  ## ```
  if prefix.len > 0 and prefix[0] != '/':
    raise newException(ValueError, "router prefixes must start with '/'")
  Router(prefix: prefix, defaultTags: tags, routes: @[], middleware: @[])

proc routerPrefix*(router: Router): string {.inline.} =
  ## Returns the path prefix prepended to the router's routes on mount.
  router.prefix

proc joinMountPath(prefix, path: string): string =
  ## Joins a mount prefix with a route path without producing `//`.
  if prefix.len == 0:
    return path
  if path.len == 0:
    return prefix
  var cleanPrefix = prefix
  while cleanPrefix.len > 1 and cleanPrefix[^1] == '/':
    cleanPrefix.setLen(cleanPrefix.len - 1)
  result = cleanPrefix & path
  if result.len == 0:
    return "/"

proc mergeRouterTags(callTags, routerTags, routeTags: seq[string]): seq[string] =
  ## Merges mount tags, router defaults, and per-route tags without duplicates.
  for tag in callTags & routerTags & routeTags:
    if tag notin result:
      result.add(tag)

proc insertRegistration(
    registrations: var seq[MiddlewareRegistration], registration: MiddlewareRegistration
) =
  ## Inserts middleware keeping phase/priority/registration order.
  var index = registrations.len
  for candidateIndex, candidate in registrations:
    if (registration.phase, registration.priority, registration.order) <
        (candidate.phase, candidate.priority, candidate.order):
      index = candidateIndex
      break
  registrations.insert(registration, index)

proc openApiSettings*(app: Application): OpenApiSettings {.inline.} =
  ## Returns this application's OpenAPI endpoint configuration.
  app.openApiSettings

proc requestLimits*(app: Application): lent RequestLimits =
  ## Returns the request limits used for new requests.
  app.limits

proc configureRequestLimits*(app: Application, limits: RequestLimits) =
  ## Replaces this application's request limits.
  ##
  ## ``serve`` captures transport, capacity, body-rate, and protocol-specific
  ## limits when the server starts. Configure them before serving. Values must
  ## satisfy the validation contract documented by ``initRequestLimits``.
  validateRequestLimits(limits)
  app.limits = limits

proc configureOpenApi*(app: Application, settings: OpenApiSettings) =
  ## Configures this application's OpenAPI and Swagger UI endpoints.
  ##
  ## This is primarily used by ``openApiPlugin``. It can also be used by
  ## applications that need to configure OpenAPI from their own plugin.
  app.openApiSettings = settings

proc context*(app: Application): Context {.inline.} =
  ## Returns the application-scoped context used by route handlers.
  app.context

proc onLoad*(app: Application, hook: LifecycleHook) =
  ## Registers a hook run once before the application starts serving.
  app.loadHooks.add(hook)

proc onUnload*(app: Application, hook: LifecycleHook) =
  ## Registers a hook run when ``app.unload`` is called.
  app.unloadHooks.add(hook)

const DependencySchemas = CacheTable"fastnim.application.dependencies.v1"

proc applicationKey(app: NimNode): string {.compileTime.} =
  if app.kind != nnkSym:
    error("dependencies and routes must use a named application", app)
  app.signatureHash

proc schemaFields(schema: NimNode): NimNode {.compileTime.} =
  let typeImpl = schema.getTypeImpl
  if typeImpl.kind != nnkBracketExpr or typeImpl.len != 2:
    error("dependencies expects an object type", schema)
  let objectType = typeImpl[1].getTypeImpl
  if objectType.kind != nnkObjectTy:
    error("dependencies expects an object type", schema)

  result = newNimNode(nnkBracket)
  let fields = objectType[2]
  for definition in fields:
    if definition.kind != nnkIdentDefs:
      error("dependency schemas only support ordinary object fields", definition)
    let fieldType = definition[^2]
    for index in 0 ..< definition.len - 2:
      let field = definition[index]
      result.add(newTree(nnkTupleConstr, newLit($field), fieldType))

proc dependencyType(fields: NimNode, name: string): NimNode {.compileTime.} =
  for field in fields:
    if field[0].strVal == name:
      return field[1]

proc dependencyNames(fields: NimNode): string {.compileTime.} =
  for field in fields:
    if result.len > 0:
      result.add(", ")
    result.add(field[0].strVal)

proc dependencyFields(app: NimNode): NimNode {.compileTime.} =
  let key = applicationKey(app)
  if key in DependencySchemas:
    DependencySchemas[key]
  else:
    newEmptyNode()

proc rewriteDependencyGet(node, app, context: NimNode): NimNode {.compileTime.} =
  let isMethodCall =
    node.kind in {nnkCall, nnkCommand} and node.len == 2 and node[0].kind == nnkDotExpr and
    node[0].len == 2 and node[0][0].kind == nnkIdent and eqIdent(node[0][0], "ctx") and
    node[0][1].kind == nnkIdent and eqIdent(node[0][1], "get")
  if not isMethodCall:
    return nil

  let fields = dependencyFields(app)
  if fields.kind == nnkEmpty:
    error(
      "ctx.get(name) requires app.dependencies(DependencyType) before this route", node
    )
  if node[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error("dependency names in ctx.get(name) must be string literals", node[1])

  let name = node[1].strVal
  let fieldType = dependencyType(fields, name)
  if fieldType.isNil:
    error(
      "dependency '" & name & "' is not declared; available dependencies: " &
        dependencyNames(fields),
      node[1],
    )
  let getter = newTree(nnkBracketExpr, ident("get"), fieldType)
  newCall(getter, context, newLit(name))

proc bindRouteIdentifiers(
    node, app, request: NimNode,
    parsedBody = newEmptyNode(),
    inputName = "",
    parsedQuery = newEmptyNode(),
    queryInputName = "queryParams",
): NimNode {.compileTime.} =
  let context = newDotExpr(request, ident("context"))
  let dependencyGet = rewriteDependencyGet(node, app, context)
  if not dependencyGet.isNil:
    return dependencyGet
  if node.kind == nnkIdent and eqIdent(node, "request"):
    return request
  if parsedBody.kind != nnkEmpty and node.kind == nnkIdent and eqIdent(node, inputName):
    return parsedBody
  if parsedQuery.kind != nnkEmpty and node.kind == nnkIdent and
      eqIdent(node, queryInputName):
    return parsedQuery
  if node.kind == nnkIdent and eqIdent(node, "ctx"):
    return context
  if node.kind == nnkDotExpr:
    result = copyNimNode(node)
    result.add(
      bindRouteIdentifiers(
        node[0], app, request, parsedBody, inputName, parsedQuery, queryInputName
      )
    )
    result.add(node[1])
    return
  result = copyNimNode(node)
  for child in node:
    result.add(
      bindRouteIdentifiers(
        child, app, request, parsedBody, inputName, parsedQuery, queryInputName
      )
    )

proc staticString(node: NimNode, value: var string): bool {.compileTime.} =
  if node.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    value = node.strVal
    return true
  if node.kind == nnkSym:
    let implementation = node.getImpl()
    if implementation.kind == nnkConstDef and
        implementation[^1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      value = implementation[^1].strVal
      return true
  false

proc withTypedPathBindings(
    path, request, body: NimNode,
    additionalBoundNames: openArray[string] = [],
): NimNode {.compileTime.} =
  result = newStmtList()
  var routePath: string
  if not path.staticString(routePath):
    result.add(body)
    return
  try:
    for segment in routePath.split('/'):
      if ':' in segment:
        var spec: PathParamSpec
        if segment.parsePathParamSegment(spec):
          for boundName in ["request", "ctx"]:
            if eqIdent(ident(spec.name), boundName):
              error(
                "typed path parameter '" & spec.name &
                  "' conflicts with framework-bound identifier '" & boundName & "'",
                path,
              )
          for boundName in additionalBoundNames:
            if eqIdent(ident(spec.name), boundName):
              error(
                "typed path parameter '" & spec.name &
                  "' conflicts with framework-bound identifier '" & boundName & "'",
                path,
              )
          let valueType =
            case spec.kind
            of PathParamKind.String:
              ident("string")
            of PathParamKind.Int:
              ident("int")
            of PathParamKind.PositiveInt:
              ident("Positive")
            of PathParamKind.Bool:
              ident("bool")
            of PathParamKind.Csv:
              newTree(nnkBracketExpr, ident("seq"), ident("string"))
          let extractor =
            newTree(nnkBracketExpr, bindSym("typedPathParam"), valueType)
          let value = newCall(extractor, request, newLit(spec.name))
          result.add(
            newTree(
              nnkLetSection,
              newIdentDefs(ident(spec.name), newEmptyNode(), value),
            )
          )
  except ValueError as exc:
    error(exc.msg, path)
  result.add(body)

proc replaceDependency(
    node: NimNode, name: string, replacement: NimNode
): NimNode {.compileTime.} =
  if node.kind == nnkIdent and eqIdent(node, name):
    return replacement
  if node.kind == nnkDotExpr:
    result = copyNimNode(node)
    result.add(replaceDependency(node[0], name, replacement))
    result.add(node[1])
    return
  result = copyNimNode(node)
  for child in node:
    result.add(replaceDependency(child, name, replacement))

macro dependencies*(app: Application, schema: typedesc, body: untyped): untyped =
  ## Declares and wires typed application dependencies.
  ##
  ## Every field in ``schema`` needs one ``provide`` declaration. A matching
  ## ``cleanup`` declaration is optional. Routes registered after this block
  ## may retrieve declared values with ``ctx.get("name")``.
  let key = applicationKey(app)
  if key in DependencySchemas:
    error("dependencies have already been declared for this application", app)

  let fields = schemaFields(schema)
  var providers = initTable[string, NimNode]()
  var cleanups = initTable[string, NimNode]()

  for declaration in body:
    if declaration.kind notin {nnkCall, nnkCommand} or declaration.len != 3 or
        declaration[0].kind != nnkIdent or declaration[1].kind != nnkIdent or
        declaration[2].kind != nnkStmtList:
      error("use `provide name: expression` or `cleanup name: expression`", declaration)
    let kind = $declaration[0]
    let name = $declaration[1]
    if dependencyType(fields, name).isNil:
      error("dependency '" & name & "' is not a field of " & $schema, declaration[1])
    case kind
    of "provide":
      if name in providers:
        error("duplicate provider for dependency '" & name & "'", declaration)
      providers[name] = declaration[2]
    of "cleanup":
      if name in cleanups:
        error("duplicate cleanup for dependency '" & name & "'", declaration)
      cleanups[name] = declaration[2]
    else:
      error("unknown dependency declaration '" & kind & "'", declaration[0])

  for field in fields:
    let name = field[0].strVal
    if name notin providers:
      error("missing provider for dependency '" & name & "'", schema)

  DependencySchemas[key] = fields
  let loadContext = genSym(nskParam, "context")
  var loadBody = newStmtList()
  for field in fields:
    let name = field[0].strVal
    let nameLit = newLit(name)
    let fieldType = field[1]
    let value = genSym(nskLet, name)
    let provider = providers[name]
    loadBody.add quote do:
      let `value`: `fieldType` = block:
        `provider`
      setContext(`loadContext`, `nameLit`, `value`)

  let loadHook = quote:
    proc(`loadContext`: Context) {.nimcall.} =
      `loadBody`
  result = newStmtList(newCall(ident("onLoad"), app, loadHook))

  let unloadContext = genSym(nskParam, "context")
  var cleanupBody = newStmtList()
  for index in countdown(fields.len - 1, 0):
    let field = fields[index]
    let name = field[0].strVal
    if name in cleanups:
      let nameLit = newLit(name)
      let fieldType = field[1]
      let value = genSym(nskLet, name)
      let cleanup = replaceDependency(cleanups[name], name, value)
      let getter = newTree(nnkBracketExpr, ident("get"), fieldType)
      cleanupBody.add(newLetStmt(value, newCall(getter, unloadContext, nameLit)))
      cleanupBody.add(cleanup)

  if cleanupBody.len > 0:
    let unloadHook = quote:
      proc(`unloadContext`: Context) {.nimcall.} =
        `cleanupBody`
    result.add(newCall(ident("onUnload"), app, unloadHook))

proc load*(app: Application) =
  ## Runs application load hooks in registration order.
  if app.lifecycleLoaded:
    return
  for hook in app.loadHooks:
    hook(app.context)
  app.lifecycleLoaded = true

proc unload*(app: Application) =
  ## Runs application unload hooks in reverse registration order.
  if not app.lifecycleLoaded:
    return
  for index in countdown(app.unloadHooks.high, 0):
    app.unloadHooks[index](app.context)
  app.lifecycleLoaded = false

proc log*(app: Application, level: Level, message: string) {.gcsafe, raises: [].} =
  ## Sends an application log event when logging is enabled.
  if app.settings.logs and not app.settings.logHandler.isNil:
    app.settings.logHandler(level, message)

proc methodName(`method`: HttpMethod): string =
  case `method`
  of HttpMethod.Get: "GET"
  of HttpMethod.Post: "POST"
  of HttpMethod.Put: "PUT"
  of HttpMethod.Patch: "PATCH"
  of HttpMethod.Delete: "DELETE"
  of HttpMethod.Head: "HEAD"
  of HttpMethod.Options: "OPTIONS"
  of HttpMethod.Query: "QUERY"

proc logRequest*(
    app: Application, request: Request, status: int, elapsedUs: int64
) {.gcsafe, raises: [].} =
  ## Logs a completed request using ``info`` for successful responses and
  ## ``warn`` for client or server error responses, including elapsed time.
  let level = if status >= 400: lvlWarn else: lvlInfo
  app.log(
    level,
    methodName(request.method) & " " & request.path & " " & $status & " " & $elapsedUs &
      " μs",
  )

proc elapsedMicroseconds(startedAt: MonoTime): int64 {.inline.} =
  (getMonoTime() - startedAt).inMicroseconds

proc logError*(app: Application, message: string) {.gcsafe, raises: [].} =
  ## Logs an application or server error.
  app.log(lvlError, message)

proc onError*(app: Application, status: int, handler: ErrorHandler) =
  ## Registers a handler for framework-generated responses with ``status``.
  ## Use 404 for unmatched routes or 500 for uncaught handler failures.
  if status < 400 or status > 599:
    raise newException(ValueError, "Error handler status must be between 400 and 599")
  app.errorHandlers[status] = handler

proc defaultApiError(status: int, message = ""): ApiError {.raises: [].} =
  let fallback =
    case status
    of 400: ("bad_request", "Bad Request")
    of 401: ("unauthorized", "Unauthorized")
    of 403: ("forbidden", "Forbidden")
    of 404: ("not_found", "Not Found")
    of 408: ("request_timeout", "Request Timeout")
    of 409: ("conflict", "Conflict")
    of 413: ("content_too_large", "Content Too Large")
    of 422: ("validation_failed", "Unprocessable Content")
    of 431: ("request_headers_too_large", "Request Header Fields Too Large")
    of 500: ("internal_server_error", "Internal Server Error")
    of 503: ("service_unavailable", "Service Unavailable")
    else: ("http_error", "HTTP Error " & $status)
  initApiError(
    fallback[0],
    if message.len == 0: fallback[1] else: message,
  )

proc apiErrorResponse(
    app: Application, request: Request, status: int, error: ApiError
): Response {.gcsafe, raises: [].} =
  let handler = app.errorHandlers.getOrDefault(status)
  if not handler.isNil:
    try:
      return handler(request)
    except CatchableError as exc:
      app.logError("Error handler for status " & $status & " failed: " & exc.msg)
  http.apiErrorResponse(status, error)

proc limitResponse*(
    app: Application, request: Request, status: int, detail: string
): Response {.gcsafe, raises: [].} =
  ## Builds a standard JSON limit response, honoring ``onError`` overrides.
  var error = defaultApiError(status, detail)
  if status == 503 and detail == HandlerTimeoutDetail:
    error.code = "handler_timeout"
  app.apiErrorResponse(request, status, error)

proc errorResponse*(
    app: Application, request: Request, status: int
): Response {.gcsafe, raises: [].} =
  ## Builds a standard framework error, honoring ``onError`` overrides.
  app.apiErrorResponse(request, status, defaultApiError(status))

proc addMiddleware*(
    app: Application,
    middleware: Middleware,
    phase = MiddlewarePhase.BeforeRouting,
    priority = 0,
) =
  ## Adds HTTP middleware. Middleware runs in registration order, wrapping the
  ## route handler and any middleware registered after it. Lower priorities run
  ## first within a phase.
  let registration = MiddlewareRegistration(
    phase: phase, priority: priority, order: app.middlewareOrder, handler: middleware
  )
  inc app.middlewareOrder
  insertRegistration(app.middleware, registration)

proc addMiddleware*(
    router: Router,
    middleware: Middleware,
    phase = MiddlewarePhase.BeforeRouting,
    priority = 0,
) =
  ## Adds middleware scoped to a router. It runs around the router's HTTP
  ## routes only, after global application middleware. SSE and WebSocket
  ## routes bypass middleware (as on applications) and only get the prefix.
  let registration = MiddlewareRegistration(
    phase: phase, priority: priority, order: router.middlewareOrder, handler: middleware
  )
  inc router.middlewareOrder
  insertRegistration(router.middleware, registration)

macro middlewares*(target: Application | Router, body: untyped): untyped =
  ## Adds one or more middleware values in declaration order.
  ##
  ## Each expression in a colon block is registered as a separate middleware:
  ##
  ## ```nim
  ## app.middlewares:
  ##   requestId()
  ##   responseTime()
  ## ```
  let targetSym = genSym(nskLet, "middlewareTarget")
  result = newStmtList(newLetStmt(targetSym, target))

  if body.kind == nnkStmtList:
    for middleware in body:
      result.add(newCall(bindSym("addMiddleware"), targetSym, middleware))
  else:
    result.add(newCall(bindSym("addMiddleware"), targetSym, body))

proc initPlugin*(name, version: string, install: PluginInstall): Plugin =
  ## Creates a plugin definition for use with ``app.installPlugin``.
  Plugin(name: name, version: version, install: install)

proc installedPlugins*(app: Application): lent seq[PluginInfo] {.inline.} =
  ## Returns installed plugins in installation order.
  app.plugins

proc pluginContext*(app: Application, pluginName: string): Context =
  ## Returns state isolated to ``pluginName`` on this application.
  if pluginName notin app.pluginContexts:
    app.pluginContexts[pluginName] = newContext()
  app.pluginContexts[pluginName]

proc addOpenApiContributor*(app: Application, contributor: OpenApiContributor) =
  ## Registers an OpenAPI document extension.
  app.openApiContributors.add(contributor)

proc installPlugin*(app: Application, plugin: Plugin) =
  ## Installs a named plugin before the application starts serving.
  if app.lifecycleLoaded:
    raise
      newException(ValueError, "plugins must be installed before app.load or app.serve")
  if plugin.name.len == 0:
    raise newException(ValueError, "plugin names cannot be empty")
  for installed in app.plugins:
    if installed.name == plugin.name:
      raise newException(ValueError, "plugin is already installed: " & plugin.name)
  if plugin.install.isNil:
    raise newException(ValueError, "plugin install callback cannot be nil")
  plugin.install(app)
  app.plugins.add(PluginInfo(name: plugin.name, version: plugin.version))

proc validateRoutePath(path: string) =
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "route paths must start with '/'")
  var names: seq[string] = @[]
  for segment in path.split('/'):
    var spec: PathParamSpec
    let isParam = segment.parsePathParamSegment(spec)
    if not isParam and ('{' in segment or '}' in segment):
      raise newException(
        ValueError, "path parameters must occupy a complete {name} or {name:type} segment"
      )
    if isParam:
      if spec.name in names:
        raise newException(ValueError, "duplicate path parameter: " & spec.name)
      names.add(spec.name)

proc addRoute*(
    app: Application,
    `method`: HttpMethod,
    path: string,
    handler: RouteHandler,
    openApi = OpenApiOperation(),
) =
  ## Registers a route. Path parameters use ``{name}`` or ``{name:type}`` segments.
  validateRoutePath(path)
  var documentation = openApi
  if documentation.path.len == 0:
    documentation = initOpenApiOperation($`method`, path)
  app.routes.add(
    Route(`method`: `method`, path: path, handler: handler, openApi: documentation)
  )

proc addRoute*(
    app: Application,
    `method`: HttpMethod,
    path: string,
    handler: SyncRouteHandler,
    openApi = OpenApiOperation(),
) =
  ## Registers a legacy synchronous route through an asynchronous adapter.
  let asyncHandler: RouteHandler = proc(
      request: Request
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    {.gcsafe.}:
      return handler(request)
  app.addRoute(`method`, path, asyncHandler, openApi)

proc addRoute*(
    router: Router,
    `method`: HttpMethod,
    path: string,
    handler: RouteHandler,
    openApi = OpenApiOperation(),
) =
  ## Registers a route on a router. Mount with ``app.addRouter`` to serve it.
  validateRoutePath(path)
  var documentation = openApi
  if documentation.path.len == 0:
    documentation = initOpenApiOperation($`method`, path)
  router.routes.add(
    Route(`method`: `method`, path: path, handler: handler, openApi: documentation)
  )

proc addRoute*(
    router: Router,
    `method`: HttpMethod,
    path: string,
    handler: SyncRouteHandler,
    openApi = OpenApiOperation(),
) =
  ## Registers a legacy synchronous router route through an asynchronous adapter.
  let asyncHandler: RouteHandler = proc(
      request: Request
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    {.gcsafe.}:
      return handler(request)
  router.addRoute(`method`, path, asyncHandler, openApi)

proc addSseRoute*(app: Application, path: string, handler: SseRouteHandler) =
  ## Registers a GET Server-Sent Events endpoint.
  validateRoutePath(path)
  app.routes.add(
    Route(
      `method`: HttpMethod.Get, path: path, sseHandler: handler, kind: RouteKind.Sse
    )
  )

proc addSseRoute*(router: Router, path: string, handler: SseRouteHandler) =
  ## Registers a GET Server-Sent Events endpoint on a router.
  validateRoutePath(path)
  router.routes.add(
    Route(
      `method`: HttpMethod.Get, path: path, sseHandler: handler, kind: RouteKind.Sse
    )
  )

proc addWebSocketRoute*(
    app: Application, path: string, handler: WebSocketHandler
) {.raises: [ValueError].} =
  ## Registers a GET endpoint that upgrades to a WebSocket connection.
  validateRoutePath(path)
  app.routes.add(
    Route(
      `method`: HttpMethod.Get,
      path: path,
      websocketHandler: handler,
      kind: RouteKind.WebSocket,
    )
  )

proc addWebSocketRoute*(
    router: Router, path: string, handler: WebSocketHandler
) {.raises: [ValueError].} =
  ## Registers a WebSocket upgrade endpoint on a router.
  validateRoutePath(path)
  router.routes.add(
    Route(
      `method`: HttpMethod.Get,
      path: path,
      websocketHandler: handler,
      kind: RouteKind.WebSocket,
    )
  )

macro sse*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a Server-Sent Events endpoint.
  ##
  ## The block can asynchronously send ``ServerSentEvent`` values using ``send``,
  ## either as ``send(event)`` or with method syntax as ``event.send()``.
  if body.kind != nnkStmtList:
    return quote:
      addSseRoute(`app`, `path`, `body`)

  let request = genSym(nskParam, "request")
  let send = genSym(nskParam, "send")
  proc bindSend(node: NimNode): NimNode =
    if node.kind == nnkIdent and eqIdent(node, "send"):
      return send
    if node.kind in {nnkCall, nnkCommand} and node.len == 1 and
        node[0].kind == nnkDotExpr and node[0].len == 2 and node[0][1].kind == nnkIdent and
        eqIdent(node[0][1], "send"):
      return newCall(send, bindSend(node[0][0]))
    if node.kind == nnkDotExpr and node.len == 2 and node[1].kind == nnkIdent and
        eqIdent(node[1], "send"):
      return newCall(send, bindSend(node[0]))
    result = copyNimNode(node)
    for child in node:
      result.add(bindSend(child))

  let boundBody = withTypedPathBindings(
    path, request, bindSend(bindRouteIdentifiers(body, app, request)), ["send"]
  )
  result = quote:
    addSseRoute(
      `app`,
      `path`,
      proc(
          `request`: Request, `send`: SseSend
      ): Future[void] {.
          closure, async: (raises: [CancelledError, HttpWriteError, ValueError])
      .} =
        `boundBody`,
    )

macro websocket*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a WebSocket route using ``request`` and ``websocket``.
  if body.kind != nnkStmtList:
    return quote:
      addWebSocketRoute(`app`, `path`, `body`)

  let request = genSym(nskParam, "request")
  let websocket = genSym(nskParam, "websocket")
  proc bindWebSocket(node: NimNode): NimNode =
    if node.kind == nnkIdent and eqIdent(node, "websocket"):
      return websocket
    result = copyNimNode(node)
    for child in node:
      result.add(bindWebSocket(child))

  let boundBody = withTypedPathBindings(
    path,
    request,
    bindWebSocket(bindRouteIdentifiers(body, app, request)),
    ["websocket"],
  )
  result = quote:
    addWebSocketRoute(
      `app`,
      `path`,
      proc(
          `request`: Request, `websocket`: WebSocket
      ): Future[void] {.
          closure,
          async: (
            raises: [
              CancelledError, AsyncStreamError, WebSocketError,
              WebSocketDisconnectError, JsonParsingError, ValueError,
            ]
          )
      .} =
        `boundBody`,
    )

proc responseAliasCode(name: string): int {.compileTime.}

proc rewriteResponseReturns(node: NimNode): NimNode =
  if node.kind == nnkReturnStmt and node.len == 1 and node[0].kind == nnkTupleConstr:
    let values = node[0]
    if values.len != 2:
      error("response returns must use `return status, body`", values)

    let status =
      if values[0].kind == nnkIdent and responseAliasCode($values[0]) >= 0:
        newLit(responseAliasCode($values[0]))
      else:
        values[0]
    return newTree(
      nnkReturnStmt,
      newCall(ident("response"), status, rewriteResponseReturns(values[1])),
    )

  result = copyNimNode(node)
  for child in node:
    result.add(rewriteResponseReturns(child))

proc responseAliasCode(name: string): int {.compileTime.} =
  case name
  of "ok": 200
  of "switchingProtocols": 101
  of "processing": 102
  of "earlyHints": 103
  of "created": 201
  of "accepted": 202
  of "nonAuthoritativeInformation": 203
  of "resetContent": 205
  of "partialContent": 206
  of "multiStatus": 207
  of "alreadyReported": 208
  of "imUsed": 226
  of "multipleChoices": 300
  of "movedPermanently": 301
  of "found": 302
  of "seeOther": 303
  of "notModified": 304
  of "temporaryRedirect": 307
  of "permanentRedirect": 308
  of "badRequest": 400
  of "unauthorized": 401
  of "paymentRequired": 402
  of "forbidden": 403
  of "notFound": 404
  of "methodNotAllowed": 405
  of "notAcceptable": 406
  of "proxyAuthenticationRequired": 407
  of "requestTimeout": 408
  of "conflict": 409
  of "gone": 410
  of "lengthRequired": 411
  of "preconditionFailed": 412
  of "contentTooLarge": 413
  of "uriTooLong": 414
  of "unsupportedMediaType": 415
  of "rangeNotSatisfiable": 416
  of "expectationFailed": 417
  of "imATeapot": 418
  of "misdirectedRequest": 421
  of "unprocessableContent", "unprocessableEntity": 422
  of "locked": 423
  of "failedDependency": 424
  of "tooEarly": 425
  of "upgradeRequired": 426
  of "preconditionRequired": 428
  of "tooManyRequests": 429
  of "requestHeaderFieldsTooLarge": 431
  of "unavailableForLegalReasons": 451
  of "internalServerError": 500
  of "notImplemented": 501
  of "badGateway": 502
  of "serviceUnavailable": 503
  of "gatewayTimeout": 504
  of "httpVersionNotSupported": 505
  of "variantAlsoNegotiates": 506
  of "insufficientStorage": 507
  of "loopDetected": 508
  of "notExtended": 510
  of "networkAuthenticationRequired": 511
  else: -1

proc responseStatus(node: NimNode): NimNode =
  if node.kind != nnkIdent:
    return node
  let code = responseAliasCode($node)
  if code < 0:
    node
  else:
    newLit(code)

proc responseTuple(node: NimNode): NimNode =
  if node.kind == nnkTupleConstr:
    if node.len != 2:
      error("response tuples must use `(status, body)`", node)
    return newCall(ident("response"), responseStatus(node[0]), node[1])
  node

proc returnFinalTuple(node: NimNode): NimNode =
  if node.kind != nnkStmtList or node.len == 0 or node[^1].kind != nnkTupleConstr:
    return node
  result = copyNimNode(node)
  for index, child in node:
    if index == node.len - 1:
      result.add(newTree(nnkReturnStmt, child))
    else:
      result.add(child)

proc prepareRouteBody(node: NimNode): NimNode =
  let rewritten = rewriteResponseReturns(node)
  if rewritten.kind != nnkStmtList:
    return newStmtList(newTree(nnkReturnStmt, newCall(ident("toResponse"), rewritten)))

  result = copyNimNode(rewritten)
  for index, child in rewritten:
    if index == rewritten.len - 1 and child.kind != nnkReturnStmt:
      result.add(
        newTree(nnkReturnStmt, newCall(ident("toResponse"), responseTuple(child)))
      )
    else:
      result.add(child)

macro get*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a GET route using Nim's block syntax.
  ##
  ## ```nim
  ## app.get("/"):
  ##   text("Hello, world!")
  ## ```
  if body.kind != nnkStmtList:
    return quote:
      addRoute(`app`, HttpMethod.Get, `path`, `body`)

  let request = genSym(nskParam, "request")
  let boundBody = withTypedPathBindings(
    path, request, bindRouteIdentifiers(prepareRouteBody(body), app, request)
  )
  result = quote:
    addRoute(
      `app`,
      HttpMethod.Get,
      `path`,
      proc(`request`: Request): Future[Response] {.async: (raises: [CatchableError]).} =
        {.gcsafe.}:
          `boundBody`,
    )

macro query*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a QUERY route using Nim's block syntax.
  if body.kind != nnkStmtList:
    return quote:
      addRoute(`app`, HttpMethod.Query, `path`, `body`)

  let request = genSym(nskParam, "request")
  let boundBody = withTypedPathBindings(
    path, request, bindRouteIdentifiers(prepareRouteBody(body), app, request)
  )
  result = quote:
    addRoute(
      `app`,
      HttpMethod.Query,
      `path`,
      proc(`request`: Request): Future[Response] {.async: (raises: [CatchableError]).} =
        {.gcsafe.}:
          `boundBody`,
    )

proc typedOpenApiOperation(
    `method`, path, responses, bodyType, queryType, routeDocs, routeBody: NimNode,
    contentType: string,
): NimNode =
  let operation = genSym(nskVar, "openApiOperation")
  result = quote:
    block:
      var `operation` = initOpenApiOperation($`method`, `path`)
      `operation`.route = `routeDocs`
      `operation`.responses = newJObject()
  for item in responses[1]:
    let status = newLit($item[0].intVal)
    let model = item[1]
    if model.kind == nnkIdent and eqIdent(model, "void"):
      result[^1].add(
        quote do:
          `operation`.responses[`status`] = %*{"description": "Response " & `status`}
      )
    else:
      var ignoredFields: seq[string]
      var includedFields: seq[string]

      proc collectOverrides(node: NimNode) =
        for child in node:
          collectOverrides(child)
        if node.kind notin {nnkCall, nnkCommand} or node.len < 2:
          return
        let callee =
          if node[0].kind in {nnkIdent, nnkSym}:
            node[0]
          elif node[0].kind == nnkDotExpr and node[0].len == 2:
            node[0][1]
          else:
            newEmptyNode()
        if callee.kind == nnkEmpty or
            not (eqIdent(callee, "ignore") or eqIdent(callee, "include")):
          return
        let firstField = if node[0].kind == nnkDotExpr: 1 else: 2
        for index in firstField ..< node.len:
          let selector = node[index]
          if selector.kind == nnkDotExpr and selector.len == 2 and
              selector[0].repr == model.repr:
            let field = $selector[1]
            if eqIdent(callee, "ignore"):
              includedFields.keepItIf(it != field)
              if field notin ignoredFields:
                ignoredFields.add(field)
            else:
              ignoredFields.keepItIf(it != field)
              if field notin includedFields:
                includedFields.add(field)

      collectOverrides(routeBody)
      let ignored = newLit(ignoredFields)
      let included = newLit(includedFields)
      result[^1].add(
        quote do:
          `operation`.responses[`status`] = %*{
            "description": "Response " & `status`,
            "content": {
              "application/json": {
                "schema": openApiResponseSchema(`model`, `ignored`, `included`)
              }
            },
          }
      )
  if bodyType.kind != nnkEmpty:
    let mediaType = newLit(contentType)
    result[^1].add(
      quote do:
        `operation`.requestBody = %*{
          "required": true,
          "content": {`mediaType`: {"schema": openApiSchema(`bodyType`)}},
        }
    )
    result[^1].add(
      quote do:
        if not `operation`.responses.hasKey("400"):
          `operation`.responses["400"] = %*{
            "description": "Invalid request body",
            "content": {
              "application/json": {
                  "schema": openApiSchema(ApiError)
              }
            },
          }
        if not `operation`.responses.hasKey("422"):
          `operation`.responses["422"] = %*{
            "description": "Request validation failed",
            "content":
              {"application/json": {"schema": openApiSchema(ApiError)}},
          }
    )
  if queryType.kind != nnkEmpty:
    result[^1].add(
      quote do:
        `operation`.parameters = openApiQueryParameters(`queryType`)
    )
    result[^1].add(
      quote do:
        if not `operation`.responses.hasKey("400"):
          `operation`.responses["400"] = %*{
            "description": "Invalid query parameters",
            "content":
              {"application/json": {"schema": openApiSchema(ApiError)}},
          }
        if not `operation`.responses.hasKey("422"):
          `operation`.responses["422"] = %*{
            "description": "Query parameter validation failed",
            "content":
              {"application/json": {"schema": openApiSchema(ApiError)}},
          }
    )
  result[^1].add(operation)

proc buildTypedRoute(
    app, path, responses, body, `method`, bodyType: NimNode,
    inputName: string,
    parser: NimNode,
    invalidInputMessage: string,
    validator: NimNode,
    routeDocs: NimNode,
    queryType: NimNode = newEmptyNode(),
    queryValidator: NimNode = newEmptyNode(),
    queryInputName = "queryParams",
): NimNode =
  if responses.kind != nnkPrefix or $responses[0] != "@" or
      responses[1].kind != nnkBracket:
    error("responses must use @[(status, ModelType), ...]", responses)

  var models = initTable[int, NimNode]()
  for item in responses[1]:
    if item.kind != nnkTupleConstr or item.len != 2 or
        item[0].kind notin {nnkIntLit .. nnkInt64Lit}:
      error("each response declaration must be (status, ModelType)", item)
    let status = item[0].intVal.int
    if status in models:
      error("a route may declare each status only once", item)
    models[status] = item[1]

  proc checkedResponses(node: NimNode): NimNode =
    if node.kind == nnkReturnStmt and node.len == 1 and node[0].kind == nnkTupleConstr:
      let values = node[0]
      if values.len != 2:
        error("response returns must use `return (status, body)`", values)
      let status =
        if values[0].kind in {nnkIntLit .. nnkInt64Lit}:
          values[0].intVal.int
        elif values[0].kind == nnkIdent:
          if eqIdent(values[0], "noContent"):
            204
          else:
            responseAliasCode($values[0])
        else:
          -1
      if status < 0:
        error("response returns need a literal status or status alias", values[0])
      if status notin models:
        error("status " & $status & " was not declared for this route", values)
      let callee = newTree(nnkBracketExpr, ident("checkedResponse"), models[status])
      return newTree(
        nnkReturnStmt, newCall(callee, newLit(status), checkedResponses(values[1]))
      )

    if node.kind in {nnkCall, nnkCommand} and node.len >= 2 and node[0].kind == nnkIdent:
      let name = $node[0]
      let status =
        if name == "noContent":
          204
        else:
          responseAliasCode(name)
      if status >= 0:
        if node.len != 2:
          error(name & " expects exactly one response model", node)
        if status notin models:
          error("status " & $status & " was not declared for this route", node)
        if name == "noContent":
          if not (node[1].kind == nnkIdent and eqIdent(node[1], "void")):
            error("noContent expects `void`", node[1])
          return newCall(ident("noContent"), node[1])
        let callee = newTree(nnkBracketExpr, ident("checkedResponse"), models[status])
        return newCall(callee, newLit(status), checkedResponses(node[1]))
      if name == "status":
        if node.len != 3 or node[1].kind notin {nnkIntLit .. nnkInt64Lit}:
          error("status expects a literal status and one response model", node)
        let status = node[1].intVal.int
        if status notin models:
          error("status " & $status & " was not declared for this route", node)
        let callee = newTree(nnkBracketExpr, ident("checkedResponse"), models[status])
        return newCall(callee, newLit(status), checkedResponses(node[2]))
    result = copyNimNode(node)
    for child in node:
      result.add(checkedResponses(child))

  let request = genSym(nskParam, "request")
  let parsedBody =
    if bodyType.kind == nnkEmpty:
      newEmptyNode()
    else:
      genSym(nskVar, "body")
  let parsedQuery =
    if queryType.kind == nnkEmpty:
      newEmptyNode()
    else:
      genSym(nskVar, "query")
  let checkedBody = checkedResponses(returnFinalTuple(body))
  var additionalBoundNames: seq[string]
  if parsedBody.kind != nnkEmpty:
    additionalBoundNames.add(inputName)
  if parsedQuery.kind != nnkEmpty:
    additionalBoundNames.add(queryInputName)
  let boundBody = withTypedPathBindings(
    path,
    request,
    bindRouteIdentifiers(
      prepareRouteBody(checkedBody),
      app,
      request,
      parsedBody,
      inputName,
      parsedQuery,
      queryInputName,
    ),
    additionalBoundNames,
  )
  let contentType =
    if inputName == "form": "application/x-www-form-urlencoded" else: "application/json"
  let documentation = typedOpenApiOperation(
    `method`, path, responses, bodyType, queryType, routeDocs, body, contentType
  )
  if bodyType.kind == nnkEmpty and queryType.kind == nnkEmpty:
    result = quote:
      addRoute(
        `app`,
        `method`,
        `path`,
        proc(
            `request`: Request
        ): Future[Response] {.async: (raises: [CatchableError]).} =
          {.gcsafe.}:
            `boundBody`,
        `documentation`,
      )
  elif queryType.kind != nnkEmpty:
    let parsing = genSym(nskVar, "queryParsing")
    let validation = genSym(nskVar, "queryValidation")
    let customValidation =
      if queryValidator.kind == nnkEmpty:
        newStmtList()
      else:
        quote:
          `validation`.mergeErrors(`queryValidator`(`parsedQuery`))
    result = quote:
      addRoute(
        `app`,
        `method`,
        `path`,
        proc(
            `request`: Request
        ): Future[Response] {.async: (raises: [CatchableError]).} =
          var `parsedQuery` = `queryType`()
          var `parsing` = initValidationResult()
          parseQueryParams(`queryType`, `request`, `parsedQuery`, `parsing`)
          if not `parsing`.isValid():
            return queryParsingResponse(`parsing`)
          var `validation` = validateModel(`parsedQuery`)
          `customValidation`
          if not `validation`.isValid():
            return validationResponse(`validation`, source = "query")
          {.cast(gcsafe).}:
            `boundBody`,
        `documentation`,
      )
  else:
    let validation = genSym(nskVar, "validation")
    let source = newLit(inputName)
    let customValidation =
      if validator.kind == nnkEmpty:
        newStmtList()
      else:
        quote:
          `validation`.mergeErrors(`validator`(`parsedBody`))
    result = quote:
      addRoute(
        `app`,
        `method`,
        `path`,
        proc(
            `request`: Request
        ): Future[Response] {.async: (raises: [CatchableError]).} =
          var `parsedBody`: `bodyType`
          if not `parser`(`request`, `parsedBody`):
            return apiErrorResponse(
              statusBadRequest,
              initApiError("invalid_request_body", `invalidInputMessage`),
            )
          var `validation` = initValidationResult()
          when typeof(`parsedBody`) is object:
            `validation` = validateModel(`parsedBody`)
          `customValidation`
          if not `validation`.isValid():
            return validationResponse(`validation`, source = `source`)
          {.cast(gcsafe).}:
            `boundBody`,
        `documentation`,
      )

macro get*(
    app: Application | Router, path: typed, responses: untyped, body: untyped
): untyped =
  ## Registers a GET route with typed responses declared as ``@[(status, Model), ...]``.
  buildTypedRoute(
    app,
    path,
    responses,
    body,
    quote do:
      HttpMethod.Get,
    newEmptyNode(),
    "",
    newEmptyNode(),
    "",
    newEmptyNode(),
    newCall(ident("initOpenApiRoute")),
  )

macro get*(app: Application | Router, path: typed, args: varargs[untyped]): untyped =
  ## Registers a typed GET route with inline OpenAPI metadata.
  ##
  ## ```nim
  ## app.get(
  ##   "/users", queryParams = UserQuery, responses = @[(200, User)]
  ## ):
  ##   ok findUser(queryParams.id)
  ## ```
  var responses = newEmptyNode()
  var routeBody = newEmptyNode()
  var tags = newEmptyNode()
  var summary = newEmptyNode()
  var description = newEmptyNode()
  var operationId = newEmptyNode()
  var deprecated = newEmptyNode()
  var queryType = newEmptyNode()
  var queryValidator = newEmptyNode()
  var queryInputName = ""

  for argument in args:
    if argument.kind == nnkExprEqExpr:
      case $argument[0]
      of "responses":
        responses = argument[1]
      of "tags":
        tags = argument[1]
      of "summary":
        summary = argument[1]
      of "description":
        description = argument[1]
      of "operationId":
        operationId = argument[1]
      of "deprecated":
        deprecated = argument[1]
      of "queryParams", "query":
        if queryType.kind != nnkEmpty:
          error("GET routes accept only one query model", argument)
        queryType = argument[1]
        queryInputName = $argument[0]
      of "validator":
        queryValidator = argument[1]
      else:
        error("unsupported GET route option: " & $argument[0], argument)
    elif routeBody.kind == nnkEmpty:
      routeBody = argument
    else:
      error("GET routes accept one handler block", argument)

  if responses.kind == nnkEmpty:
    error(
      "inline OpenAPI metadata requires `responses = @[(status, Model), ...]`", path
    )
  if routeBody.kind == nnkEmpty:
    error("GET routes require a handler block", path)
  if queryValidator.kind != nnkEmpty and queryType.kind == nnkEmpty:
    error("GET route `validator` requires `queryParams`", queryValidator)

  var docs = newCall(ident("initOpenApiRoute"))
  proc addOption(name: string, value: NimNode) =
    if value.kind != nnkEmpty:
      docs.add(newTree(nnkExprEqExpr, ident(name), value))

  addOption("tags", tags)
  addOption("summary", summary)
  addOption("description", description)
  addOption("operationId", operationId)
  addOption("deprecated", deprecated)

  buildTypedRoute(
    app,
    path,
    responses,
    routeBody,
    quote do:
      HttpMethod.Get,
    newEmptyNode(),
    "",
    newEmptyNode(),
    "",
    newEmptyNode(),
    docs,
    queryType,
    queryValidator,
    queryInputName,
  )

macro query*(
    app: Application | Router, path: typed, responses: untyped, body: untyped
): untyped =
  ## Registers a QUERY route with typed responses.
  buildTypedRoute(
    app,
    path,
    responses,
    body,
    quote do:
      HttpMethod.Query,
    newEmptyNode(),
    "",
    newEmptyNode(),
    "",
    newEmptyNode(),
    newCall(ident("initOpenApiRoute")),
  )

macro post*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a POST route with either a handler or Nim block syntax.
  if body.kind != nnkStmtList:
    return quote:
      addRoute(`app`, HttpMethod.Post, `path`, `body`)

  let request = genSym(nskParam, "request")
  let boundBody = withTypedPathBindings(
    path, request, bindRouteIdentifiers(prepareRouteBody(body), app, request)
  )
  result = quote:
    addRoute(
      `app`,
      HttpMethod.Post,
      `path`,
      proc(`request`: Request): Future[Response] {.async: (raises: [CatchableError]).} =
        {.gcsafe.}:
          `boundBody`,
    )

macro post*(
    app: Application | Router, path: typed, responses: untyped, body: untyped
): untyped =
  ## Registers a POST route with typed responses declared as ``@[(status, Model), ...]``.
  buildTypedRoute(
    app,
    path,
    responses,
    body,
    quote do:
      HttpMethod.Post,
    newEmptyNode(),
    "",
    newEmptyNode(),
    "",
    newEmptyNode(),
    newCall(ident("initOpenApiRoute")),
  )

proc buildBodyRoute(
    app, path, args, `method`: NimNode, verb: string
): NimNode {.compileTime.} =
  var responses = newEmptyNode()
  var routeBody = newEmptyNode()
  var bodyType = newEmptyNode()
  var inputName = ""
  var parser = newEmptyNode()
  var invalidMessage = ""
  var validator = newEmptyNode()
  var tags = newEmptyNode()
  var summary = newEmptyNode()
  var description = newEmptyNode()
  var operationId = newEmptyNode()
  var deprecated = newEmptyNode()

  for argument in args:
    if argument.kind == nnkExprEqExpr:
      case $argument[0]
      of "responses":
        responses = argument[1]
      of "body":
        bodyType = argument[1]
        inputName = "body"
        parser = ident("parseJsonBody")
        invalidMessage = "invalid JSON request body"
      of "form":
        bodyType = argument[1]
        inputName = "form"
        parser = ident("parseFormBody")
        invalidMessage = "invalid form request body"
      of "validator":
        validator = argument[1]
      of "tags":
        tags = argument[1]
      of "summary":
        summary = argument[1]
      of "description":
        description = argument[1]
      of "operationId":
        operationId = argument[1]
      of "deprecated":
        deprecated = argument[1]
      else:
        error("unsupported " & verb & " route option: " & $argument[0], argument)
    elif routeBody.kind == nnkEmpty:
      routeBody = argument
    else:
      error(verb & " routes accept one handler block", argument)

  if responses.kind == nnkEmpty:
    error(
      "inline OpenAPI metadata requires `responses = @[(status, Model), ...]`", path
    )
  if routeBody.kind == nnkEmpty:
    error(verb & " routes require a handler block", path)
  if validator.kind != nnkEmpty and bodyType.kind == nnkEmpty:
    error(verb & " route `validator` requires `body` or `form`", validator)

  var docs = newCall(ident("initOpenApiRoute"))
  proc addOption(name: string, value: NimNode) =
    if value.kind != nnkEmpty:
      docs.add(newTree(nnkExprEqExpr, ident(name), value))

  addOption("tags", tags)
  addOption("summary", summary)
  addOption("description", description)
  addOption("operationId", operationId)
  addOption("deprecated", deprecated)

  result = buildTypedRoute(
    app, path, responses, routeBody, `method`, bodyType, inputName, parser,
    invalidMessage, validator, docs,
  )

proc buildBlockRoute(app, path, body, `method`: NimNode): NimNode {.compileTime.} =
  if body.kind != nnkStmtList:
    return quote:
      addRoute(`app`, `method`, `path`, `body`)

  let request = genSym(nskParam, "request")
  let boundBody = withTypedPathBindings(
    path, request, bindRouteIdentifiers(prepareRouteBody(body), app, request)
  )
  result = quote:
    addRoute(
      `app`,
      `method`,
      `path`,
      proc(`request`: Request): Future[Response] {.async: (raises: [CatchableError]).} =
        {.gcsafe.}:
          `boundBody`,
    )

macro post*(app: Application | Router, path: typed, args: varargs[untyped]): untyped =
  ## Registers a typed POST route with inline OpenAPI metadata.
  ##
  ## A ``body = Model`` or ``form = Model`` is decoded and automatically
  ## validated from its field pragmas before the handler runs. Supply
  ## ``validator = validateModelBusinessRules`` to merge cross-field or
  ## domain-specific errors with the declarative constraint errors.
  ##
  ## ```nim
  ## app.post(
  ##   "/products",
  ##   body = CreateProduct,
  ##   responses = @[(201, Product)],
  ## ):
  ##   created Product(name: body.name)
  ## ```
  buildBodyRoute(
    app,
    path,
    args,
    quote do:
      HttpMethod.Post,
    "POST",
  )

macro put*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a PUT route with either a handler or Nim block syntax.
  buildBlockRoute(
    app,
    path,
    body,
    quote do:
      HttpMethod.Put,
  )

macro put*(app: Application | Router, path: typed, args: varargs[untyped]): untyped =
  ## Registers a typed PUT route with optional body validation and OpenAPI metadata.
  buildBodyRoute(
    app,
    path,
    args,
    quote do:
      HttpMethod.Put,
    "PUT",
  )

macro patch*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a PATCH route with either a handler or Nim block syntax.
  buildBlockRoute(
    app,
    path,
    body,
    quote do:
      HttpMethod.Patch,
  )

macro patch*(app: Application | Router, path: typed, args: varargs[untyped]): untyped =
  ## Registers a typed PATCH route with optional body validation and OpenAPI metadata.
  ##
  ## ```nim
  ## app.patch(
  ##   "/orders/{id}",
  ##   body = StatusChange,
  ##   validator = validateStatusChange,
  ##   responses = @[(200, StatusChange)],
  ## ):
  ##   ok body
  ## ```
  buildBodyRoute(
    app,
    path,
    args,
    quote do:
      HttpMethod.Patch,
    "PATCH",
  )

macro delete*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a DELETE route with either a handler or Nim block syntax.
  buildBlockRoute(
    app,
    path,
    body,
    quote do:
      HttpMethod.Delete,
  )

macro delete*(app: Application | Router, path: typed, args: varargs[untyped]): untyped =
  ## Registers a DELETE route with typed responses and inline OpenAPI metadata.
  var responses = newEmptyNode()
  var routeBody = newEmptyNode()
  var tags = newEmptyNode()
  var summary = newEmptyNode()
  var description = newEmptyNode()
  var operationId = newEmptyNode()
  var deprecated = newEmptyNode()

  for argument in args:
    if argument.kind == nnkExprEqExpr:
      case $argument[0]
      of "responses":
        responses = argument[1]
      of "tags":
        tags = argument[1]
      of "summary":
        summary = argument[1]
      of "description":
        description = argument[1]
      of "operationId":
        operationId = argument[1]
      of "deprecated":
        deprecated = argument[1]
      else:
        error("unsupported DELETE route option: " & $argument[0], argument)
    elif routeBody.kind == nnkEmpty:
      routeBody = argument
    else:
      error("DELETE routes accept one handler block", argument)

  if responses.kind == nnkEmpty:
    error("DELETE routes require `responses = @[(status, Model), ...]`", path)
  if routeBody.kind == nnkEmpty:
    error("DELETE routes require a handler block", path)

  var docs = newCall(ident("initOpenApiRoute"))
  proc addOption(name: string, value: NimNode) =
    if value.kind != nnkEmpty:
      docs.add(newTree(nnkExprEqExpr, ident(name), value))

  addOption("tags", tags)
  addOption("summary", summary)
  addOption("description", description)
  addOption("operationId", operationId)
  addOption("deprecated", deprecated)

  buildTypedRoute(
    app,
    path,
    responses,
    routeBody,
    quote do:
      HttpMethod.Delete,
    newEmptyNode(),
    "",
    newEmptyNode(),
    "",
    newEmptyNode(),
    docs,
  )

proc routes*(app: Application): lent seq[Route] {.inline.} =
  ## Returns the application's routes in registration order.
  app.routes

proc routes*(router: Router): lent seq[Route] {.inline.} =
  ## Returns the router's routes in registration order.
  router.routes

proc addRouter*(
    app: Application, router: Router, prefix = "", tags: seq[string] = @[]
) =
  ## Mounts a router's routes on an application, FastAPI-style.
  ##
  ## The final path is ``prefix & router.prefix & route.path`` with duplicate
  ## slashes removed. Tags merge as ``tags & router.defaultTags & routeTags``.
  ## Router middleware runs around the router's HTTP routes only, after
  ## global application middleware.
  ##
  ## ```nim
  ## let app = initFastNim()
  ## app.addRouter(userRouter, prefix = "/v1")
  ## ```
  if router.isNil:
    raise newException(ValueError, "router cannot be nil")
  if app.lifecycleLoaded:
    raise newException(ValueError, "routers must be added before app.load or app.serve")
  if prefix.len > 0 and prefix[0] != '/':
    raise newException(ValueError, "router mount prefixes must start with '/'")
  let basePrefix = joinMountPath(prefix, router.prefix)
  var scopedMiddleware: seq[Middleware] = @[]
  for registration in router.middleware:
    scopedMiddleware.add(registration.handler)
  for route in router.routes:
    var mounted = route
    mounted.path = joinMountPath(basePrefix, route.path)
    mounted.openApi.path = mounted.path
    mounted.openApi.route.tags =
      mergeRouterTags(tags, router.defaultTags, route.openApi.route.tags)
    if route.kind == RouteKind.Http and scopedMiddleware.len > 0:
      mounted.routerMiddleware = scopedMiddleware
    app.routes.add(mounted)

proc documentRoute*(
    app: Application, `method`: HttpMethod, path: string, docs: OpenApiRoute
) =
  ## Attaches OpenAPI metadata to a previously registered route.
  for route in app.routes.mitems:
    if route.method == `method` and route.path == path:
      route.openApi.route = docs
      return
  raise newException(ValueError, "cannot document an unregistered route: " & path)

proc documentRoute*(
    router: Router, `method`: HttpMethod, path: string, docs: OpenApiRoute
) =
  ## Attaches OpenAPI metadata to a previously registered router route.
  for route in router.routes.mitems:
    if route.method == `method` and route.path == path:
      route.openApi.route = docs
      return
  raise newException(ValueError, "cannot document an unregistered route: " & path)

proc openApiDocument*(app: Application): JsonNode =
  ## Builds the current application's OpenAPI 3.1 document.
  var operations: seq[OpenApiOperation] = @[]
  for route in app.routes:
    if route.kind == RouteKind.Http:
      operations.add(route.openApi)
  result = spec.openApiDocument(app.openApiSettings, operations)
  for contributor in app.openApiContributors:
    contributor(result)

proc splitPath(path: string): seq[string] =
  if path == "/":
    return @[]
  for segment in path.split('/'):
    if segment.len > 0:
      result.add(segment)

proc match(
    route: Route, request: Request, params: var Table[string, string]
): bool {.raises: [].} =
  if route.method != request.method:
    return false

  let routeParts = splitPath(route.path)
  let requestParts = splitPath(request.path)
  if routeParts.len != requestParts.len:
    return false

  try:
    for index, routePart in routeParts:
      var spec: PathParamSpec
      if routePart.parsePathParamSegment(spec):
        if not spec.kind.matchesPathParam(requestParts[index]):
          return false
        params[spec.name] = requestParts[index]
      elif routePart != requestParts[index]:
        return false
    true
  except ValueError:
    false

proc invokeHandler(
    app: Application, handler: RouteHandler, request: Request
): Future[Response] {.async: (raises: [CatchableError]).} =
  ## Runs one HTTP handler, cancelling it when ``handlerTimeout`` elapses.
  ##
  ## The deadline becomes a ``503`` response so middleware still observes it.
  ## Cancellation of this procedure itself, such as server shutdown, is
  ## re-raised. Server-sent events and WebSocket handlers do not use this path.
  let timeout = app.requestLimits.handlerTimeout
  if timeout.isInfinite():
    return await handler(request)
  let pending = handler(request)
  let finished =
    try:
      await pending.withTimeout(timeout)
    except CancelledError as exc:
      raise exc
  if not finished:
    return app.limitResponse(request, 503, HandlerTimeoutDetail)
  await pending

proc runRouteMiddleware(
    app: Application, route: Route, index: int, request: Request
): Future[Response] {.async: (raises: [CatchableError]).} =
  ## Runs router-scoped middleware around an already matched route handler.
  if index == route.routerMiddleware.len:
    return await app.invokeHandler(route.handler, request)
  let next: NextHandler = proc(
      nextRequest: Request
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    return await runRouteMiddleware(app, route, index + 1, nextRequest)
  return await route.routerMiddleware[index](request, next)

proc dispatch(
    app: Application, request: Request
): Future[Response] {.async: (raises: [CatchableError]).} =
  ## Dispatches a request to its matching route without running middleware.
  if app.openApiSettings.enabled and request.method == HttpMethod.Get:
    if request.path == app.openApiSettings.schemaPath:
      try:
        var document: JsonNode
        {.cast(gcsafe), cast(raises: [CatchableError]).}:
          document = app.openApiDocument()
        return json(document)
      except CatchableError:
        return text(statusInternalServerError, "Unable to generate OpenAPI document")
    if request.path == app.openApiSettings.docsPath:
      var docs = text(
        swaggerUiHtml(
          app.openApiSettings.schemaPath, app.openApiSettings.title & " docs"
        )
      )
      docs.setHeader("content-type", "text/html; charset=utf-8")
      return docs
  for route in app.routes:
    var params = initTable[string, string]()
    if route.match(request, params):
      var matchedRequest = request
      matchedRequest.pathParams = params
      matchedRequest.context = app.context
      if route.kind == RouteKind.Sse:
        return text(statusNotImplemented, "SSE routes require an HTTP server")
      if route.kind == RouteKind.WebSocket:
        return text(statusNotImplemented, "WebSocket routes require an HTTP server")
      if route.routerMiddleware.len > 0:
        return await runRouteMiddleware(app, route, 0, matchedRequest)
      return await app.invokeHandler(route.handler, matchedRequest)
  return app.errorResponse(request, 404)

proc runMiddleware(
    app: Application, index: int, request: Request
): Future[Response] {.async: (raises: [CatchableError]).} =
  if index == app.middleware.len:
    return await app.dispatch(request)

  let next: NextHandler = proc(
      nextRequest: Request
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    return await app.runMiddleware(index + 1, nextRequest)
  return await app.middleware[index].handler(request, next)

proc handle*(
    app: Application, request: Request
): Future[Response] {.async: (raises: [CancelledError]).} =
  ## Asynchronously runs middleware and dispatches a request to its route.
  let startedAt = getMonoTime()
  var contextualRequest = request
  contextualRequest.context = app.context
  try:
    let headerDetail = headerLimitDetail(contextualRequest.headers, app.requestLimits)
    if headerDetail.len > 0:
      result = app.limitResponse(contextualRequest, 431, headerDetail)
    else:
      let bodyDetail = bodyLimitDetail(
        contextualRequest.headers, contextualRequest.body, app.requestLimits
      )
      if bodyDetail.len > 0:
        result = app.limitResponse(contextualRequest, 413, bodyDetail)
      else:
        result = await app.runMiddleware(0, contextualRequest)
  except CancelledError as exc:
    raise exc
  except HttpRequestBodyTooLargeError:
    result = app.limitResponse(contextualRequest, 413, BodyTooLargeDetail)
  except BodyReadLimitError as exc:
    result = app.limitResponse(contextualRequest, 408, exc.detail)
  except ApiErrorException as exc:
    let status = exc.apiErrorStatus().statusCode()
    if status == 500:
      app.logError("Unhandled request error: " & exc.msg)
      result = app.errorResponse(contextualRequest, 500)
    else:
      result = app.apiErrorResponse(contextualRequest, status, exc.apiError())
  except MultipartError as exc:
    result = app.apiErrorResponse(
      contextualRequest, exc.status, defaultApiError(exc.status, exc.msg)
    )
  except CatchableError as exc:
    app.logError("Unhandled request error: " & exc.msg)
    result = app.errorResponse(contextualRequest, 500)
  app.logRequest(request, result.status, elapsedMicroseconds(startedAt))

proc isSseRoute*(app: Application, request: Request): bool {.gcsafe, raises: [].} =
  ## Returns whether ``request`` targets a registered SSE route.
  for route in app.routes:
    var params = initTable[string, string]()
    if route.kind == RouteKind.Sse and route.match(request, params):
      return true
  false

proc isWebSocketRoute*(
    app: Application, request: Request
): bool {.gcsafe, raises: [].} =
  ## Returns whether ``request`` targets a registered WebSocket route.
  for route in app.routes:
    var params = initTable[string, string]()
    if route.kind == RouteKind.WebSocket and route.match(request, params):
      return true
  false

proc handleWebSocket*(
    app: Application, request: Request, websocket: WebSocket
): Future[void] {.
    async: (
      raises: [
        CancelledError, AsyncStreamError, WebSocketError, WebSocketDisconnectError,
        JsonParsingError, ValueError,
      ]
    )
.} =
  ## Runs a matching WebSocket route.
  for route in app.routes:
    var params = initTable[string, string]()
    if route.kind == RouteKind.WebSocket and route.match(request, params):
      var matchedRequest = request
      matchedRequest.pathParams = params
      matchedRequest.context = app.context
      await route.websocketHandler(matchedRequest, websocket)
      return

proc handleSse*(
    app: Application, request: Request, send: SseSend
): Future[void] {.async: (raises: [CancelledError, HttpWriteError, ValueError]).} =
  ## Runs a matching SSE route, passing it the async event sender.
  for route in app.routes:
    var params = initTable[string, string]()
    if route.kind == RouteKind.Sse and route.match(request, params):
      var matchedRequest = request
      matchedRequest.pathParams = params
      matchedRequest.context = app.context
      await route.sseHandler(matchedRequest, send)
      return
