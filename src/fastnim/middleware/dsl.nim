## Declaration macro for concise request middleware.

import std/macros

import chronos

import fastnim/[context/http, routing/router]

proc replaceMiddlewareNames(node, requestParam, nextParam: NimNode): NimNode =
  if node.kind == nnkIdent:
    if eqIdent(node, "request"):
      return requestParam
    if eqIdent(node, "next"):
      return nextParam
    return node
  result = copyNimNode(node)
  for child in node:
    result.add(replaceMiddlewareNames(child, requestParam, nextParam))

macro middleware*(name: untyped, body: untyped): untyped =
  ## Declares a middleware value with ``request`` and ``next`` in scope.
  ##
  ## ```nim
  ## middleware requireAuth:
  ##   if request.header("authorization").len == 0:
  ##     return json(statusUnauthorized, %*{"detail": "missing credentials"})
  ##   await next(request)
  ##
  ## app.use(requireAuth)
  ## ```
  let requestParam = genSym(nskParam, "request")
  let nextParam = genSym(nskParam, "next")
  let middlewareBody = replaceMiddlewareNames(body, requestParam, nextParam)
  result = quote:
    let `name`: Middleware = proc(
        `requestParam`: Request, `nextParam`: NextHandler
    ): Future[Response] {.async: (raises: [CatchableError]), gcsafe.} =
      `middlewareBody`
