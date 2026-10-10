## OpenAPI document and Swagger UI helpers for FastNim applications.

import std/[json, macros, strutils]

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
    requestBody: newJNull(),
  )

proc typeSchema(node: NimNode): JsonNode {.compileTime.}

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
    if container == "Option":
      result = typeSchema(current[1])
      result["nullable"] = newJBool(true)
      return result
  if current.kind == nnkObjectTy:
    result = %*{"type": "object", "properties": newJObject(), "required": newJArray()}
    let fields = current[^1]
    for field in fields:
      if field.kind == nnkIdentDefs:
        let fieldType = field[^2]
        for index in 0 ..< field.len - 2:
          let fieldName = $field[index]
          result["properties"][fieldName] = typeSchema(fieldType)
          result["required"].add(newJString(fieldName))
    return result
  if current.kind == nnkEnumTy:
    result = %*{"type": "string", "enum": newJArray()}
    for item in current:
      if item.kind == nnkEnumFieldDef:
        result["enum"].add(newJString($item[0]))
      elif item.kind == nnkIdent:
        result["enum"].add(newJString($item))
    return result
  newJObject()

macro openApiSchema*(model: typedesc): untyped =
  ## Produces an OpenAPI schema for a typed request or response model.
  let schema = typeSchema(model.getTypeImpl)
  result = newCall(ident("openApiSchemaJson"), newLit($schema))

proc openApiSchemaJson*(source: string): JsonNode =
  ## Parses schema JSON emitted by ``openApiSchema`` at compile time.
  parseJson(source)

proc addPathParameters(operation: var JsonNode) =
  var parameters = newJArray()
  for segment in operation["x-fastnim-path"].getStr.split('/'):
    if segment.len > 2 and segment[0] == '{' and segment[^1] == '}':
      parameters.add(
        %*{
          "name": segment[1 .. ^2],
          "in": "path",
          "required": true,
          "schema": {"type": "string"},
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
    operation["responses"] =
      if registered.responses.len > 0:
        registered.responses
      else:
        %*{"200": {"description": "Successful Response"}}
    operation.addPathParameters()
    if registered.path notin result["paths"]:
      result["paths"][registered.path] = newJObject()
    result["paths"][registered.path][registered.`method`] = operation

proc swaggerUiHtml*(schemaPath: string, title = "FastNim API docs"): string =
  ## Returns a small Swagger UI page backed by the public Swagger CDN.
  "<!doctype html><html><head><title>" & title &
    "</title><link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui.css\"></head>" &
    "<body><div id=\"swagger-ui\"></div><script src=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js\"></script>" &
    "<script>SwaggerUIBundle({url:'" & schemaPath &
    "',dom_id:'#swagger-ui'});</script></body></html>"
