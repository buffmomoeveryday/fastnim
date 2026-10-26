## Field-name customization for FastNim JSON models.

import std/macros

import ./private/jsonmetadata

template jsonName*(name: static[string]) {.pragma.}
  ## Renames an object field when FastNim encodes, decodes, or documents JSON.

template jsonRespIgnore*() {.pragma.}
  ## Omits an object field from JSON responses by default.

type JsonResponseFields*[T] = object
  ## A typed response model with per-response field visibility overrides.
  value*: T ## Model serialized into the response body.
  ignoredFields*: seq[string] ## Effective JSON field names explicitly omitted.
  includedFields*: seq[string] ## Effective JSON field names explicitly retained.

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

macro fieldName*(model: typedesc, field: untyped): untyped =
  ## Returns the effective JSON name of `field` on `model`.
  ##
  ## The field is checked at compile time. A field carrying `jsonName` returns
  ## that renamed value; otherwise its Nim name is returned.
  if field.kind notin {nnkIdent, nnkSym}:
    error("fieldName expects an object field identifier", field)

  let modelType = objectType(model.getTypeImpl)
  if modelType.kind != nnkObjectTy:
    error("fieldName expects an object type", model)

  for fieldInfo in jsonFields(modelType):
    if eqIdent(field, fieldInfo.nimName):
      return newLit(fieldInfo.jsonName)

  error("unknown field '" & $field & "' for " & $model, field)

proc responseModelType(node: NimNode): NimNode {.compileTime.} =
  result = node.getTypeInst
  if result.kind == nnkBracketExpr and result.len == 2 and
      eqIdent(result[0], "JsonResponseFields"):
    result = result[1]

proc responseFieldName(model, selector: NimNode): string {.compileTime.} =
  let field =
    if selector.kind == nnkDotExpr and selector.len == 2:
      selector[1]
    else:
      selector
  if field.kind notin {nnkIdent, nnkSym}:
    error("response field selectors must use `Model.field`", selector)

  let modelObject = objectType(model.getTypeImpl)
  if modelObject.kind != nnkObjectTy:
    error("response field filtering expects an object model", model)
  for fieldInfo in jsonFields(modelObject):
    if eqIdent(field, fieldInfo.nimName):
      return fieldInfo.jsonName
  error("unknown response field '" & $field & "' for " & $model, selector)

proc addUnique(fields: var seq[string], field: string) =
  if field notin fields:
    fields.add(field)

proc remove(fields: var seq[string], field: string) =
  for index, candidate in fields:
    if candidate == field:
      fields.delete(index)
      return

proc withIgnoredField[T](value: T, field: string): JsonResponseFields[T] =
  result = JsonResponseFields[T](value: value)
  result.ignoredFields.add(field)

proc withIgnoredField[T](
    value: JsonResponseFields[T], field: string
): JsonResponseFields[T] =
  result = value
  result.includedFields.remove(field)
  result.ignoredFields.addUnique(field)

proc withIncludedField[T](value: T, field: string): JsonResponseFields[T] =
  result = JsonResponseFields[T](value: value)
  result.includedFields.add(field)

proc withIncludedField[T](
    value: JsonResponseFields[T], field: string
): JsonResponseFields[T] =
  result = value
  result.ignoredFields.remove(field)
  result.includedFields.addUnique(field)

macro ignore*(value: typed, fields: varargs[untyped]): untyped =
  ## Explicitly omits model fields from this JSON response.
  ##
  ## Fields are checked at compile time and use ``Model.field`` selectors.
  ## Explicit rules take precedence over ``jsonRespIgnore`` and the last call
  ## wins when the same field is passed to both ``ignore`` and ``include``.
  if fields.len == 0:
    error("ignore expects at least one `Model.field` selector", value)
  let model = responseModelType(value)
  result = value
  for field in fields:
    result = newCall(
      bindSym("withIgnoredField"), result, newLit(responseFieldName(model, field))
    )

macro `include`*(value: typed, fields: varargs[untyped]): untyped =
  ## Explicitly includes model fields in this JSON response.
  ##
  ## This overrides ``jsonRespIgnore`` for the selected fields. Fields are
  ## checked at compile time and use ``Model.field`` selectors.
  if fields.len == 0:
    error("include expects at least one `Model.field` selector", value)
  let model = responseModelType(value)
  result = value
  for field in fields:
    result = newCall(
      bindSym("withIncludedField"), result, newLit(responseFieldName(model, field))
    )
