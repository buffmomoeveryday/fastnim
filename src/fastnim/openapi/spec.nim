## OpenAPI document and Swagger UI helpers for FastNim applications.

import std/[json, macros, strutils]

import ../params/path
import ../private/jsonmetadata

type
  OpenApiSettings* = object
    ## Controls FastNim's generated OpenAPI and Swagger UI endpoints.
    title*: string ## API title shown in the document and docs page.
    version*: string ## API version reported by the document.
    description*: string ## Optional API description, omitted when empty.
    schemaPath*: string ## Route serving the generated OpenAPI JSON.
    docsPath*: string ## Route serving the Swagger UI page.
    enabled*: bool ## Serves both built-in endpoints when true.

  OpenApiRoute* = object ## Optional documentation supplied for a route.
    summary*: string ## Short operation summary.
    description*: string ## Long operation description.
    tags*: seq[string] ## Tags grouping the operation in Swagger UI.
    operationId*: string ## Stable operation identifier.
    deprecated*: bool ## Marks the operation deprecated when true.

  OpenApiOperation* = object
    ## Documentation recorded for one HTTP operation.
    ## ``method`` holds the lowercase HTTP method for the operation.
    `method`*: string ## Lowercase HTTP method for the operation.
    path*: string ## Route path template with ``{name}`` parameters.
    route*: OpenApiRoute ## Human-facing route documentation.
    responses*: JsonNode ## Status-keyed response objects.
    parameters*: JsonNode ## Operation parameters, null when the route takes none.
    requestBody*: JsonNode ## Request body object, null when the route takes none.

proc initOpenApiSettings*(
    title = "FastNim API",
    version = "0.1.0",
    description = "",
    schemaPath = "/openapi.json",
    docsPath = "/docs",
    enabled = true,
): OpenApiSettings =
  ## Creates OpenAPI endpoint settings.
  OpenApiSettings(
    title: title,
    version: version,
    description: description,
    schemaPath: schemaPath,
    docsPath: docsPath,
    enabled: enabled,
  )

proc initOpenApiRoute*(
    summary = "",
    description = "",
    tags: seq[string] = @[],
    operationId = "",
    deprecated = false,
): OpenApiRoute =
  ## Creates optional documentation metadata for a route.
  OpenApiRoute(
    summary: summary,
    description: description,
    tags: tags,
    operationId: operationId,
    deprecated: deprecated,
  )

proc initOpenApiOperation*(
    `method`, path: string, route = OpenApiRoute()
): OpenApiOperation =
  ## Creates minimal metadata for an untyped route.
  OpenApiOperation(
    `method`: `method`.toLowerAscii(),
    path: path,
    route: route,
    responses: newJObject(),
    parameters: newJNull(),
    requestBody: newJNull(),
  )

proc typeSchema(node: NimNode): JsonNode {.compileTime.}
proc responseTypeSchema(
    node: NimNode,
    ignoredFields, includedFields: seq[string],
    root: bool,
): JsonNode {.compileTime.}

proc isOptionType(node: NimNode): bool {.compileTime.} =
  if node.kind == nnkBracketExpr and node.len == 2 and eqIdent(node[0], "Option"):
    return true
  if node.kind == nnkSym:
    let impl = node.getImpl()
    if impl.kind == nnkTypeDef:
      return isOptionType(impl[^1])
  false

proc isSequenceType(node: NimNode): bool {.compileTime.} =
  if node.kind == nnkBracketExpr and node.len == 2 and eqIdent(node[0], "seq"):
    return true
  if node.kind == nnkSym:
    let impl = node.getImpl()
    if impl.kind == nnkTypeDef:
      return isSequenceType(impl[^1])
  false

proc objectType(node: NimNode): NimNode {.compileTime.} =
  case node.kind
  of nnkObjectTy:
    node
  of nnkBracketExpr:
    if node.len == 2 and ($node[0] == "typeDesc" or $node[0] == "typedesc"):
      objectType(node[1])
    else:
      newEmptyNode()
  of nnkSym:
    objectType(node.getImpl)
  of nnkTypeDef:
    objectType(node[^1])
  else:
    newEmptyNode()

proc numericLiteral(node: NimNode): JsonNode {.compileTime.} =
  case node.kind
  of nnkIntLit .. nnkUInt64Lit:
    result = newJInt(node.intVal)
  of nnkFloatLit .. nnkFloat128Lit:
    result = newJFloat(node.floatVal)
  of nnkPrefix:
    if node.len == 2 and eqIdent(node[0], "-"):
      result = numericLiteral(node[1])
      if result.kind == JInt:
        result = newJInt(-result.getBiggestInt())
      elif result.kind == JFloat:
        result = newJFloat(-result.getFloat())
      else:
        error("validation bound must be a numeric literal", node)
    else:
      error("validation bound must be a numeric literal", node)
  else:
    error("validation bound must be a numeric literal", node)

proc numericValue(node: JsonNode): BiggestFloat {.compileTime.} =
  if node.kind == JInt:
    BiggestFloat(node.getBiggestInt())
  else:
    BiggestFloat(node.getFloat())

proc compareNumbers(a, b: JsonNode): int {.compileTime.} =
  if a.kind == JInt and b.kind == JInt:
    cmp(a.getBiggestInt(), b.getBiggestInt())
  else:
    cmp(a.numericValue(), b.numericValue())

proc mergeMinimum(schema: var JsonNode, name: string, bound: JsonNode) {.compileTime.} =
  if name notin schema or compareNumbers(bound, schema[name]) > 0:
    schema[name] = bound

proc mergeMaximum(schema: var JsonNode, name: string, bound: JsonNode) {.compileTime.} =
  if name notin schema or compareNumbers(bound, schema[name]) < 0:
    schema[name] = bound

proc applyValidationSchema(schema: var JsonNode, source: NimNode) {.compileTime.} =
  if source.kind != nnkPragmaExpr:
    return
  for pragma in source[1]:
    let name =
      if pragma.kind in {nnkCall, nnkCommand, nnkExprColonExpr}:
        $pragma[0]
      else:
        $pragma
    case name
    of "nonEmpty":
      schema.mergeMinimum("minLength", newJInt(1))
    of "email":
      schema["format"] = newJString("email")
    of "positive":
      schema.mergeMinimum("exclusiveMinimum", newJInt(0))
    of "minValue", "ge":
      schema.mergeMinimum("minimum", numericLiteral(pragma[1]))
    of "maxValue", "le":
      schema.mergeMaximum("maximum", numericLiteral(pragma[1]))
    of "gt":
      schema.mergeMinimum("exclusiveMinimum", numericLiteral(pragma[1]))
    of "lt":
      schema.mergeMaximum("exclusiveMaximum", numericLiteral(pragma[1]))
    of "minLen":
      if schema.getOrDefault("type").getStr() == "array":
        schema.mergeMinimum("minItems", numericLiteral(pragma[1]))
      else:
        schema.mergeMinimum("minLength", numericLiteral(pragma[1]))
    of "maxLen":
      if schema.getOrDefault("type").getStr() == "array":
        schema.mergeMaximum("maxItems", numericLiteral(pragma[1]))
      else:
        schema.mergeMaximum("maxLength", numericLiteral(pragma[1]))
    else:
      discard

proc namedTypeSchema(name: string): JsonNode {.compileTime.} =
  case name
  of "string", "cstring", "char":
    %*{"type": "string"}
  of "bool":
    %*{"type": "boolean"}
  of "float", "float32", "float64":
    %*{"type": "number"}
  of "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
      "uint64":
    %*{"type": "integer"}
  of "JsonNode":
    newJObject()
  else:
    newJObject()

proc typeSchema(node: NimNode): JsonNode {.compileTime.} =
  var current = node
  if current.kind == nnkBracketExpr and current.len == 2 and $current[0] == "typeDesc":
    current = current[1]
  if current.kind == nnkSym:
    let named = namedTypeSchema($current)
    if named.len > 0:
      return named
    let impl = current.getImpl
    if impl.kind == nnkTypeDef:
      return typeSchema(impl[^1])
    return namedTypeSchema($current)
  if current.kind == nnkIdent:
    return namedTypeSchema($current)
  if current.kind == nnkBracketExpr:
    let container = $current[0]
    if container in ["seq", "array"]:
      let item = current[^1]
      return %*{"type": "array", "items": typeSchema(item)}
    if container in ["Table", "OrderedTable"] and current.len == 3:
      return %*{
        "type": "object", "additionalProperties": typeSchema(current[2])
      }
    if container == "Option":
      result = typeSchema(current[1])
      result["nullable"] = newJBool(true)
      return result
  if current.kind == nnkRefTy:
    return typeSchema(current[0])
  if current.kind == nnkObjectTy:
    result = %*{"type": "object", "properties": newJObject(), "required": newJArray()}
    for field in jsonFields(current):
      var fieldSchema = typeSchema(field.fieldType)
      fieldSchema.applyValidationSchema(field.source)
      result["properties"][field.jsonName] = fieldSchema
      if not field.fieldType.isOptionType():
        result["required"].add(newJString(field.jsonName))
    return result
  if current.kind == nnkEnumTy:
    result = %*{"type": "string", "enum": newJArray()}
    for item in current:
      if item.kind == nnkEnumFieldDef:
        result["enum"].add(newJString($item[0]))
      elif item.kind in {nnkIdent, nnkSym}:
        result["enum"].add(newJString($item))
    return result
  newJObject()

proc selected(fields: seq[string], name: string): bool {.compileTime.} =
  for field in fields:
    if field == name:
      return true

proc responseFieldVisible(
    field: JsonFieldInfo,
    ignoredFields, includedFields: seq[string],
    root: bool,
): bool {.compileTime.} =
  let explicitlyIgnored = ignoredFields.selected(field.nimName) or
    ignoredFields.selected(field.jsonName)
  let explicitlyIncluded = includedFields.selected(field.nimName) or
    includedFields.selected(field.jsonName)
  if root and explicitlyIgnored:
    return false
  not field.responseIgnored or (root and explicitlyIncluded)

proc addResponseField(
    schema: JsonNode,
    field: JsonFieldInfo,
    ignoredFields, includedFields: seq[string],
    root: bool,
) {.compileTime.} =
  if not field.responseFieldVisible(ignoredFields, includedFields, root):
    return
  var fieldSchema = responseTypeSchema(
    field.fieldType, ignoredFields, includedFields, false
  )
  fieldSchema.applyValidationSchema(field.source)
  schema["properties"][field.jsonName] = fieldSchema
  if not field.fieldType.isOptionType():
    schema["required"].add(newJString(field.jsonName))

proc newObjectSchema(): JsonNode {.compileTime.} =
  %*{"type": "object", "properties": newJObject(), "required": newJArray()}

proc responseObjectSchema(
    objectType: NimNode,
    ignoredFields, includedFields: seq[string],
    root: bool,
): JsonNode {.compileTime.} =
  var variant = newEmptyNode()
  var commonFields: seq[JsonFieldInfo]
  for child in objectType[^1]:
    if child.kind == nnkRecCase:
      variant = child
    else:
      commonFields.add(jsonFieldsIn(child))

  if variant.kind == nnkEmpty:
    result = newObjectSchema()
    for field in jsonFields(objectType):
      result.addResponseField(field, ignoredFields, includedFields, root)
    return

  let discriminatorFields = jsonFieldsIn(variant[0])
  result = %*{"oneOf": newJArray()}
  for index in 1 ..< variant.len:
    let branch = variant[index]
    if branch.kind in {nnkOfBranch, nnkElse}:
      var branchSchema = newObjectSchema()
      for field in commonFields:
        branchSchema.addResponseField(field, ignoredFields, includedFields, root)
      for field in discriminatorFields:
        branchSchema.addResponseField(field, ignoredFields, includedFields, root)
      if branch.len > 0:
        for field in jsonFieldsIn(branch[^1]):
          branchSchema.addResponseField(field, ignoredFields, includedFields, root)
      result["oneOf"].add(branchSchema)

proc responseEnumSchema(enumType: NimNode): JsonNode {.compileTime.} =
  result = %*{"type": "integer", "enum": newJArray()}
  var ordinal = 0
  for item in enumType:
    if item.kind != nnkEmpty:
      if item.kind == nnkEnumFieldDef and item.len == 2 and
          item[1].kind in {nnkIntLit .. nnkUInt64Lit}:
        ordinal = item[1].intVal.int
      result["enum"].add(newJInt(ordinal))
      inc ordinal

proc responseTypeSchema(
    node: NimNode,
    ignoredFields, includedFields: seq[string],
    root: bool,
): JsonNode {.compileTime.} =
  var current = node
  if current.kind == nnkBracketExpr and current.len == 2 and
      eqIdent(current[0], "typeDesc"):
    current = current[1]
  if current.kind == nnkSym:
    let named = namedTypeSchema($current)
    if named.len > 0:
      return named
    let impl = current.getImpl
    if impl.kind == nnkTypeDef:
      return responseTypeSchema(
        impl[^1], ignoredFields, includedFields, root
      )
  if current.kind == nnkIdent:
    return namedTypeSchema($current)
  if current.kind == nnkBracketExpr:
    let container = $current[0]
    if container in ["seq", "array"]:
      return %*{
        "type": "array",
        "items": responseTypeSchema(
          current[^1], ignoredFields, includedFields, false
        ),
      }
    if container in ["Table", "OrderedTable"] and current.len == 3:
      return %*{
        "type": "object",
        "additionalProperties": responseTypeSchema(
          current[2], ignoredFields, includedFields, false
        ),
      }
    if container == "Option":
      result = responseTypeSchema(
        current[1], ignoredFields, includedFields, false
      )
      result["nullable"] = newJBool(true)
      return
  if current.kind == nnkRefTy:
    return responseTypeSchema(current[0], ignoredFields, includedFields, root)
  if current.kind == nnkObjectTy:
    return responseObjectSchema(current, ignoredFields, includedFields, root)
  if current.kind == nnkEnumTy:
    return responseEnumSchema(current)
  typeSchema(current)

proc stringLiterals(node: NimNode): seq[string] {.compileTime.} =
  var values = node
  if values.kind in {nnkCall, nnkConv} and values.len == 2:
    values = values[1]
  if values.kind == nnkPrefix and values.len == 2 and eqIdent(values[0], "@"):
    values = values[1]
  if values.kind == nnkNilLit:
    return
  if values.kind != nnkBracket:
    error(
      "response field overrides must be a sequence literal, got " & values.repr,
      node,
    )
  for value in values:
    if value.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error("response field override names must be string literals", value)
    result.add(value.strVal)

macro openApiSchema*(model: typedesc): untyped =
  ## Produces an OpenAPI schema for a typed request or response model.
  let schema = typeSchema(model.getTypeImpl)
  result = newCall(ident("openApiSchemaJson"), newLit($schema))

macro openApiResponseSchema*(
    model: typedesc, ignoredFields, includedFields: untyped
): untyped =
  ## Produces a response schema honoring response-only field visibility rules.
  let schema = responseTypeSchema(
    model.getTypeImpl,
    stringLiterals(ignoredFields),
    stringLiterals(includedFields),
    true,
  )
  result = newCall(ident("openApiSchemaJson"), newLit($schema))

macro openApiQueryParameters*(model: typedesc): untyped =
  ## Produces OpenAPI parameter objects for fields extracted from the query.
  let implementation = objectType(model.getTypeImpl)
  if implementation.kind != nnkObjectTy:
    error("query route models must be object types", model)

  var parameters = newJArray()
  for field in jsonFields(implementation):
    var schema = typeSchema(field.fieldType)
    schema.applyValidationSchema(field.source)
    if field.fieldType.isOptionType() and schema.kind == JObject:
      schema.delete("nullable")
    parameters.add(
      %*{
        "name": field.jsonName,
        "in": "query",
        "required":
          field.defaultValue.kind == nnkEmpty and not field.fieldType.isOptionType() and
          not field.fieldType.isSequenceType(),
        "schema": schema,
      }
    )
  result = newCall(ident("openApiSchemaJson"), newLit($parameters))

proc openApiSchemaJson*(source: string): JsonNode =
  ## Parses schema JSON emitted by ``openApiSchema`` at compile time.
  parseJson(source)

proc addPathParameters(operation: var JsonNode) =
  var parameters =
    if operation.hasKey("parameters") and operation["parameters"].kind == JArray:
      operation["parameters"]
    else:
      newJArray()
  for segment in operation["x-fastnim-path"].getStr.split('/'):
    var spec: PathParamSpec
    if segment.parsePathParamSegment(spec):
      let schema =
        case spec.kind
        of PathParamKind.Int:
          %*{"type": "integer"}
        of PathParamKind.PositiveInt:
          %*{"type": "integer", "minimum": 1}
        of PathParamKind.Bool:
          %*{"type": "boolean"}
        of PathParamKind.Csv:
          %*{"type": "array", "items": {"type": "string"}}
        of PathParamKind.String:
          %*{"type": "string"}
      parameters.add(
        %*{
          "name": spec.name,
          "in": "path",
          "required": true,
          "schema": schema,
        }
      )
  if parameters.len > 0:
    operation["parameters"] = parameters
  operation.delete("x-fastnim-path")

proc openApiDocument*(
    settings: OpenApiSettings, operations: openArray[OpenApiOperation]
): JsonNode =
  ## Builds an OpenAPI 3.1 document from registered route operations.
  result = %*{
    "openapi": "3.1.0",
    "info": {"title": settings.title, "version": settings.version},
    "paths": newJObject(),
  }
  if settings.description.len > 0:
    result["info"]["description"] = newJString(settings.description)
  for registered in operations:
    let documentPath = registered.path.normalizedPath()
    var operation = newJObject()
    operation["x-fastnim-path"] = newJString(registered.path)
    if registered.route.summary.len > 0:
      operation["summary"] = newJString(registered.route.summary)
    if registered.route.description.len > 0:
      operation["description"] = newJString(registered.route.description)
    if registered.route.operationId.len > 0:
      operation["operationId"] = newJString(registered.route.operationId)
    if registered.route.tags.len > 0:
      operation["tags"] = newJArray()
      for tag in registered.route.tags:
        operation["tags"].add(newJString(tag))
    if registered.route.deprecated:
      operation["deprecated"] = newJBool(true)
    if registered.requestBody.kind != JNull:
      operation["requestBody"] = registered.requestBody
    if registered.parameters.kind != JNull:
      operation["parameters"] = registered.parameters
    operation["responses"] =
      if registered.responses.len > 0:
        registered.responses
      else:
        %*{"200": {"description": "Successful Response"}}
    operation.addPathParameters()
    if documentPath notin result["paths"]:
      result["paths"][documentPath] = newJObject()
    result["paths"][documentPath][registered.`method`] = operation

proc swaggerUiHtml*(schemaPath: string, title = "FastNim API docs"): string =
  ## Returns a small Swagger UI page backed by the public Swagger CDN.
  "<!doctype html><html><head><title>" & title &
    "</title><link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui.css\"></head>" &
    "<body><div id=\"swagger-ui\"></div><script src=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js\"></script>" &
    "<script>SwaggerUIBundle({url:'" & schemaPath &
    "',dom_id:'#swagger-ui'});</script></body></html>"
