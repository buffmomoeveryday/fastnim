## Inertia.js server adapter for FastNim applications.
##
## Install ``inertiaPlugin`` and return pages with ``inertia`` from ordinary
## route handlers. The plugin emits HTML for initial visits and Inertia page
## JSON for requests carrying ``X-Inertia: true``.

import std/[json, strutils, tables, uri]

import chronos

import fastnim/[context/http, params/extract, plugin, routing/router]

const
  InertiaHeader* = "x-inertia" ## Identifies Inertia requests and responses.
  InertiaVersionHeader* = "x-inertia-version" ## Carries the asset version.
  InertiaLocationHeader* = "x-inertia-location" ## Requests a full-page visit.

type
  InertiaRootTemplate* = proc(pageJson: string): string {.closure.}
    ## Renders the initial HTML document around script-safe page JSON.

  InertiaOptions* = object ## Configuration installed by ``inertiaPlugin``.
    version*: string ## Identifier changed whenever client assets change.
    rootTemplate*: InertiaRootTemplate ## Renders the initial HTML document.
    sharedProps*: JsonNode ## Object merged into every page's props.

proc defaultInertiaRootTemplate*(pageJson: string): string =
  ## Renders a minimal HTML shell that loads ``/assets/app.js``.
  ##
  ## Supply a custom ``rootTemplate`` when the application uses a different
  ## asset path or needs additional head markup.
  """<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script type="module" src="/assets/app.js"></script>
  </head>
  <body>
    <script data-page="app" type="application/json">""" &
    pageJson & """</script>
    <div id="app"></div>
  </body>
</html>"""

proc initInertiaOptions*(
    version = "",
    rootTemplate: InertiaRootTemplate = defaultInertiaRootTemplate,
    sharedProps = newJObject(),
): InertiaOptions =
  ## Creates Inertia configuration.
  ##
  ## ``version`` should change whenever client assets change. ``sharedProps``
  ## are merged into every page, with route props taking precedence.
  if rootTemplate.isNil:
    raise newException(ValueError, "Inertia root template cannot be nil")
  if sharedProps.kind != JObject:
    raise newException(ValueError, "Inertia shared props must be a JSON object")
  InertiaOptions(
    version: version, rootTemplate: rootTemplate, sharedProps: sharedProps.copy()
  )

proc inertia*(component: string, props = newJObject(), status = 200): Response =
  ## Creates an Inertia page response for a route handler.
  ##
  ## The installed plugin turns this intermediate response into HTML or page
  ## JSON according to the incoming request.
  if component.len == 0:
    raise newException(ValueError, "Inertia component cannot be empty")
  if props.kind != JObject:
    raise newException(ValueError, "Inertia props must be a JSON object")
  result = initResponse($(%*{"component": component, "props": props}))
  result.status = status
  result.setHeader("content-type", "application/json; charset=utf-8")
  result.setHeader("x-fastnim-inertia-page", "true")

proc inertiaLocation*(url: string): Response =
  ## Creates a response that makes the Inertia client perform a full-page visit.
  if url.len == 0:
    raise newException(ValueError, "Inertia location cannot be empty")
  result = initResponse(statusConflict)
  result.setHeader(InertiaLocationHeader, url)

proc requestUrl(request: Request): string =
  result = request.path
  var separator = '?'
  for key, value in request.queryParams:
    result.add(separator)
    separator = '&'
    result.add(encodeUrl(key))
    result.add('=')
    result.add(encodeUrl(value))

proc addVary(response: var Response, name: string) =
  let current = response.headers.getOrDefault("vary")
  for value in current.split(','):
    if value.strip().toLowerAscii() == name.toLowerAscii():
      return
  if current.len == 0:
    response.setHeader("vary", name)
  else:
    response.setHeader("vary", current & ", " & name)

proc requestedProps(request: Request, component: string, props: JsonNode): JsonNode =
  result = newJObject()
  let partialComponent = request.header("x-inertia-partial-component")
  if request.header(InertiaHeader).toLowerAscii() != "true" or
      partialComponent != component:
    return props.copy()

  let only = request.header("x-inertia-partial-data")
  let excluded = request.header("x-inertia-partial-except")
  if only.len == 0:
    result = props.copy()
  else:
    for rawName in only.split(','):
      let name = rawName.strip()
      if name in props:
        result[name] = props[name].copy()

  if excluded.len > 0:
    for rawName in excluded.split(','):
      let name = rawName.strip()
      if name != "errors":
        result.delete(name)
  if "errors" in props:
    result["errors"] = props["errors"].copy()

proc pageJson(request: Request, response: Response, options: InertiaOptions): JsonNode =
  let routePage = parseJson(response.body)
  var props = options.sharedProps.copy()
  for name, value in routePage["props"]:
    props[name] = value.copy()
  if "errors" notin props:
    props["errors"] = newJObject()

  let component = routePage["component"].getStr()
  props = requestedProps(request, component, props)
  %*{
    "component": component,
    "props": props,
    "url": requestUrl(request),
    "version": options.version,
  }

proc scriptSafeJson(page: JsonNode): string =
  ($page).replace("/", "\\/")

proc inertiaMiddleware(options: InertiaOptions): Middleware =
  result = proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    let isInertia = request.header(InertiaHeader).toLowerAscii() == "true"
    let clientVersion = request.header(InertiaVersionHeader)
    if isInertia and request.method == HttpMethod.Get and clientVersion.len > 0 and
        clientVersion != options.version:
      result = inertiaLocation(requestUrl(request))
      result.setHeader(InertiaVersionHeader, options.version)
      return

    result = await next(request)
    if isInertia and request.method != HttpMethod.Get and result.status == 302:
      result.status = 303

    if result.headers.getOrDefault("x-fastnim-inertia-page") != "true":
      return

    result.headers.del("x-fastnim-inertia-page")
    let page = pageJson(request, result, options)
    if isInertia:
      result.body = $page
      result.setHeader("content-type", "application/json; charset=utf-8")
      result.setHeader(InertiaHeader, "true")
      result.addVary("X-Inertia")
    else:
      {.cast(gcsafe), cast(raises: [CatchableError]).}:
        result.body = options.rootTemplate(scriptSafeJson(page))
      result.setHeader("content-type", "text/html; charset=utf-8")
      result.addVary("X-Inertia")

proc inertiaPlugin*(
    options = initInertiaOptions(), name = "inertia", version = "0.1.0"
): Plugin =
  ## Creates the Inertia.js protocol plugin.
  initPlugin(
    name,
    version,
    proc(app: Application) =
      app.use(inertiaMiddleware(options), priority = -50),
  )
