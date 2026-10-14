## Built-in HTTP middleware for FastNim applications.

import std/[monotimes, sequtils, strutils, times]

import chronos

import ../context/http, ../params/extract, ../routing/router

type
  CorsOptions* = object ## Configuration for Cross-Origin Resource Sharing middleware.
    allowOrigins*: seq[string] ## Permitted origins; empty denies every origin.
    allowMethods*: seq[HttpMethod] ## Methods advertised for preflight requests.
    allowHeaders*: seq[string] ## Headers advertised for preflight requests.
    exposeHeaders*: seq[string] ## Response headers exposed to browser clients.
    allowCredentials*: bool ## Emits ``access-control-allow-credentials`` when true.
    maxAge*: int ## Preflight cache lifetime in seconds.

  RequestIdFactory* = proc(): string {.closure.}
    ## Creates an ID for a request that did not provide one.

proc initCorsOptions*(
    allowOrigins: seq[string] = @[],
    allowMethods: seq[HttpMethod] = @[
      HttpMethod.Get, HttpMethod.Post, HttpMethod.Put, HttpMethod.Patch,
      HttpMethod.Delete, HttpMethod.Options,
    ],
    allowHeaders: seq[string] = @[],
    exposeHeaders: seq[string] = @[],
    allowCredentials = false,
    maxAge = 600,
): CorsOptions =
  ## Creates CORS configuration. Origins are denied until explicitly allowed.
  CorsOptions(
    allowOrigins: allowOrigins,
    allowMethods: allowMethods,
    allowHeaders: allowHeaders,
    exposeHeaders: exposeHeaders,
    allowCredentials: allowCredentials,
    maxAge: maxAge,
  )

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

proc allowsOrigin(options: CorsOptions, origin: string): bool =
  origin in options.allowOrigins or "*" in options.allowOrigins

proc allowsMethod(options: CorsOptions, `method`: string): bool =
  for allowed in options.allowMethods:
    if methodName(allowed) == `method`.toUpperAscii():
      return true
  false

proc applyCors(response: var Response, options: CorsOptions, origin: string) =
  if "*" in options.allowOrigins and not options.allowCredentials:
    response.setHeader("access-control-allow-origin", "*")
  else:
    response.setHeader("access-control-allow-origin", origin)
  response.setHeader("vary", "origin")
  if options.allowCredentials:
    response.setHeader("access-control-allow-credentials", "true")
  if options.exposeHeaders.len > 0:
    response.setHeader(
      "access-control-expose-headers", options.exposeHeaders.join(", ")
    )

proc cors*(options = initCorsOptions()): Middleware =
  ## Creates CORS middleware. It handles valid preflight requests with ``204``
  ## and applies CORS headers to matching cross-origin responses.
  result = proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    let origin = request.header("origin")
    if origin.len == 0 or not options.allowsOrigin(origin):
      return await next(request)

    let requestedMethod = request.header("access-control-request-method")
    if request.method == HttpMethod.Options and requestedMethod.len > 0:
      if not options.allowsMethod(requestedMethod):
        return text(statusForbidden, "CORS method not allowed")
      result = initResponse(statusNoContent)
      result.applyCors(options, origin)
      result.setHeader(
        "access-control-allow-methods",
        options.allowMethods.mapIt(methodName(it)).join(", "),
      )
      if options.allowHeaders.len > 0:
        result.setHeader(
          "access-control-allow-headers", options.allowHeaders.join(", ")
        )
      elif request.header("access-control-request-headers").len > 0:
        result.setHeader(
          "access-control-allow-headers",
          request.header("access-control-request-headers"),
        )
      if options.maxAge >= 0:
        result.setHeader("access-control-max-age", $options.maxAge)
      return

    result = await next(request)
    result.applyCors(options, origin)

proc requestId*(
    headerName = "x-request-id", factory: RequestIdFactory = nil
): Middleware =
  ## Creates middleware that propagates or generates a request ID response header.
  result = proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    var forwardedRequest = request
    let requestId =
      if request.header(headerName).len > 0:
        request.header(headerName)
      elif factory.isNil:
        "fastnim-" & $getMonoTime().ticks
      else:
        {.cast(gcsafe), cast(raises: [CatchableError]).}:
          factory()
    forwardedRequest.headers[headerName.toLowerAscii()] = requestId
    result = await next(forwardedRequest)
    result.setHeader(headerName, requestId)

proc responseTime*(headerName = "x-response-time-us"): Middleware =
  ## Creates middleware that adds the downstream elapsed time in microseconds.
  result = proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    let startedAt = getMonoTime()
    result = await next(request)
    result.setHeader(headerName, $(getMonoTime() - startedAt).inMicroseconds)
