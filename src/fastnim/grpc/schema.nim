## Compile-time protobuf schema validation for typed gRPC routes.

import std/[macros, os, strutils]

type
  ProtoField = object
    name: string
    typeName: string
    number: int
    repeated: bool

  ProtoMessage = object
    name: string
    fields: seq[ProtoField]

  ProtoMethod = object
    path: string
    requestType: string
    responseType: string
    requestStreaming: bool
    responseStreaming: bool

  ProtoSchema = object
    packageName: string
    messages: seq[ProtoMessage]
    methods: seq[ProtoMethod]

  NimField = object
    name: string
    typeNode: NimNode

proc isIdentStart(value: char): bool {.compileTime.} =
  value in {'a'..'z', 'A'..'Z', '_'}

proc isIdentContinue(value: char): bool {.compileTime.} =
  value.isIdentStart() or value in {'0'..'9'}

proc tokenize(source: string): seq[string] {.compileTime.} =
  var position = 0
  while position < source.len:
    if source[position] in Whitespace:
      inc position
    elif source[position] == '/' and position + 1 < source.len and
        source[position + 1] == '/':
      position += 2
      while position < source.len and source[position] notin {'\r', '\n'}:
        inc position
    elif source[position] == '/' and position + 1 < source.len and
        source[position + 1] == '*':
      position += 2
      while position + 1 < source.len and
          not (source[position] == '*' and source[position + 1] == '/'):
        inc position
      if position + 1 >= source.len:
        raise newException(ValueError, "unterminated protobuf block comment")
      position += 2
    elif source[position].isIdentStart():
      let first = position
      inc position
      while position < source.len and source[position].isIdentContinue():
        inc position
      result.add(source[first..<position])
    elif source[position] in {'0'..'9'}:
      let first = position
      inc position
      while position < source.len and source[position] in {'0'..'9'}:
        inc position
      result.add(source[first..<position])
    elif source[position] in {'\'', '"'}:
      let quote = source[position]
      let first = position
      inc position
      while position < source.len and source[position] != quote:
        if source[position] == '\\' and position + 1 < source.len:
          position += 2
        else:
          inc position
      if position >= source.len:
        raise newException(ValueError, "unterminated protobuf string")
      inc position
      result.add(source[first..<position])
    else:
      result.add($source[position])
      inc position

proc requireToken(
    tokens: seq[string], position: var int, expected: string
) {.compileTime.} =
  if position >= tokens.len or tokens[position] != expected:
    let actual = if position < tokens.len: tokens[position] else: "end of file"
    raise newException(
      ValueError, "expected '" & expected & "' in protobuf schema, got '" & actual & "'"
    )
  inc position

proc takeName(tokens: seq[string], position: var int): string {.compileTime.} =
  if position < tokens.len and tokens[position] == ".":
    inc position
  if position >= tokens.len or tokens[position].len == 0 or
      not tokens[position][0].isIdentStart():
    raise newException(ValueError, "expected protobuf identifier")
  result = tokens[position]
  inc position
  while position + 1 < tokens.len and tokens[position] == ".":
    inc position
    result.add('.' & tokens[position])
    inc position

proc skipStatement(tokens: seq[string], position: var int) {.compileTime.} =
  var squareDepth = 0
  while position < tokens.len:
    case tokens[position]
    of "[": inc squareDepth
    of "]": dec squareDepth
    of ";":
      inc position
      if squareDepth == 0:
        return
    else:
      discard
    inc position

proc skipBlock(tokens: seq[string], position: var int) {.compileTime.} =
  while position < tokens.len and tokens[position] != "{":
    inc position
  tokens.requireToken(position, "{")
  var depth = 1
  while position < tokens.len and depth > 0:
    case tokens[position]
    of "{": inc depth
    of "}": dec depth
    else: discard
    inc position
  if depth != 0:
    raise newException(ValueError, "unterminated protobuf block")

proc qualify(packageName, typeName: string): string {.compileTime.} =
  if '.' in typeName or packageName.len == 0:
    typeName
  else:
    packageName & "." & typeName

proc parseMessage(
    tokens: seq[string], position: var int, packageName: string
): ProtoMessage {.compileTime.} =
  result.name = packageName.qualify(tokens.takeName(position))
  tokens.requireToken(position, "{")
  while position < tokens.len and tokens[position] != "}":
    if tokens[position] in ["message", "enum", "oneof", "extend"]:
      inc position
      tokens.skipBlock(position)
      continue
    if tokens[position] in ["option", "reserved", "extensions"]:
      tokens.skipStatement(position)
      continue

    var repeated = false
    if tokens[position] in ["optional", "required", "repeated"]:
      repeated = tokens[position] == "repeated"
      inc position
    if position >= tokens.len:
      raise newException(ValueError, "truncated protobuf message")
    if tokens[position] == "map":
      raise newException(ValueError, "protobuf map fields are not supported")
    let typeName = tokens.takeName(position)
    let fieldName = tokens.takeName(position)
    tokens.requireToken(position, "=")
    if position >= tokens.len:
      raise newException(ValueError, "missing protobuf field number")
    let fieldNumber = parseInt(tokens[position])
    inc position
    result.fields.add(ProtoField(
      name: fieldName,
      typeName: packageName.qualify(typeName),
      number: fieldNumber,
      repeated: repeated,
    ))
    tokens.skipStatement(position)
  tokens.requireToken(position, "}")

proc parseService(
    schema: var ProtoSchema, tokens: seq[string], position: var int
) {.compileTime.} =
  let serviceName = tokens.takeName(position)
  tokens.requireToken(position, "{")
  while position < tokens.len and tokens[position] != "}":
    if tokens[position] != "rpc":
      tokens.skipStatement(position)
      continue
    inc position
    let methodName = tokens.takeName(position)
    tokens.requireToken(position, "(")
    let requestStreaming = position < tokens.len and tokens[position] == "stream"
    if requestStreaming:
      inc position
    let requestType = schema.packageName.qualify(tokens.takeName(position))
    tokens.requireToken(position, ")")
    tokens.requireToken(position, "returns")
    tokens.requireToken(position, "(")
    let responseStreaming = position < tokens.len and tokens[position] == "stream"
    if responseStreaming:
      inc position
    let responseType = schema.packageName.qualify(tokens.takeName(position))
    tokens.requireToken(position, ")")
    schema.methods.add(ProtoMethod(
      path: "/" & schema.packageName.qualify(serviceName) & "/" & methodName,
      requestType: requestType,
      responseType: responseType,
      requestStreaming: requestStreaming,
      responseStreaming: responseStreaming,
    ))
    if position < tokens.len and tokens[position] == "{":
      tokens.skipBlock(position)
    else:
      tokens.requireToken(position, ";")
  tokens.requireToken(position, "}")

proc parseSchema(source: string): ProtoSchema {.compileTime.} =
  let tokens = source.tokenize()
  var position = 0
  while position < tokens.len:
    case tokens[position]
    of "syntax", "import", "option":
      tokens.skipStatement(position)
    of "package":
      inc position
      result.packageName = tokens.takeName(position)
      tokens.requireToken(position, ";")
    of "message":
      inc position
      result.messages.add(tokens.parseMessage(position, result.packageName))
    of "service":
      inc position
      result.parseService(tokens, position)
    of "enum", "extend":
      inc position
      tokens.skipBlock(position)
    else:
      raise newException(
        ValueError, "unsupported top-level protobuf declaration '" & tokens[position] & "'"
      )

proc staticString(node: NimNode, label: string): string {.compileTime.} =
  case node.kind
  of nnkStrLit..nnkTripleStrLit:
    result = node.strVal
  of nnkSym:
    let implementation = node.getImpl()
    if implementation.kind == nnkConstDef:
      result = staticString(implementation[^1], label)
    else:
      error(label & " must be a compile-time string constant", node)
  else:
    error(label & " must be a compile-time string literal", node)

proc resolveProtoPath*(node: NimNode): string {.compileTime.} =
  ## Resolves a protobuf path relative to the source file containing the route.
  let relativePath = staticString(node, "gRPC `proto`")
  if relativePath.isAbsolute():
    relativePath
  else:
    node.lineInfoObj.filename.parentDir / relativePath

proc normalized(name: string): string {.compileTime.} =
  name.replace("_", "").toLowerAscii()

proc bareName(name: string): string {.compileTime.} =
  let separator = name.rfind('.')
  if separator < 0: name else: name[separator + 1..^1]

proc nimTypeName(node: NimNode): string {.compileTime.} =
  case node.kind
  of nnkSym, nnkIdent:
    result = node.strVal
  of nnkBracketExpr:
    result = nimTypeName(node[0]) & "["
    for index in 1..<node.len:
      if index > 1:
        result.add(", ")
      result.add(nimTypeName(node[index]))
    result.add(']')
  else:
    result = node.repr

proc objectFields(typeNode: NimNode): seq[NimField] {.compileTime.} =
  var implementation = typeNode.getImpl()
  if implementation.kind == nnkTypeDef:
    implementation = implementation[2]
  if implementation.kind != nnkObjectTy:
    error("gRPC protobuf models must be object types", typeNode)
  let records = implementation[2]
  for definition in records:
    if definition.kind != nnkIdentDefs:
      error("variant protobuf objects are not supported", definition)
    for index in 0..<definition.len - 2:
      var nameNode = definition[index]
      if nameNode.kind == nnkPostfix:
        nameNode = nameNode[1]
      result.add(NimField(name: nameNode.strVal, typeNode: definition[^2]))

proc expectedNimType(field: ProtoField): string {.compileTime.} =
  var base: string
  case field.typeName.bareName()
  of "double": base = "float64"
  of "float": base = "float32"
  of "int32": base = "int32"
  of "int64": base = "int64"
  of "uint32": base = "uint32"
  of "uint64": base = "uint64"
  of "bool": base = "bool"
  of "string": base = "string"
  of "bytes": base = "seq[byte]"
  of "sint32", "sint64", "fixed32", "fixed64", "sfixed32", "sfixed64":
    error(
      "protobuf type '" & field.typeName.bareName() &
        "' is not supported by FastNim's built-in codec"
    )
  else:
    base = field.typeName.bareName()
  if field.repeated:
    "seq[" & base & "]"
  else:
    base

proc findMessage(schema: ProtoSchema, name: string): ProtoMessage {.compileTime.} =
  for message in schema.messages:
    if message.name == name:
      return message
  raise newException(ValueError, "protobuf message '" & name & "' is not declared")

proc validateMessage(
    schema: ProtoSchema, messageName: string, typeNode, errorNode: NimNode
) {.compileTime.} =
  let message = schema.findMessage(messageName)
  let fields = objectFields(typeNode)
  if fields.len != message.fields.len:
    error(
      "Nim type '" & nimTypeName(typeNode) & "' has " & $fields.len &
        " fields, but protobuf message '" & messageName & "' has " &
        $message.fields.len,
      errorNode,
    )
  for index, protoField in message.fields:
    let nimField = fields[index]
    if protoField.number != index + 1:
      error(
        "protobuf field '" & protoField.name & "' uses number " &
          $protoField.number & "; FastNim's built-in codec requires declaration-order " &
          "field numbers starting at 1",
        errorNode,
      )
    if nimField.name.normalized() != protoField.name.normalized():
      error(
        "Nim field '" & nimField.name & "' does not match protobuf field '" &
          protoField.name & "' at field number " & $protoField.number,
        errorNode,
      )
    let expected = protoField.expectedNimType()
    let actual = nimTypeName(nimField.typeNode)
    if actual != expected:
      error(
        "Nim field '" & nimField.name & "' has type '" & actual &
          "', but protobuf field '" & protoField.name & "' requires '" & expected & "'",
        errorNode,
      )

proc validateGrpcSchema*(
    protoNode, pathNode, requestType, responseType: NimNode,
    requestStreaming, responseStreaming: bool,
) {.compileTime.} =
  ## Validates one typed route against a protobuf file during macro expansion.
  let relativePath = staticString(protoNode, "gRPC `proto`")
  let schemaPath = resolveProtoPath(protoNode)
  let source = staticRead(schemaPath)
  let schema = parseSchema(source)
  let path = staticString(pathNode, "gRPC route path")
  var selected: ProtoMethod
  var found = false
  for rpcMethod in schema.methods:
    if rpcMethod.path == path:
      selected = rpcMethod
      found = true
      break
  if not found:
    error("gRPC method '" & path & "' is not declared in " & relativePath, pathNode)
  if selected.requestStreaming != requestStreaming or
      selected.responseStreaming != responseStreaming:
    error("gRPC streaming shape does not match protobuf method '" & path & "'", pathNode)
  if nimTypeName(requestType) != selected.requestType.bareName():
    error(
      "route request type '" & nimTypeName(requestType) &
        "' does not match protobuf request '" & selected.requestType.bareName() & "'",
      requestType,
    )
  if nimTypeName(responseType) != selected.responseType.bareName():
    error(
      "route response type '" & nimTypeName(responseType) &
        "' does not match protobuf response '" & selected.responseType.bareName() & "'",
      responseType,
    )
  schema.validateMessage(selected.requestType, requestType, requestType)
  schema.validateMessage(selected.responseType, responseType, responseType)

macro validateGrpcContract*(
    protoPath, path: static[string], requestType, responseType: typedesc,
    requestStreaming, responseStreaming: static[bool],
): untyped =
  ## Checks a route after Nim has resolved its request and response types.
  let protoNode = newLit(protoPath)
  protoNode.copyLineInfo(requestType)
  let pathNode = newLit(path)
  pathNode.copyLineInfo(requestType)
  validateGrpcSchema(
    protoNode,
    pathNode,
    requestType,
    responseType,
    requestStreaming,
    responseStreaming,
  )
  newEmptyNode()
