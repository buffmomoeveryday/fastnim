## Internal JSON conversion that honors FastNim field metadata.

import std/[json, jsonutils, macros, options]

import fastnim/jsonfields

export jsonutils

proc renameJsonField(node: JsonNode, source, target: string) =
  if node.isNil or node.kind != JObject or source == target or source notin node:
    return
  if target in node:
    raise newException(
      ValueError,
      "JSON contains both '" & source & "' and its renamed field '" & target & "'",
    )
  node[target] = node[source]
  node.delete(source)

template effectiveJsonName(field: untyped, defaultName: static[string]): string =
  when field.hasCustomPragma(jsonName):
    const customName = field.getCustomPragmaVal(jsonName).name
    when customName.len == 0:
      {.error: "jsonName cannot be empty".}
    customName
  else:
    defaultName

proc transformJsonFields[T](node: JsonNode, value: T, encode: static[bool]) =
  when T is Option:
    if not node.isNil and node.kind != JNull:
      when encode:
        if value.isSome():
          transformJsonFields(node, value.get(), encode)
      else:
        type Item = typeof(value.get())
        var item: Item
        transformJsonFields(node, item, encode)
  elif T is ref:
    when encode:
      if not value.isNil:
        transformJsonFields(node, value[], encode)
    else:
      type Item = typeof(value[])
      var item: Item
      transformJsonFields(node, item, encode)
  elif T is object:
    for nimName, field in fieldPairs(value):
      const fieldName = effectiveJsonName(field, nimName)
      for otherNimName, otherField in fieldPairs(value):
        const otherFieldName = effectiveJsonName(otherField, otherNimName)
        when nimName != otherNimName and fieldName == otherFieldName:
          {.error: "duplicate JSON field name '" & fieldName & "'".}

      const sourceName = if encode: nimName else: fieldName
      const targetName = if encode: fieldName else: nimName
      const childName = if encode: fieldName else: nimName
      when not encode and field is Option:
        if not node.isNil and node.kind == JObject and sourceName notin node:
          node[targetName] = newJNull()
      renameJsonField(node, sourceName, targetName)
      if not node.isNil and node.kind == JObject and childName in node:
        transformJsonFields(node[childName], field, encode)
  elif T is seq or T is array:
    type Item = typeof(value[0])
    if not node.isNil and node.kind == JArray:
      for child in node.items:
        var item: Item
        transformJsonFields(child, item, encode)

template toJsonValue*[T](value: T): JsonNode =
  ## Encodes a framework value while applying ``jsonName`` recursively.
  block:
    var jsonResult = toJson(value)
    transformJsonFields(jsonResult, value, true)
    jsonResult

template jsonToValue*[T](node: JsonNode, model: typedesc[T]): T =
  ## Decodes a framework value while applying ``jsonName`` recursively.
  block:
    var normalized = node.copy()
    var value: T
    transformJsonFields(normalized, value, false)
    jsonTo(normalized, T)
