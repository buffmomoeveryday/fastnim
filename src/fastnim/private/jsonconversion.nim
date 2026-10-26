## JSON conversion for FastNim models.
##
## jsony encodes and decodes values. Field names honor ``jsonName``,
## responses honor ``jsonRespIgnore``, and object bodies reject missing,
## unexpected, and ambiguous fields.

import std/[json, macros, options, sets, tables, typetraits]

import jsony

import ../jsonfields

const NoJsonFieldOverrides: array[0, string] = []

proc isNamedTuple(T: typedesc): bool {.magic: "TypeTrait".}

proc invalidJson(message: string) {.noinline.} =
  raise newException(ValueError, message)

proc isJsonIntToken(text: string): bool =
  if text.len == 0:
    return false
  var start = 0
  if text[0] in {'+', '-'}:
    if text.len == 1:
      return false
    start = 1
  for index in start ..< text.len:
    if text[index] notin {'0' .. '9'}:
      return false
  true

proc renameJsonField(node: JsonNode, source, target: string) =
  if node.isNil or node.kind != JObject or source == target or source notin node:
    return
  if target in node:
    invalidJson(
      "JSON contains both '" & source & "' and its renamed field '" & target & "'"
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

proc fieldSelected(fields: openArray[string], name: string): bool =
  for field in fields:
    if field == name:
      return true

template guardJsonNames(value: untyped) =
  for nimName, field in fieldPairs(value):
    const fieldName = effectiveJsonName(field, nimName)
    for otherNimName, otherField in fieldPairs(value):
      const otherFieldName = effectiveJsonName(otherField, otherNimName)
      when nimName != otherNimName and fieldName == otherFieldName:
        {.error: "duplicate JSON field name '" & fieldName & "'".}

proc renameKeys[T](node: JsonNode, value: T) =
  guardJsonNames(value)
  for nimName, field in fieldPairs(value):
    const fieldName = effectiveJsonName(field, nimName)
    renameJsonField(node, fieldName, nimName)

proc requireFields[T](node: JsonNode, value: T) =
  var present = 0
  for nimName, field in fieldPairs(value):
    if nimName in node:
      inc present
    else:
      when not (field is Option):
        invalidJson("missing JSON field '" & nimName & "'")
  if node.len != present:
    invalidJson("unexpected JSON field")

proc concreteObject(node: NimNode): NimNode {.compileTime.} =
  var current = node
  for _ in 0 .. 8:
    if current.kind == nnkObjectTy:
      return current
    if current.kind in {nnkSym, nnkIdent}:
      current = current.getTypeImpl()
    elif current.kind in {nnkRefTy, nnkPtrTy, nnkVarTy, nnkDistinctTy} and
        current.len > 0:
      current = current[0].getTypeImpl()
    elif current.kind == nnkBracketExpr and current.len > 1:
      current = current[^1].getTypeImpl()
    else:
      break
  newEmptyNode()

proc discriminatorDef(record: NimNode): NimNode {.compileTime.} =
  if record.kind == nnkRecCase and record.len > 0 and record[0].kind == nnkIdentDefs and
      record[0].len > 1:
    return record[0]
  for child in record:
    let found = discriminatorDef(child)
    if found.kind != nnkEmpty:
      return found
  newEmptyNode()

proc nodeText(node: NimNode): string {.compileTime.} =
  if node.kind == nnkPostfix and node.len == 2:
    nodeText(node[1])
  elif node.kind in {nnkIdent, nnkSym, nnkAccQuoted}:
    $node
  else:
    node.strVal

macro isVariant(value: typed): untyped =
  let obj = concreteObject(value.getTypeImpl())
  newLit(obj.kind == nnkObjectTy and discriminatorDef(obj[^1]).kind != nnkEmpty)

macro variantDiscriminator(value: typed): untyped =
  let definition = discriminatorDef(concreteObject(value.getTypeImpl())[^1])
  if definition.kind == nnkEmpty:
    error("JSON object variant is missing a discriminator", value)
  newLit(nodeText(definition[0]))

macro discriminatorType(value: typed): untyped =
  let definition = discriminatorDef(concreteObject(value.getTypeImpl())[^1])
  if definition.kind == nnkEmpty:
    error("JSON object variant is missing a discriminator", value)
  definition[1]

macro initVariant(value: typed, discriminator: typed): untyped =
  let obj = concreteObject(value.getTypeImpl())
  let field = discriminatorDef(obj[^1])[0]
  let typ = value.getTypeInst()
  quote:
    `value` = `typ`(`field`: `discriminator`)

macro genericArg(sample: typed, position: static int): untyped =
  var inst = sample.getTypeInst()
  if inst.kind == nnkSym:
    inst = inst.getTypeImpl()
  if inst.kind != nnkBracketExpr or inst.len <= position:
    error("JSON conversion expected a generic collection", sample)
  inst[position]

proc readJson[T](node: JsonNode, value: var T)

proc readFields[T](node: JsonNode, value: var T) =
  renameKeys(node, value)
  requireFields(node, value)
  when T is object and isVariant(value):
    const discriminatorName = variantDiscriminator(value)
  else:
    const discriminatorName = ""
  for nimName, field in fieldPairs(value):
    # The active branch is chosen before this loop, and Nim does not allow
    # assigning a case object's discriminator again.
    when discriminatorName.len > 0 and nimName == discriminatorName:
      discard
    else:
      if nimName in node:
        readJson(node[nimName], field)
      else:
        when field is Option:
          type Item = typeof(field.get())
          field = none(Item)

proc readCollection[T](node: JsonNode, value: var T) =
  if node.isNil or node.kind != JArray:
    invalidJson("JSON array expected")
  type Item = genericArg(value, 1)
  when T is HashSet:
    value = initHashSet[Item]()
  elif T is OrderedSet:
    value = initOrderedSet[Item]()
  else:
    value = default(T)
  for child in node.items:
    var item: Item
    readJson(child, item)
    value.incl(item)

proc readTable[T](node: JsonNode, value: var T) =
  if node.isNil or node.kind == JNull:
    when T is ref:
      value = nil
      return
    invalidJson("JSON object expected")
  if node.kind != JObject:
    invalidJson("JSON object expected")
  type
    Key = genericArg(value, 1)
    Item = genericArg(value, 2)

  when T is TableRef:
    value = newTable[Key, Item]()
  elif T is OrderedTableRef:
    value = newOrderedTable[Key, Item]()
  else:
    value = default(T)
  for key, child in node.pairs:
    var item: Item
    readJson(child, item)
    when Key is string:
      value[key] = item
    else:
      value[jsony.fromJson(key, Key)] = item

proc readObject[T](node: JsonNode, value: var T) =
  if node.isNil or node.kind != JObject:
    invalidJson("JSON object expected")
  when T is object and isVariant(value):
    var scratch: T
    renameKeys(node, scratch)
    const discriminatorName = variantDiscriminator(scratch)
    if discriminatorName notin node:
      invalidJson("missing JSON field '" & discriminatorName & "'")
    var discriminator: discriminatorType(scratch)
    readJson(node[discriminatorName], discriminator)
    initVariant(value, discriminator)
  readFields(node, value)

proc readJson[T](node: JsonNode, value: var T) =
  when T is JsonNode:
    value = node
  elif T is Option:
    if node.isNil or node.kind == JNull:
      type Item = typeof(value.get())
      value = none(Item)
    else:
      type Item = typeof(value.get())
      var item: Item
      readJson(node, item)
      value = some(item)
  elif T is distinct:
    var base: typeof(distinctBase(value))
    readJson(node, base)
    value = cast[T](base)
  elif T is Table or T is OrderedTable or T is TableRef or T is OrderedTableRef:
    readTable(node, value)
  elif T is HashSet or T is OrderedSet or T is set:
    readCollection(node, value)
  elif T is ref:
    if node.isNil or node.kind == JNull:
      value = nil
    else:
      when T is ref object and isVariant(value):
        if node.kind != JObject:
          invalidJson("JSON object expected")
        var scratch: typeof(value[])
        renameKeys(node, scratch)
        const discriminatorName = variantDiscriminator(scratch)
        if discriminatorName notin node:
          invalidJson("missing JSON field '" & discriminatorName & "'")
        var discriminator: discriminatorType(scratch)
        readJson(node[discriminatorName], discriminator)
        initVariant(value, discriminator)
        readFields(node, value[])
      else:
        new(value)
        readJson(node, value[])
  elif T is seq:
    if node.isNil or node.kind != JArray:
      invalidJson("JSON array expected")
    value.setLen(node.len)
    for index in 0 ..< node.len:
      readJson(node[index], value[index])
  elif T is array:
    if node.isNil or node.kind != JArray or node.len != value.len:
      invalidJson("JSON array has the wrong length")
    for index in 0 ..< value.len:
      readJson(node[index], value[index])
  elif T is tuple:
    when isNamedTuple(T):
      readObject(node, value)
    else:
      if node.isNil or node.kind != JArray:
        invalidJson("JSON array expected")
      var index = 0
      for field in fields(value):
        if index >= node.len:
          invalidJson("JSON array has the wrong length")
        readJson(node[index], field)
        inc index
      if index != node.len:
        invalidJson("JSON array has the wrong length")
  elif T is object:
    readObject(node, value)
  elif T is SomeFloat:
    if node.isNil:
      invalidJson("JSON number expected")
    elif node.kind == JString:
      case node.str
      of "nan":
        let special = NaN
        value = T(special)
      of "inf":
        let special = Inf
        value = T(special)
      of "-inf":
        let special = -Inf
        value = T(special)
      else:
        invalidJson("JSON number expected")
    else:
      value = jsony.fromJson($node, T)
  elif T is SomeInteger:
    if node.isNil:
      invalidJson("JSON number expected")
    elif node.kind == JString:
      if not isJsonIntToken(node.str):
        invalidJson("JSON number expected")
      value = jsony.fromJson(node.str, T)
    else:
      value = jsony.fromJson($node, T)
  else:
    if node.isNil:
      invalidJson("JSON value expected")
    value = jsony.fromJson($node, T)

proc dumpJsonKey[K](output: var string, key: K) =
  when K is string:
    jsony.dumpHook(output, key)
  else:
    jsony.dumpHook(output, $key)

proc dumpJsonInner[T](
    output: var string,
    value: T,
    ignoredFields, includedFields: openArray[string],
    root: static[bool],
) {.raises: [CatchableError].} =
  mixin toJsonHook
  when compiles(toJsonHook(value)):
    when compiles(value.isNil):
      if value.isNil:
        output.add "null"
      else:
        output.add $toJsonHook(value)
    else:
      output.add $toJsonHook(value)
  elif T is JsonNode:
    if value.isNil:
      output.add "null"
    else:
      output.add $value
  elif T is enum:
    jsony.dumpHook(output, ord(value))
  elif T is Option:
    if value.isNone:
      output.add "null"
    else:
      dumpJsonInner(
        output, value.get(), NoJsonFieldOverrides, NoJsonFieldOverrides, false
      )
  elif T is distinct:
    dumpJsonInner(output, distinctBase(value), ignoredFields, includedFields, root)
  elif T is Table or T is OrderedTable or T is TableRef or T is OrderedTableRef:
    when compiles(value.isNil):
      if value.isNil:
        output.add "null"
      else:
        dumpJsonInner(output, value[], ignoredFields, includedFields, root)
    else:
      output.add '{'
      var written = 0
      for key, item in value.pairs:
        if written > 0:
          output.add ','
        dumpJsonKey(output, key)
        output.add ':'
        dumpJsonInner(output, item, NoJsonFieldOverrides, NoJsonFieldOverrides, false)
        inc written
      output.add '}'
  elif T is HashSet:
    dumpHashSet(output, value)
  elif T is OrderedSet:
    dumpOrderedSet(output, value)
  elif T is set:
    output.add '['
    var written = 0
    for item in value:
      if written > 0:
        output.add ','
      dumpJsonInner(output, item, NoJsonFieldOverrides, NoJsonFieldOverrides, false)
      inc written
    output.add ']'
  elif T is ref:
    if value.isNil:
      output.add "null"
    else:
      dumpJsonInner(output, value[], NoJsonFieldOverrides, NoJsonFieldOverrides, false)
  elif T is seq or T is array:
    output.add '['
    var written = 0
    for item in value:
      if written > 0:
        output.add ','
      dumpJsonInner(output, item, NoJsonFieldOverrides, NoJsonFieldOverrides, false)
      inc written
    output.add ']'
  elif T is tuple:
    when isNamedTuple(T):
      guardJsonNames(value)
      output.add '{'
      var written = 0
      for nimName, field in fieldPairs(value):
        const fieldName = effectiveJsonName(field, nimName)
        if written > 0:
          output.add ','
        jsony.dumpHook(output, fieldName)
        output.add ':'
        dumpJsonInner(output, field, NoJsonFieldOverrides, NoJsonFieldOverrides, false)
        inc written
      output.add '}'
    else:
      output.add '['
      var written = 0
      for field in fields(value):
        if written > 0:
          output.add ','
        dumpJsonInner(output, field, NoJsonFieldOverrides, NoJsonFieldOverrides, false)
        inc written
      output.add ']'
  elif T is object:
    guardJsonNames(value)
    output.add '{'
    var written = 0
    for nimName, field in fieldPairs(value):
      const fieldName = effectiveJsonName(field, nimName)
      const ignoredByDefault = field.hasCustomPragma(jsonRespIgnore)
      # A nested value cannot bring a jsonRespIgnore field back, so the
      # serializer for that field is not generated. Model bookkeeping such as
      # the loaded-column set stays out of response code.
      when not (ignoredByDefault and not root):
        let explicitlyIgnored =
          when root:
            ignoredFields.fieldSelected(fieldName)
          else:
            false
        let explicitlyIncluded =
          when root:
            includedFields.fieldSelected(fieldName)
          else:
            false
        if not (explicitlyIgnored or (ignoredByDefault and not explicitlyIncluded)):
          if written > 0:
            output.add ','
          jsony.dumpHook(output, fieldName)
          output.add ':'
          dumpJsonInner(
            output, field, NoJsonFieldOverrides, NoJsonFieldOverrides, false
          )
          inc written
    output.add '}'
  elif T is SomeFloat:
    if value != value or value == Inf or value == -Inf:
      output.add $(%value)
    else:
      jsony.dumpHook(output, value)
  elif T is cstring:
    if value.isNil:
      output.add "null"
    else:
      jsony.dumpHook(output, $value)
  else:
    jsony.dumpHook(output, value)

proc dumpHashSet[A](output: var string, value: HashSet[A]) =
  ## HashSet's iterator is not visible inside `dumpJsonInner`'s generic branch.
  output.add '['
  var written = 0
  for item in value:
    if written > 0:
      output.add ','
    dumpJsonInner(output, item, NoJsonFieldOverrides, NoJsonFieldOverrides, false)
    inc written
  output.add ']'

proc dumpOrderedSet[A](output: var string, value: OrderedSet[A]) =
  output.add '['
  var written = 0
  for item in value:
    if written > 0:
      output.add ','
    dumpJsonInner(output, item, NoJsonFieldOverrides, NoJsonFieldOverrides, false)
    inc written
  output.add ']'

proc toJsonValue*[T](
    value: T, ignoredFields, includedFields: openArray[string]
): JsonNode {.raises: [CatchableError].} =
  ## Encodes a value with root-level response field overrides.
  var encoded = ""
  dumpJsonInner(encoded, value, ignoredFields, includedFields, true)
  parseJson(encoded)

template toJsonValue*[T](value: T): JsonNode =
  ## Encodes a framework value while applying ``jsonName`` recursively.
  toJsonValue(value, NoJsonFieldOverrides, NoJsonFieldOverrides)

proc jsonToValue*[T](node: JsonNode, model: typedesc[T]): T =
  ## Decodes a framework value while applying ``jsonName`` recursively.
  var normalized = node.copy()
  readJson(normalized, result)
