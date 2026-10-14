## Field-name customization for FastNim JSON models.

import std/macros

import ./private/jsonmetadata

template jsonName*(name: static[string]) {.pragma.}
  ## Renames an object field when FastNim encodes, decodes, or documents JSON.

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
