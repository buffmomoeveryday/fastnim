## Compile-time helpers shared by JSON conversion and OpenAPI generation.

import std/[macros, sets]

type JsonFieldInfo* = object
  ## Compile-time names and type information for one JSON object field.
  nimName*: string ## Field name used by Nim code.
  jsonName*: string ## Field name used by JSON and OpenAPI.
  fieldType*: NimNode ## Field type AST.
  defaultValue*: NimNode ## Field initializer AST, or ``nnkEmpty`` when absent.
  source*: NimNode ## Source AST used for compiler diagnostics.
  responseIgnored*: bool ## Whether ``jsonRespIgnore`` omits this response field.

proc bareFieldName(node: NimNode): NimNode {.compileTime.} =
  result = node
  if result.kind == nnkPragmaExpr:
    result = result[0]
  if result.kind == nnkPostfix and result.len == 2:
    result = result[1]

proc renamedFieldName(node: NimNode, defaultName: string): string {.compileTime.} =
  result = defaultName
  if node.kind != nnkPragmaExpr:
    return
  for pragma in node[1]:
    if pragma.kind in {nnkCall, nnkCommand, nnkExprColonExpr} and pragma.len >= 2 and
        eqIdent(pragma[0], "jsonName"):
      if pragma[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        error("jsonName must be a string literal", pragma)
      result = pragma[1].strVal
      if result.len == 0:
        error("jsonName cannot be empty", pragma)

proc responseIgnored(node: NimNode): bool {.compileTime.} =
  if node.kind != nnkPragmaExpr:
    return false
  for pragma in node[1]:
    let name =
      if pragma.kind in {nnkCall, nnkCommand, nnkExprColonExpr}:
        pragma[0]
      else:
        pragma
    if eqIdent(name, "jsonRespIgnore"):
      return true

proc collectFields(node: NimNode, fields: var seq[JsonFieldInfo]) {.compileTime.} =
  case node.kind
  of nnkIdentDefs:
    let fieldType = node[^2]
    for index in 0 ..< node.len - 2:
      let source = node[index]
      let name = $bareFieldName(source)
      fields.add(
        JsonFieldInfo(
          nimName: name,
          jsonName: renamedFieldName(source, name),
          fieldType: fieldType,
          defaultValue: node[^1],
          source: source,
          responseIgnored: responseIgnored(source),
        )
      )
  of nnkRecList, nnkRecCase, nnkOfBranch, nnkElse:
    for child in node:
      collectFields(child, fields)
  else:
    discard

proc jsonFields*(objectType: NimNode): seq[JsonFieldInfo] {.compileTime.} =
  ## Returns object fields and validates their effective JSON names.
  if objectType.kind != nnkObjectTy:
    return
  collectFields(objectType[^1], result)
  var names = initHashSet[string]()
  for field in result:
    if field.jsonName in names:
      error("duplicate JSON field name '" & field.jsonName & "'", field.source)
    names.incl(field.jsonName)

proc jsonFieldsIn*(record: NimNode): seq[JsonFieldInfo] {.compileTime.} =
  ## Returns JSON field metadata found below an object record node.
  collectFields(record, result)
