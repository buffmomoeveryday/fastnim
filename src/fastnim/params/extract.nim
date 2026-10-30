## Query, path, and header extraction plus request body decoding.
##
## These helpers read values out of a ``Request``: path parameters matched
## from ``{name}`` route segments, decoded query parameters, request
## headers, and typed JSON or form bodies.
##
## Typed URL query extraction supports ``string``, ``int``, ``bool``, enums,
## ``Option[T]``, and ``seq[T]``. Boolean words are ASCII case-insensitive;
## enum strings are exact and case-sensitive. Sequences consume repeated keys,
## while commas remain ordinary characters within a value.

import std/[json, macros, options, strutils, tables]

import ../context/http
import ../jsonfields
import ../orm/uuids
import ../params/path
import ../params/validationtypes
import ../private/jsonconversion
import ../private/jsonmetadata

export validationtypes

template effectiveInputName(field: untyped, defaultName: static[string]): string =
  when field.hasCustomPragma(jsonName):
    const customName = field.getCustomPragmaVal(jsonName).name
    when customName.len == 0:
      {.error: "jsonName cannot be empty".}
    customName
  else:
    defaultName

proc pathParam*(
    request: Request, name: string, default = ""
): string {.inline, raises: [].} =
  ## Returns a matched path parameter, or ``default`` when it is absent.
  request.pathParams.getOrDefault(name, default)

proc typedPathParam*[T](request: Request, name: string): T =
  ## Returns a path parameter converted to the requested route type.
  ##
  ## Route blocks declare this conversion with ``{name:type}`` and receive a
  ## local named ``name``. Supported result types are ``string``, ``int``,
  ## ``Positive``, ``bool``, ``seq[string]`` (the ``csv`` converter), and
  ## ``UUID``.
  ## Callback handlers can call this procedure explicitly; conversion failure
  ## raises ``ValueError``. Typed route matching validates the value first.
  let raw = request.pathParam(name)
  when T is string:
    result = raw
  elif T is Positive:
    result = Positive(parseInt(raw))
  elif T is int:
    result = parseInt(raw)
  elif T is bool:
    if not parsePathBool(raw, result):
      raise newException(ValueError, "invalid boolean path parameter: " & name)
  elif T is seq[string]:
    result = raw.split(',')
  elif T is UUID:
    result = parseUUID(raw)
  else:
    {.
      error:
        "typed path parameters support string, int, Positive, bool, seq[string], and UUID"
    .}

proc queryParam*(
    request: Request, name: string, default = ""
): string {.inline, raises: [].} =
  ## Returns the final decoded URL query value, or ``default`` when absent.
  request.queryParams.getOrDefault(name, default)

proc parseQueryScalar[T](raw: string, value: var T): bool {.raises: [].} =
  try:
    when T is string:
      value = raw
    elif T is int:
      value = parseInt(raw)
    elif T is bool:
      case raw.toLowerAscii()
      of "y", "yes", "true", "1", "on":
        value = true
      of "n", "no", "false", "0", "off":
        value = false
      else:
        return false
    elif T is enum:
      let parsed = parseEnum[T](raw)
      if $parsed != raw:
        return false
      value = parsed
    else:
      {.
        error:
          "typed query parameters support string, int, bool, enum, Option[T], and seq[T]"
      .}
    true
  except ValueError:
    false

proc addQueryValueError[T](
    validation: var ValidationResult, location: openArray[string]
) {.raises: [].} =
  when T is int:
    validation.addError(location, "integer", "must be an integer")
  elif T is bool:
    validation.addError(location, "boolean", "must be a boolean")
  elif T is enum:
    validation.addError(location, "enum", "must be a valid enum value")
  elif T is string:
    discard
  else:
    {.error: "typed query parameters support scalar Option and seq item types only".}

proc extractQueryParam[T](
    request: Request,
    name: string,
    validation: var ValidationResult,
    hasDefault: bool,
    fallback: T,
): T {.raises: [].} =
  let values = request.queryParamValues(name)
  if values.len == 0:
    if hasDefault:
      return fallback
    when T is Option:
      type Item = typeof(result.get())
      return none(Item)
    elif T is seq:
      return @[]
    else:
      validation.addError(name, "required", "is required")
      return default(T)

  when T is Option:
    type Item = typeof(result.get())
    var item: Item
    if parseQueryScalar(values[^1], item):
      result = some(item)
    else:
      addQueryValueError[Item](validation, [name])
  elif T is seq:
    type Item = typeof(result[0])
    result = @[]
    for index, raw in values:
      var item: Item
      if parseQueryScalar(raw, item):
        result.add(item)
      else:
        addQueryValueError[Item](validation, [name, $index])
  else:
    if not parseQueryScalar(values[^1], result):
      addQueryValueError[T](validation, [name])

proc queryParam*[T](
    request: Request, name: string, validation: var ValidationResult
): T {.raises: [].} =
  ## Extracts a typed value from the URL query string.
  ##
  ## Missing scalar values and invalid present values are appended to
  ## ``validation``. Missing ``Option[T]`` values return ``none(T)`` and
  ## missing ``seq[T]`` values return an empty sequence. A sequence consumes
  ## repeated names in URL order; comma-separated text remains one value.
  ## Supported scalar types are ``string``, ``int``, ``bool``, and enums.
  extractQueryParam(request, name, validation, false, default(T))

proc queryParam*[T](
    request: Request, name: string, validation: var ValidationResult, default: T
): T {.raises: [].} =
  ## Extracts a typed value from the URL query string with a missing-value default.
  ##
  ## ``default`` is used only when the parameter is absent. Invalid present
  ## values are appended to ``validation`` using the same rules as the required
  ## typed query extractor.
  extractQueryParam(request, name, validation, true, default)

proc objectType(node: NimNode): NimNode {.compileTime.} =
  case node.kind
  of nnkObjectTy:
    node
  of nnkBracketExpr:
    if node.len == 2 and eqIdent(node[0], "typedesc"):
      objectType(node[1])
    else:
      newEmptyNode()
  of nnkSym:
    objectType(node.getImpl)
  of nnkTypeDef:
    objectType(node[^1])
  else:
    newEmptyNode()

macro parseQueryParams*(
    model: typedesc, request: Request, value: untyped, validation: untyped
): untyped =
  ## Populates an object model from URL query parameters.
  ##
  ## Fields with initializers retain their initialized value when the query
  ## parameter is absent. Other scalar fields are required; ``Option[T]`` and
  ## ``seq[T]`` fields use the missing-value behavior of ``queryParam``.
  ## ``jsonName`` selects a field's external query parameter name.
  let implementation = objectType(model.getTypeImpl)
  if implementation.kind != nnkObjectTy:
    error("query route models must be object types", model)

  result = newStmtList()
  for field in jsonFields(implementation):
    let queryName = newLit(field.jsonName)
    let access = newDotExpr(value, ident(field.nimName))
    let extractor = newTree(nnkBracketExpr, bindSym("queryParam"), field.fieldType)
    let assignment = newAssignment(
      access, newCall(extractor, request, newLit(field.jsonName), validation)
    )
    if field.defaultValue.kind == nnkEmpty:
      result.add(assignment)
    else:
      result.add(
        quote do:
          if `request`.queryParamValues(`queryName`).len > 0:
            `assignment`
      )

proc header*(
    request: Request, name: string, default = ""
): string {.inline, raises: [].} =
  ## Returns a request header, or ``default`` when it is absent.
  request.headers.getOrDefault(name.toLowerAscii(), default)

proc parseFormValue[T](raw: string, value: var T): bool {.raises: [].} =
  try:
    when T is Option:
      type Item = typeof(value.get())
      var item: Item
      if not parseFormValue(raw, item):
        return false
      value = some(item)
    elif T is string:
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
    value = jsonToValue(parseJson(request.body), T)
    true
  except CatchableError:
    false

proc parseFormBody*[T](request: Request, value: var T): bool {.raises: [].} =
  ## Decodes an ``application/x-www-form-urlencoded`` request body into
  ## ``value``. Non-optional fields are required and ``jsonName`` controls the
  ## external field name. Supported values are strings, booleans, numeric types,
  ## enums, and optional forms of those types.
  let fields = parseQuery(request.body)
  for name, field in fieldPairs(value):
    const inputName = effectiveInputName(field, name)
    if inputName in fields:
      if not parseFormValue(fields.getOrDefault(inputName), field):
        return false
    else:
      when field is Option:
        type Item = typeof(field.get())
        field = none(Item)
      else:
        return false
  true
