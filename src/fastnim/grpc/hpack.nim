## Pure Nim HPACK codec for the native HTTP/2 transport.

import std/tables

type
  HeaderField = object
    name: string
    value: string

  HpackDecoder* = object ## Stateful HPACK decoder scoped to one HTTP/2 connection.
    dynamic: seq[HeaderField]
    dynamicSize: int
    maxDynamicSize: int

  HpackEncoder* = object ## HPACK encoder scoped to one HTTP/2 connection.

const
  StaticTable = [
    (":authority", ""),
    (":method", "GET"),
    (":method", "POST"),
    (":path", "/"),
    (":path", "/index.html"),
    (":scheme", "http"),
    (":scheme", "https"),
    (":status", "200"),
    (":status", "204"),
    (":status", "206"),
    (":status", "304"),
    (":status", "400"),
    (":status", "404"),
    (":status", "500"),
    ("accept-charset", ""),
    ("accept-encoding", "gzip, deflate"),
    ("accept-language", ""),
    ("accept-ranges", ""),
    ("accept", ""),
    ("access-control-allow-origin", ""),
    ("age", ""),
    ("allow", ""),
    ("authorization", ""),
    ("cache-control", ""),
    ("content-disposition", ""),
    ("content-encoding", ""),
    ("content-language", ""),
    ("content-length", ""),
    ("content-location", ""),
    ("content-range", ""),
    ("content-type", ""),
    ("cookie", ""),
    ("date", ""),
    ("etag", ""),
    ("expect", ""),
    ("expires", ""),
    ("from", ""),
    ("host", ""),
    ("if-match", ""),
    ("if-modified-since", ""),
    ("if-none-match", ""),
    ("if-range", ""),
    ("if-unmodified-since", ""),
    ("last-modified", ""),
    ("link", ""),
    ("location", ""),
    ("max-forwards", ""),
    ("proxy-authenticate", ""),
    ("proxy-authorization", ""),
    ("range", ""),
    ("referer", ""),
    ("refresh", ""),
    ("retry-after", ""),
    ("server", ""),
    ("set-cookie", ""),
    ("strict-transport-security", ""),
    ("transfer-encoding", ""),
    ("user-agent", ""),
    ("vary", ""),
    ("via", ""),
    ("www-authenticate", ""),
  ]

  HuffmanCodes = [
    0x1ff8'u32, 0x7fffd8, 0xfffffe2, 0xfffffe3, 0xfffffe4, 0xfffffe5, 0xfffffe6,
    0xfffffe7, 0xfffffe8, 0xffffea, 0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd,
    0xfffffeb, 0xfffffec, 0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0, 0xffffff1,
    0xffffff2, 0x3ffffffe, 0xffffff3, 0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7,
    0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb, 0x14, 0x3f8, 0x3f9, 0xffa, 0x1ff9, 0x15,
    0xf8, 0x7fa, 0x3fa, 0x3fb, 0xf9, 0x7fb, 0xfa, 0x16, 0x17, 0x18, 0x0, 0x1, 0x2, 0x19,
    0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x5c, 0xfb, 0x7ffc, 0x20, 0xffb, 0x3fc, 0x1ffa,
    0x21, 0x5d, 0x5e, 0x5f, 0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0xfc, 0x73, 0xfd, 0x1ffb,
    0x7fff0, 0x1ffc, 0x3ffc, 0x22, 0x7ffd, 0x3, 0x23, 0x4, 0x24, 0x5, 0x25, 0x26, 0x27,
    0x6, 0x74, 0x75, 0x28, 0x29, 0x2a, 0x7, 0x2b, 0x76, 0x2c, 0x8, 0x9, 0x2d, 0x77,
    0x78, 0x79, 0x7a, 0x7b, 0x7ffe, 0x7fc, 0x3ffd, 0x1ffd, 0xffffffc, 0xfffe6, 0x3fffd2,
    0xfffe7, 0xfffe8, 0x3fffd3, 0x3fffd4, 0x3fffd5, 0x7fffd9, 0x3fffd6, 0x7fffda,
    0x7fffdb, 0x7fffdc, 0x7fffdd, 0x7fffde, 0xffffeb, 0x7fffdf, 0xffffec, 0xffffed,
    0x3fffd7, 0x7fffe0, 0xffffee, 0x7fffe1, 0x7fffe2, 0x7fffe3, 0x7fffe4, 0x1fffdc,
    0x3fffd8, 0x7fffe5, 0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef, 0x3fffda, 0x1fffdd,
    0xfffe9, 0x3fffdb, 0x3fffdc, 0x7fffe8, 0x7fffe9, 0x1fffde, 0x7fffea, 0x3fffdd,
    0x3fffde, 0xfffff0, 0x1fffdf, 0x3fffdf, 0x7fffeb, 0x7fffec, 0x1fffe0, 0x1fffe1,
    0x3fffe0, 0x1fffe2, 0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef, 0xfffea, 0x3fffe2,
    0x3fffe3, 0x3fffe4, 0x7ffff0, 0x3fffe5, 0x3fffe6, 0x7ffff1, 0x3ffffe0, 0x3ffffe1,
    0xfffeb, 0x7fff1, 0x3fffe7, 0x7ffff2, 0x3fffe8, 0x1ffffec, 0x3ffffe2, 0x3ffffe3,
    0x3ffffe4, 0x7ffffde, 0x7ffffdf, 0x3ffffe5, 0xfffff1, 0x1ffffed, 0x7fff2, 0x1fffe3,
    0x3ffffe6, 0x7ffffe0, 0x7ffffe1, 0x3ffffe7, 0x7ffffe2, 0xfffff2, 0x1fffe4, 0x1fffe5,
    0x3ffffe8, 0x3ffffe9, 0xffffffd, 0x7ffffe3, 0x7ffffe4, 0x7ffffe5, 0xfffec, 0xfffff3,
    0xfffed, 0x1fffe6, 0x3fffe9, 0x1fffe7, 0x1fffe8, 0x7ffff3, 0x3fffea, 0x3fffeb,
    0x1ffffee, 0x1ffffef, 0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4, 0x3ffffeb, 0x7ffffe6,
    0x3ffffec, 0x3ffffed, 0x7ffffe7, 0x7ffffe8, 0x7ffffe9, 0x7ffffea, 0x7ffffeb,
    0xffffffe, 0x7ffffec, 0x7ffffed, 0x7ffffee, 0x7ffffef, 0x7fffff0, 0x3ffffee,
  ]
  HuffmanLengths = [
    13'u8, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28, 28, 28, 28, 28,
    28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28, 6, 10, 10, 12, 13, 6, 8, 11, 10, 10,
    8, 11, 8, 6, 6, 6, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10, 13, 6, 7, 7,
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14,
    6, 15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5, 6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7,
    15, 11, 14, 13, 28, 20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24, 22, 21, 20, 22, 22,
    23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23, 21, 21, 22, 21, 23, 22, 23, 23, 20, 22,
    22, 22, 23, 22, 22, 23, 26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24,
    25, 19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27, 20, 24, 20, 21,
    22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23, 26, 27, 26, 26, 27, 27, 27, 27, 27,
    28, 27, 27, 27, 27, 27, 26,
  ]

proc initHpackDecoder*(): HpackDecoder =
  ## Creates a bounded HPACK decoder with the RFC default table size.
  HpackDecoder(dynamic: @[], maxDynamicSize: 4096)

proc initHpackEncoder*(): HpackEncoder =
  ## Creates a pure Nim HPACK encoder.
  HpackEncoder()

proc close*(decoder: var HpackDecoder) =
  ## Clears decoder-owned dynamic table state.
  decoder.dynamic.setLen(0)
  decoder.dynamicSize = 0

proc close*(encoder: var HpackEncoder) =
  ## Releases encoder state. The pure encoder owns no resources.
  discard encoder

proc readInteger(data: openArray[byte], position: var int, prefixBits: int): int =
  if position >= data.len:
    raise newException(ValueError, "truncated HPACK integer")
  let prefix = (1 shl prefixBits) - 1
  result = int(data[position]) and prefix
  inc position
  if result < prefix:
    return
  var shift = 0
  while true:
    if position >= data.len or shift > 28:
      raise newException(ValueError, "invalid HPACK integer")
    let current = int(data[position])
    inc position
    result += (current and 0x7f) shl shift
    if (current and 0x80) == 0:
      return
    shift += 7

proc decodeHuffman(data: openArray[byte]): string =
  var code = 0'u32
  var length = 0
  for current in data:
    for shift in countdown(7, 0):
      code = (code shl 1) or uint32((current shr shift) and 1)
      inc length
      var found = false
      for symbol in 0 ..< HuffmanCodes.len:
        if int(HuffmanLengths[symbol]) == length and HuffmanCodes[symbol] == code:
          if symbol == 256:
            raise newException(ValueError, "HPACK Huffman EOS is not data")
          result.add(char(symbol))
          code = 0
          length = 0
          found = true
          break
      if not found and length > 30:
        raise newException(ValueError, "invalid HPACK Huffman code")
  if length > 7 or (length > 0 and code != uint32((1 shl length) - 1)):
    raise newException(ValueError, "invalid HPACK Huffman padding")

proc readString(data: openArray[byte], position: var int): string =
  if position >= data.len:
    raise newException(ValueError, "truncated HPACK string")
  let huffman = (data[position] and 0x80) != 0
  let length = data.readInteger(position, 7)
  if length < 0 or position + length > data.len:
    raise newException(ValueError, "truncated HPACK string")
  if huffman:
    if length > 0:
      result = decodeHuffman(data.toOpenArray(position, position + length - 1))
  else:
    result = newString(length)
    for index in 0 ..< length:
      result[index] = char(data[position + index])
  position += length

proc fieldAt(decoder: HpackDecoder, index: int): HeaderField =
  if index <= 0:
    raise newException(ValueError, "invalid HPACK table index")
  if index <= StaticTable.len:
    return
      HeaderField(name: StaticTable[index - 1][0], value: StaticTable[index - 1][1])
  let dynamicIndex = index - StaticTable.len - 1
  if dynamicIndex >= decoder.dynamic.len:
    raise newException(ValueError, "invalid HPACK dynamic table index")
  decoder.dynamic[dynamicIndex]

proc evict(decoder: var HpackDecoder) =
  while decoder.dynamicSize > decoder.maxDynamicSize and decoder.dynamic.len > 0:
    let oldest = decoder.dynamic[^1]
    decoder.dynamicSize -= oldest.name.len + oldest.value.len + 32
    decoder.dynamic.setLen(decoder.dynamic.len - 1)

proc add(decoder: var HpackDecoder, field: HeaderField) =
  let size = field.name.len + field.value.len + 32
  if size > decoder.maxDynamicSize:
    decoder.dynamic.setLen(0)
    decoder.dynamicSize = 0
  else:
    decoder.dynamic.insert(field, 0)
    decoder.dynamicSize += size
    decoder.evict()

proc readLiteral(
    decoder: var HpackDecoder,
    data: openArray[byte],
    position: var int,
    prefixBits: int,
    indexing: bool,
): HeaderField =
  let nameIndex = data.readInteger(position, prefixBits)
  result.name =
    if nameIndex == 0:
      data.readString(position)
    else:
      decoder.fieldAt(nameIndex).name
  result.value = data.readString(position)
  if result.name.len == 0:
    raise newException(ValueError, "empty HPACK header name")
  if indexing:
    decoder.add(result)

proc decode*(decoder: var HpackDecoder, data: seq[byte]): Table[string, string] =
  ## Decodes one complete HPACK header block, including Huffman strings.
  result = initTable[string, string]()
  var position = 0
  var sawField = false
  while position < data.len:
    let first = data[position]
    var field: HeaderField
    if (first and 0x80) != 0:
      field = decoder.fieldAt(data.readInteger(position, 7))
    elif (first and 0xc0) == 0x40:
      field = decoder.readLiteral(data, position, 6, indexing = true)
    elif (first and 0xe0) == 0x20:
      if sawField:
        raise newException(ValueError, "late HPACK table size update")
      let size = data.readInteger(position, 5)
      if size > 4096:
        raise newException(ValueError, "HPACK table size exceeds server limit")
      decoder.maxDynamicSize = size
      decoder.evict()
      continue
    else:
      field = decoder.readLiteral(data, position, 4, indexing = false)
    sawField = true
    result[field.name] = field.value

proc addInteger(output: var seq[byte], prefixBits, value: int, firstBits: byte) =
  let prefix = (1 shl prefixBits) - 1
  if value < prefix:
    output.add(firstBits or byte(value))
  else:
    output.add(firstBits or byte(prefix))
    var remaining = value - prefix
    while remaining >= 128:
      output.add(byte(remaining and 0x7f) or 0x80)
      remaining = remaining shr 7
    output.add(byte(remaining))

proc addString(output: var seq[byte], value: string) =
  output.addInteger(7, value.len, 0)
  for current in value:
    output.add(byte(current))

proc findExact(name, value: string): int =
  for index, field in StaticTable:
    if field[0] == name and field[1] == value:
      return index + 1

proc findName(name: string): int =
  for index, field in StaticTable:
    if field[0] == name:
      return index + 1

proc encode*(encoder: HpackEncoder, fields: openArray[(string, string)]): seq[byte] =
  ## Encodes headers without dynamic indexing or external libraries.
  discard encoder
  for field in fields:
    let exact = findExact(field[0], field[1])
    if exact > 0:
      result.addInteger(7, exact, 0x80)
    else:
      let nameIndex = findName(field[0])
      result.addInteger(4, nameIndex, 0)
      if nameIndex == 0:
        result.addString(field[0])
      result.addString(field[1])
