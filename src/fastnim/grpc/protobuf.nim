## Minimal protobuf wire codec used by FastNim's native gRPC transport.
##
## Object fields map to protobuf field numbers in declaration order. Applications
## with generated or specially encoded messages can overload ``encodeProtobuf``
## and ``decodeProtobuf`` for their own types.

type ProtobufError* = object of CatchableError ## Invalid protobuf wire data.

proc addVarint(output: var seq[byte], value: uint64) =
  var remaining = value
  while remaining >= 0x80:
    output.add(byte(remaining) or 0x80)
    remaining = remaining shr 7
  output.add(byte(remaining))

proc readVarint(data: openArray[byte], position: var int): uint64 =
  var shift = 0
  while shift < 70:
    if position >= data.len:
      raise newException(ProtobufError, "truncated protobuf varint")
    let current = data[position]
    inc position
    result = result or (uint64(current and 0x7f) shl shift)
    if (current and 0x80) == 0:
      return
    shift += 7
  raise newException(ProtobufError, "protobuf varint is too long")

proc addKey(output: var seq[byte], fieldNumber, wireType: int) =
  output.addVarint(uint64((fieldNumber shl 3) or wireType))

proc addFixed32(output: var seq[byte], value: uint32) =
  for shift in countup(0, 24, 8):
    output.add(byte(value shr shift))

proc addFixed64(output: var seq[byte], value: uint64) =
  for shift in countup(0, 56, 8):
    output.add(byte(value shr shift))

proc appendField(output: var seq[byte], fieldNumber: int, value: bool) =
  if value:
    output.addKey(fieldNumber, 0)
    output.addVarint(1)

proc appendField[T: SomeInteger | enum](
    output: var seq[byte], fieldNumber: int, value: T
) =
  if value != default(T):
    output.addKey(fieldNumber, 0)
    when T is SomeUnsignedInt:
      output.addVarint(uint64(value))
    else:
      output.addVarint(cast[uint64](int64(value)))

proc appendField(output: var seq[byte], fieldNumber: int, value: float32) =
  if value != 0:
    var bits: uint32
    copyMem(addr bits, unsafeAddr value, sizeof(bits))
    output.addKey(fieldNumber, 5)
    output.addFixed32(bits)

proc appendField(output: var seq[byte], fieldNumber: int, value: float64) =
  if value != 0:
    var bits: uint64
    copyMem(addr bits, unsafeAddr value, sizeof(bits))
    output.addKey(fieldNumber, 1)
    output.addFixed64(bits)

proc appendBytes(output: var seq[byte], fieldNumber: int, value: openArray[byte]) =
  if value.len > 0:
    output.addKey(fieldNumber, 2)
    output.addVarint(uint64(value.len))
    output.add(value)

proc appendField(output: var seq[byte], fieldNumber: int, value: string) =
  if value.len > 0:
    output.addKey(fieldNumber, 2)
    output.addVarint(uint64(value.len))
    for item in value:
      output.add(byte(item))

proc appendField(output: var seq[byte], fieldNumber: int, value: seq[byte]) =
  output.appendBytes(fieldNumber, value)

proc encodeProtobuf*[T: object](value: T): seq[byte]

proc appendField[T: object](output: var seq[byte], fieldNumber: int, value: T) =
  let nested = encodeProtobuf(value)
  if nested.len > 0:
    output.appendBytes(fieldNumber, nested)

proc appendField[T](output: var seq[byte], fieldNumber: int, value: seq[T]) =
  for item in value:
    output.appendField(fieldNumber, item)

proc encodeProtobuf*[T: object](value: T): seq[byte] =
  ## Encodes an object using protobuf field numbers in declaration order.
  ##
  ## Supported fields are booleans, integers, enums, floats, strings, bytes,
  ## nested objects, and repeated sequences of those values.
  var fieldNumber = 0
  for _, field in fieldPairs(value):
    inc fieldNumber
    result.appendField(fieldNumber, field)

proc requireBytes(data: openArray[byte], position, count: int) =
  if count < 0 or position < 0 or position + count > data.len:
    raise newException(ProtobufError, "truncated protobuf field")

proc readLength(data: openArray[byte], position: var int): int =
  let length = readVarint(data, position)
  if length > uint64(high(int)):
    raise newException(ProtobufError, "protobuf field is too large")
  result = int(length)
  data.requireBytes(position, result)

proc readFixed32(data: openArray[byte], position: var int): uint32 =
  data.requireBytes(position, 4)
  for shift in countup(0, 24, 8):
    result = result or (uint32(data[position]) shl shift)
    inc position

proc readFixed64(data: openArray[byte], position: var int): uint64 =
  data.requireBytes(position, 8)
  for shift in countup(0, 56, 8):
    result = result or (uint64(data[position]) shl shift)
    inc position

proc requireWire(actual, expected: int) =
  if actual != expected:
    raise newException(ProtobufError, "protobuf field has the wrong wire type")

proc decodeValue(
    field: var bool, wireType: int, data: openArray[byte], position: var int
) =
  wireType.requireWire(0)
  field = data.readVarint(position) != 0

proc decodeValue[T: SomeInteger | enum](
    field: var T, wireType: int, data: openArray[byte], position: var int
) =
  wireType.requireWire(0)
  let value = data.readVarint(position)
  when T is SomeSignedInt or T is enum:
    field = T(cast[int64](value))
  else:
    field = T(value)

proc decodeValue(
    field: var float32, wireType: int, data: openArray[byte], position: var int
) =
  wireType.requireWire(5)
  let bits = data.readFixed32(position)
  copyMem(addr field, unsafeAddr bits, sizeof(bits))

proc decodeValue(
    field: var float64, wireType: int, data: openArray[byte], position: var int
) =
  wireType.requireWire(1)
  let bits = data.readFixed64(position)
  copyMem(addr field, unsafeAddr bits, sizeof(bits))

proc decodeValue(
    field: var string, wireType: int, data: openArray[byte], position: var int
) =
  wireType.requireWire(2)
  let length = data.readLength(position)
  field = newString(length)
  for index in 0 ..< length:
    field[index] = char(data[position + index])
  position += length

proc decodeValue(
    field: var seq[byte], wireType: int, data: openArray[byte], position: var int
) =
  wireType.requireWire(2)
  let length = data.readLength(position)
  field = newSeq[byte](length)
  if length > 0:
    copyMem(addr field[0], unsafeAddr data[position], length)
  position += length

proc decodeProtobuf*[T: object](data: openArray[byte]): T

proc decodeValue[T: object](
    field: var T, wireType: int, data: openArray[byte], position: var int
) =
  wireType.requireWire(2)
  let length = data.readLength(position)
  if length == 0:
    field = default(T)
  else:
    field = decodeProtobuf[T](data.toOpenArray(position, position + length - 1))
  position += length

proc decodeValue[T](
    field: var seq[T], wireType: int, data: openArray[byte], position: var int
) =
  when T is SomeInteger or T is enum or T is bool or T is SomeFloat:
    if wireType == 2:
      let length = data.readLength(position)
      let limit = position + length
      while position < limit:
        var item: T
        when T is float32:
          item.decodeValue(5, data, position)
        elif T is float64:
          item.decodeValue(1, data, position)
        else:
          item.decodeValue(0, data, position)
        field.add(item)
      if position != limit:
        raise newException(ProtobufError, "invalid packed protobuf field")
      return
  var item: T
  item.decodeValue(wireType, data, position)
  field.add(item)

proc skipField(data: openArray[byte], wireType: int, position: var int) =
  case wireType
  of 0:
    discard data.readVarint(position)
  of 1:
    data.requireBytes(position, 8)
    position += 8
  of 2:
    position += data.readLength(position)
  of 5:
    data.requireBytes(position, 4)
    position += 4
  else:
    raise newException(ProtobufError, "unsupported protobuf wire type")

proc decodeProtobuf*[T: object](data: openArray[byte]): T =
  ## Decodes protobuf bytes into an object whose declaration order defines field numbers.
  var position = 0
  while position < data.len:
    let key = data.readVarint(position)
    let fieldNumber = int(key shr 3)
    let wireType = int(key and 0x07)
    if fieldNumber <= 0:
      raise newException(ProtobufError, "invalid protobuf field number")
    var matched = false
    var candidate = 0
    for _, field in fieldPairs(result):
      inc candidate
      if candidate == fieldNumber:
        field.decodeValue(wireType, data, position)
        matched = true
        break
    if not matched:
      data.skipField(wireType, position)

proc decodeProtobuf*[T: object](data: openArray[byte], messageType: typedesc[T]): T =
  ## Typedesc form used by typed gRPC route registration.
  when false:
    discard messageType
  decodeProtobuf[T](data)
