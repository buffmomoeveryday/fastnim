## Route registration and dispatch for fastnim applications.

import std/[json, logging, macrocache, macros, monotimes, strutils, tables, times]

import chronos/[asyncloop, futures, transport]
from chronos/apps/http/httpserver import HttpWriteError
from websock/websock import WebSocketError

import fastnim/context/http
import fastnim/context/state
import fastnim/logging
import fastnim/openapi/spec
import fastnim/websocket

type
  RouteHandler* = proc(request: Request): Response {.nimcall.}
    ## Handles a regular HTTP request. Handlers may capture application state.
  ErrorHandler* = proc(request: Request): Response {.closure, gcsafe.}
    ## Creates a response for a framework-generated HTTP error status.
  NextHandler* = proc(request: Request): Response {.closure.}
    ## Continues an HTTP request through the remaining middleware and route.
  Middleware* = proc(request: Request, next: NextHandler): Response {.closure.}
    ## Runs around an HTTP request. It may return without calling ``next`` to
    ## short-circuit the request.
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
    path*: string ## Path template with ``{name}`` segments.
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

proc initFastNim*(
    settings: ApplicationSettings, openApi = initOpenApiSettings()
): Application =
  ## Creates an empty application with the supplied settings.
  ##
  ## When logging is enabled and no handler is configured, logs are colorized
  ## on the console.
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
  )
  if result.settings.logs and result.settings.logHandler.isNil:
    result.settings.logHandler = colorConsoleLogHandler(result.settings.logLevel)

proc initFastNim*(
    logs = true,
    logHandler: LogHandler = nil,
    logLevel = lvlInfo,
    openApi = initOpenApiSettings(),
): Application =
  ## Creates an empty application.
  ##
  ## Set ``logs = false`` to disable framework logs, or provide ``logHandler``
  ## to send them to a custom destination.
  initFastNim(initApplicationSettings(logs, logHandler, logLevel), openApi)

proc newApplication*(
    settings: ApplicationSettings, openApi = initOpenApiSettings()
): Application {.deprecated: "Use FastNim instead.".} =
  ## Deprecated alias for ``initFastNim``.
  initFastNim(settings, openApi)

proc newApplication*(
    logs = true,
    logHandler: LogHandler = nil,
    logLevel = lvlInfo,
    openApi = initOpenApiSettings(),
): Application {.deprecated: "Use FastNim instead.".} =
  ## Deprecated alias for ``initFastNim``.
  initFastNim(initApplicationSettings(logs, logHandler, logLevel), openApi)

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

proc rewriteDependencyGet(
    node, app, context: NimNode
): NimNode {.compileTime.} =
  let isMethodCall =
    node.kind in {nnkCall, nnkCommand} and node.len == 2 and
    node[0].kind == nnkDotExpr and node[0].len == 2 and
    node[0][0].kind == nnkIdent and eqIdent(node[0][0], "ctx") and
    node[0][1].kind == nnkIdent and eqIdent(node[0][1], "get")
  if not isMethodCall:
    return nil

  let fields = dependencyFields(app)
  if fields.kind == nnkEmpty:
    error(
      "ctx.get(name) requires app.dependencies(DependencyType) before this route",
      node,
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
): NimNode {.compileTime.} =
  let context = newDotExpr(request, ident("context"))
  let dependencyGet = rewriteDependencyGet(node, app, context)
  if not dependencyGet.isNil:
    return dependencyGet
  if node.kind == nnkIdent and eqIdent(node, "request"):
    return request
  if parsedBody.kind != nnkEmpty and node.kind == nnkIdent and eqIdent(node, inputName):
    return parsedBody
  if node.kind == nnkIdent and eqIdent(node, "ctx"):
    return context
  result = copyNimNode(node)
  for child in node:
    result.add(bindRouteIdentifiers(child, app, request, parsedBody, inputName))

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

  let loadHook = quote do:
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
      cleanupBody.add(
        newLetStmt(value, newCall(getter, unloadContext, nameLit)),
      )
      cleanupBody.add(cleanup)

  if cleanupBody.len > 0:
    let unloadHook = quote do:
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

proc errorResponse*(app: Application, request: Request, status: int): Response =
  ## Builds a framework error response, using a registered handler if present.
  let handler = app.errorHandlers.getOrDefault(status)
  if not handler.isNil:
    try:
      return handler(request)
    except CatchableError as exc:
      app.logError("Error handler for status " & $status & " failed: " & exc.msg)
    except:
      app.logError("Error handler for status " & $status & " failed")
  case status
  of 404:
    notFound()
  of 500:
    text("Internal Server Error", 500)
  else:
    text("HTTP Error " & $status, status)

proc use*(
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

proc use*(
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

proc middlewares*(app: Application, middleware: Middleware) =
  ## Adds middleware using the plural ``app.middlewares: middleware`` style.
  app.use(middleware)

proc middlewares*(router: Router, middleware: Middleware) =
  ## Adds router-scoped middleware using the plural style.
  router.use(middleware)

proc initPlugin*(name, version: string, install: PluginInstall): Plugin =
  ## Creates a plugin definition for use with ``app.install``.
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

proc install*(app: Application, plugin: Plugin) =
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

proc addRoute*(
    app: Application,
    `method`: HttpMethod,
    path: string,
    handler: RouteHandler,
    openApi = OpenApiOperation(),
) =
  ## Registers a route. Path parameters use ``{name}`` segments.
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "route paths must start with '/'")
  var documentation = openApi
  if documentation.path.len == 0:
    documentation = initOpenApiOperation($`method`, path)
  app.routes.add(
    Route(`method`: `method`, path: path, handler: handler, openApi: documentation)
  )

proc addRoute*(
    router: Router,
    `method`: HttpMethod,
    path: string,
    handler: RouteHandler,
    openApi = OpenApiOperation(),
) =
  ## Registers a route on a router. Mount with ``app.addRouter`` to serve it.
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "route paths must start with '/'")
  var documentation = openApi
  if documentation.path.len == 0:
    documentation = initOpenApiOperation($`method`, path)
  router.routes.add(
    Route(`method`: `method`, path: path, handler: handler, openApi: documentation)
  )

proc addSseRoute*(app: Application, path: string, handler: SseRouteHandler) =
  ## Registers a GET Server-Sent Events endpoint.
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "route paths must start with '/'")
  app.routes.add(
    Route(
      `method`: HttpMethod.Get, path: path, sseHandler: handler, kind: RouteKind.Sse
    )
  )

proc addSseRoute*(router: Router, path: string, handler: SseRouteHandler) =
  ## Registers a GET Server-Sent Events endpoint on a router.
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "route paths must start with '/'")
  router.routes.add(
    Route(
      `method`: HttpMethod.Get, path: path, sseHandler: handler, kind: RouteKind.Sse
    )
  )

proc addWebSocketRoute*(
    app: Application, path: string, handler: WebSocketHandler
) {.raises: [ValueError].} =
  ## Registers a GET endpoint that upgrades to a WebSocket connection.
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "route paths must start with '/'")
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
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "route paths must start with '/'")
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

  let boundBody = bindSend(bindRouteIdentifiers(body, app, request))
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

  let boundBody = bindWebSocket(bindRouteIdentifiers(body, app, request))
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

proc rewriteResponseReturns(node: NimNode): NimNode =
  if node.kind == nnkReturnStmt and node.len == 1 and node[0].kind == nnkTupleConstr:
    let values = node[0]
    if values.len != 2:
      error("response returns must use `return status, body`", values)

    let status =
      if values[0].kind == nnkIdent:
        case $values[0]
        of "ok":
          newLit(200)
        of "created":
          newLit(201)
        of "badRequest":
          newLit(400)
        of "notFound":
          newLit(404)
        of "conflict":
          newLit(409)
        of "unprocessableEntity":
          newLit(422)
        else:
          values[0]
      else:
        values[0]
    return newTree(
      nnkReturnStmt,
      newCall(ident("response"), status, rewriteResponseReturns(values[1])),
    )

  result = copyNimNode(node)
  for child in node:
    result.add(rewriteResponseReturns(child))

proc responseStatus(node: NimNode): NimNode =
  if node.kind != nnkIdent:
    return node
  case $node
  of "ok":
    newLit(200)
  of "created":
    newLit(201)
  of "badRequest":
    newLit(400)
  of "notFound":
    newLit(404)
  of "conflict":
    newLit(409)
  of "unprocessableEntity":
    newLit(422)
  else:
    node

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
  let boundBody = bindRouteIdentifiers(prepareRouteBody(body), app, request)
  result = quote:
    addRoute(
      `app`,
      HttpMethod.Get,
      `path`,
      proc(`request`: Request): Response {.nimcall.} =
        `boundBody`,
    )

macro query*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a QUERY route using Nim's block syntax.
  if body.kind != nnkStmtList:
    return quote:
      addRoute(`app`, HttpMethod.Query, `path`, `body`)

  let request = genSym(nskParam, "request")
  let boundBody = bindRouteIdentifiers(prepareRouteBody(body), app, request)
  result = quote:
    addRoute(
      `app`,
      HttpMethod.Query,
      `path`,
      proc(`request`: Request): Response {.nimcall.} =
        `boundBody`,
    )

proc typedOpenApiOperation(
    `method`, path, responses, bodyType, routeDocs: NimNode, contentType: string
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
      result[^1].add(
        quote do:
          `operation`.responses[`status`] = %*{
            "description": "Response " & `status`,
            "content": {"application/json": {"schema": openApiSchema(`model`)}},
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
  result[^1].add(operation)

proc buildTypedRoute(
    app, path, responses, body, `method`, bodyType: NimNode,
    inputName: string,
    parser: NimNode,
    invalidInputMessage: string,
    routeDocs: NimNode,
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
          case $values[0]
          of "ok": 200
          of "created": 201
          of "badRequest": 400
          of "notFound": 404
          of "conflict": 409
          of "unprocessableEntity": 422
          of "noContent": 204
          else: -1
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
        case name
        of "ok": 200
        of "created": 201
        of "badRequest": 400
        of "notFound": 404
        of "conflict": 409
        of "unprocessableEntity": 422
        else: -1
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
  let checkedBody = checkedResponses(returnFinalTuple(body))
  let boundBody =
    bindRouteIdentifiers(prepareRouteBody(checkedBody), app, request, parsedBody, inputName)
  let contentType =
    if inputName == "form": "application/x-www-form-urlencoded" else: "application/json"
  let documentation =
    typedOpenApiOperation(`method`, path, responses, bodyType, routeDocs, contentType)
  if bodyType.kind == nnkEmpty:
    result = quote:
      addRoute(
        `app`,
        `method`,
        `path`,
        proc(`request`: Request): Response {.nimcall.} =
          `boundBody`,
        `documentation`,
      )
  else:
    result = quote:
      addRoute(
        `app`,
        `method`,
        `path`,
        proc(`request`: Request): Response {.nimcall.} =
          var `parsedBody`: `bodyType`
          if not `parser`(`request`, `parsedBody`):
            return json("{\"detail\":\"" & `invalidInputMessage` & "\"}", 400)
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
    newCall(ident("initOpenApiRoute")),
  )

macro get*(app: Application | Router, path: typed, args: varargs[untyped]): untyped =
  ## Registers a typed GET route with inline OpenAPI metadata.
  ##
  ## ```nim
  ## app.get("/users", responses = @[(200, User)], tags = @["users"]):
  ##   ok User()
  ## ```
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
    docs,
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
    newCall(ident("initOpenApiRoute")),
  )

macro post*(app: Application | Router, path: typed, body: untyped): untyped =
  ## Registers a POST route with either a handler or Nim block syntax.
  if body.kind != nnkStmtList:
    return quote:
      addRoute(`app`, HttpMethod.Post, `path`, `body`)

  let request = genSym(nskParam, "request")
  let boundBody = bindRouteIdentifiers(prepareRouteBody(body), app, request)
  result = quote:
    addRoute(
      `app`,
      HttpMethod.Post,
      `path`,
      proc(`request`: Request): Response {.nimcall.} =
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
    newCall(ident("initOpenApiRoute")),
  )

macro post*(app: Application | Router, path: typed, args: varargs[untyped]): untyped =
  ## Registers a typed POST route with inline OpenAPI metadata.
  var responses = newEmptyNode()
  var routeBody = newEmptyNode()
  var bodyType = newEmptyNode()
  var inputName = ""
  var parser = newEmptyNode()
  var invalidMessage = ""
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
        error("unsupported POST route option: " & $argument[0], argument)
    elif routeBody.kind == nnkEmpty:
      routeBody = argument
    else:
      error("POST routes accept one handler block", argument)

  if responses.kind == nnkEmpty:
    error(
      "inline OpenAPI metadata requires `responses = @[(status, Model), ...]`", path
    )
  if routeBody.kind == nnkEmpty:
    error("POST routes require a handler block", path)

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
      HttpMethod.Post,
    bodyType,
    inputName,
    parser,
    invalidMessage,
    docs,
  )

proc put*(app: Application, path: string, handler: RouteHandler) =
  ## Registers a PUT route.
  app.addRoute(HttpMethod.Put, path, handler)

proc put*(router: Router, path: string, handler: RouteHandler) =
  ## Registers a PUT route on a router.
  router.addRoute(HttpMethod.Put, path, handler)

proc patch*(app: Application, path: string, handler: RouteHandler) =
  ## Registers a PATCH route.
  app.addRoute(HttpMethod.Patch, path, handler)

proc patch*(router: Router, path: string, handler: RouteHandler) =
  ## Registers a PATCH route on a router.
  router.addRoute(HttpMethod.Patch, path, handler)

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

proc isParameter(segment: string): bool =
  segment.len > 2 and segment[0] == '{' and segment[^1] == '}'

proc match(route: Route, request: Request, params: var Table[string, string]): bool =
  if route.method != request.method:
    return false

  let routeParts = splitPath(route.path)
  let requestParts = splitPath(request.path)
  if routeParts.len != requestParts.len:
    return false

  for index, routePart in routeParts:
    if isParameter(routePart):
      let name = routePart[1 ..^ 2]
      if name.len == 0:
        return false
      params[name] = requestParts[index]
    elif routePart != requestParts[index]:
      return false
  true

proc runRouteMiddleware(route: Route, request: Request): Response =
  ## Runs router-scoped middleware around an already matched route handler.
  var index = 0
  let scoped = route.routerMiddleware
  proc next(nextRequest: Request): Response {.closure.} =
    if index >= scoped.len:
      return route.handler(nextRequest)
    let current = scoped[index]
    inc index
    current(nextRequest, next)

  next(request)

proc dispatch(app: Application, request: Request): Response =
  ## Dispatches a request to its matching route without running middleware.
  if app.openApiSettings.enabled and request.method == HttpMethod.Get:
    if request.path == app.openApiSettings.schemaPath:
      try:
        var document: JsonNode
        {.cast(gcsafe).}:
          document = app.openApiDocument()
        return json(document)
      except CatchableError:
        return text("Unable to generate OpenAPI document", 500)
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
        return text("SSE routes require an HTTP server", 501)
      if route.kind == RouteKind.WebSocket:
        return text("WebSocket routes require an HTTP server", 501)
      if route.routerMiddleware.len > 0:
        return runRouteMiddleware(route, matchedRequest)
      return route.handler(matchedRequest)
  app.errorResponse(request, 404)

proc runMiddleware(app: Application, index: int, request: Request): Response =
  if index == app.middleware.len:
    return app.dispatch(request)

  let next: NextHandler = proc(nextRequest: Request): Response {.closure.} =
    result = app.runMiddleware(index + 1, nextRequest)
  result = app.middleware[index].handler(request, next)

proc handle*(app: Application, request: Request): Response =
  ## Runs HTTP middleware, then dispatches a request to its route or a 404 response.
  let startedAt = getMonoTime()
  var contextualRequest = request
  contextualRequest.context = app.context
  try:
    result = app.runMiddleware(0, contextualRequest)
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
