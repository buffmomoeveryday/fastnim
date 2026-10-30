## Typed path-parameter parsing shared by routing, handlers, and OpenAPI.

import std/[options, strutils]

import ../orm/uuids

type
  PathParamKind* {.pure.} = enum
    ## Supported converters in ``{name:type}`` route segments.
    String
    Int
    PositiveInt
    Bool
    Csv
    Uuid

  PathParamSpec* = object ## Parsed name and converter for one path-parameter segment.
    name*: string ## Name exposed to the route handler.
    kind*: PathParamKind ## Converter used to match and decode the segment.

proc parsePathParamKind*(name: string): Option[PathParamKind] {.raises: [].} =
  ## Parses a path converter name.
  case name.toLowerAscii()
  of "string", "str":
    some(PathParamKind.String)
  of "int":
    some(PathParamKind.Int)
  of "positiveint", "positive_int", "positive-int", "positive", "posint":
    some(PathParamKind.PositiveInt)
  of "bool":
    some(PathParamKind.Bool)
  of "csv":
    some(PathParamKind.Csv)
  of "uuid":
    some(PathParamKind.Uuid)
  else:
    none(PathParamKind)

proc parsePathParamSegment*(segment: string, spec: var PathParamSpec): bool =
  ## Parses a complete ``{name}`` or ``{name:type}`` route segment.
  ##
  ## Raises ``ValueError`` when the segment looks like a parameter but has an
  ## empty name, an unknown converter, or more than one converter separator.
  if segment.len < 2 or segment[0] != '{' or segment[^1] != '}':
    return false
  let declaration = segment[1 ..^ 2]
  let separator = declaration.find(':')
  if separator < 0:
    if declaration.len == 0:
      raise newException(ValueError, "path parameter names cannot be empty")
    spec = PathParamSpec(name: declaration, kind: PathParamKind.String)
    return true
  if separator == 0:
    raise newException(ValueError, "path parameter names cannot be empty")
  if separator == declaration.high or declaration.find(':', separator + 1) >= 0:
    raise newException(ValueError, "path parameters must use {name:type}")
  let converterName = declaration[separator + 1 .. ^1]
  let kind = parsePathParamKind(converterName)
  if kind.isNone:
    raise newException(
      ValueError,
      "unsupported path parameter type '" & converterName &
        "'; expected string, int, positiveInt, bool, csv, or uuid",
    )
  spec = PathParamSpec(name: declaration[0 ..< separator], kind: kind.get())
  true

proc parsePathBool*(raw: string, value: var bool): bool {.raises: [].} =
  ## Parses the case-insensitive boolean words accepted in typed paths.
  case raw.toLowerAscii()
  of "y", "yes", "true", "1", "on":
    value = true
    true
  of "n", "no", "false", "0", "off":
    value = false
    true
  else:
    false

proc matchesPathParam*(kind: PathParamKind, raw: string): bool {.raises: [].} =
  ## Returns whether ``raw`` satisfies a path converter.
  case kind
  of PathParamKind.String, PathParamKind.Csv:
    raw.len > 0
  of PathParamKind.Int, PathParamKind.PositiveInt:
    try:
      let value = parseInt(raw)
      kind == PathParamKind.Int or value > 0
    except ValueError:
      false
  of PathParamKind.Bool:
    var value: bool
    parsePathBool(raw, value)
  of PathParamKind.Uuid:
    try:
      discard parseUUID(raw)
      true
    except ValueError:
      false

proc normalizedPath*(path: string): string =
  ## Removes converter suffixes from a route path for OpenAPI output.
  var parts = path.split('/')
  for part in parts.mitems:
    var spec: PathParamSpec
    if part.parsePathParamSegment(spec):
      part = "{" & spec.name & "}"
  parts.join("/")
