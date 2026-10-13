## Incremental bounded MQTT packet framing.

type
  MqttProtocolError* = object of CatchableError ## Malformed or unsupported MQTT input.

  MqttPacket* = object ## One decoded MQTT control packet frame.
    fixedHeader*: byte ## First fixed-header byte, including packet flags.
    body*: seq[byte] ## Variable header and payload bytes.

  MqttDecoder* = object ## Stateful decoder accepting arbitrarily fragmented input.
    buffer: seq[byte]
    maxPacketSize: int

proc initMqttDecoder*(maxPacketSize = 1024 * 1024): MqttDecoder =
  ## Creates a bounded incremental MQTT packet decoder.
  if maxPacketSize <= 0:
    raise newException(ValueError, "MQTT maximum packet size must be positive")
  MqttDecoder(buffer: @[], maxPacketSize: maxPacketSize)

proc encodeRemainingLength*(value: int): seq[byte] =
  ## Encodes an MQTT variable-byte integer.
  if value < 0 or value > 268_435_455:
    raise newException(ValueError, "MQTT remaining length is out of range")
  var remaining = value
  while true:
    var encoded = byte(remaining mod 128)
    remaining = remaining div 128
    if remaining > 0:
      encoded = encoded or 0x80
    result.add(encoded)
    if remaining == 0:
      break

proc frameLength(
    data: openArray[byte], headerLength, totalLength: var int
): bool =
  if data.len < 2:
    return false
  var multiplier = 1
  var remaining = 0
  var index = 1
  var count = 0
  while true:
    if index >= data.len:
      return false
    let current = int(data[index])
    remaining += (current and 0x7F) * multiplier
    inc index
    inc count
    if (current and 0x80) == 0:
      break
    if count == 4:
      raise newException(MqttProtocolError, "malformed MQTT remaining length")
    multiplier *= 128
  headerLength = index
  totalLength = index + remaining
  true

proc feed*(decoder: var MqttDecoder, data: openArray[byte]): seq[MqttPacket] =
  ## Adds bytes and returns every complete packet currently available.
  decoder.buffer.add(data)
  while decoder.buffer.len > 0:
    var headerLength, totalLength: int
    if not frameLength(decoder.buffer, headerLength, totalLength):
      break
    let bodyLength = totalLength - headerLength
    if bodyLength > decoder.maxPacketSize:
      raise newException(MqttProtocolError, "MQTT packet exceeds configured limit")
    if decoder.buffer.len < totalLength:
      break
    var body = newSeq[byte](bodyLength)
    if bodyLength > 0:
      copyMem(addr body[0], addr decoder.buffer[headerLength], bodyLength)
    result.add(MqttPacket(fixedHeader: decoder.buffer[0], body: body))
    if totalLength == decoder.buffer.len:
      decoder.buffer.setLen(0)
    else:
      decoder.buffer = decoder.buffer[totalLength..^1]
