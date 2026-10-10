## Query, path, and header extraction plus request body decoding.
##
## These helpers read values out of a ``Request``: path parameters matched
## from ``{name}`` route segments, decoded query parameters, request
## headers, and typed JSON or form bodies.

import std/[json, jsonutils, strutils, tables]

import fastnim/context/http

proc pathParam*(
    request: Request, name: string, default = ""
): string {.inline, raises: [].} =
  ## Returns a matched path parameter, or ``default`` when it is absent.
  request.pathParams.getOrDefault(name, default)

proc queryParam*(
    request: Request, name: string, default = ""
): string {.inline, raises: [].} =
  ## Returns a decoded query parameter, or ``default`` when it is absent.
  request.queryParams.getOrDefault(name, default)

proc header*(
    request: Request, name: string, default = ""
): string {.inline, raises: [].} =
  ## Returns a request header, or ``default`` when it is absent.
  request.headers.getOrDefault(name.toLowerAscii(), default)

proc parseFormValue[T](raw: string, value: var T): bool {.raises: [].} =
  try:
    when T is string:
      value = raw
    elif T is bool:
      value = parseBool(raw)
    elif T is SomeInteger:
      value = T(parseBiggestInt(raw))
    elif T is SomeFloat:
      value = T(parseFloat(raw))
    elif T is enum:
      value = parseEnum[T](raw)
    else:
      return false
    true
  except CatchableError:
    false

proc parseJsonBody*[T](request: Request, value: var T): bool {.raises: [].} =
  ## Decodes a JSON request body into ``value`` and returns whether it was valid.
  try:
    value = jsonTo(parseJson(request.body), T)
    true
  except CatchableError:
    false

proc parseFormBody*[T](request: Request, value: var T): bool {.raises: [].} =
  ## Decodes an ``application/x-www-form-urlencoded`` request body into
  ## ``value``. Supported fields are strings, booleans, numeric types, and enums.
  let fields = parseQuery(request.body)
  for name, field in fieldPairs(value):
    if name in fields and not parseFormValue(fields.getOrDefault(name), field):
      return false
  true
