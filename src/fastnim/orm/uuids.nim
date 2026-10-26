## Minimal RFC 4122 UUID type used by `UUIDField`.

import std/[sysrand, strutils, hashes]

type
  UUID* = object
    bytes*: array[16, uint8]

proc genUUID*(): UUID {.raises: [OSError].} =
  ## Generates a random (version 4) UUID.
  if not urandom(result.bytes):
    raise newException(OSError, "fastorm: unable to read random bytes for UUID")
  result.bytes[6] = (result.bytes[6] and 0x0F'u8) or 0x40'u8
  result.bytes[8] = (result.bytes[8] and 0x3F'u8) or 0x80'u8

proc isZero*(u: UUID): bool =
  for b in u.bytes:
    if b != 0: return false
  true

proc `$`*(u: UUID): string =
  result = newStringOfCap(36)
  for i, b in u.bytes:
    if i in [4, 6, 8, 10]: result.add '-'
    result.add toHex(b.int, 2).toLowerAscii

proc parseUUID*(s: string): UUID {.raises: [ValueError].} =
  let hex = s.replace("-", "")
  if hex.len != 32 or s.len notin [32, 36]:
    raise newException(ValueError, "invalid UUID: " & s)
  for i in 0 ..< 16:
    result.bytes[i] = uint8(parseHexInt(hex[i * 2 .. i * 2 + 1]))

proc hash*(u: UUID): Hash = hash(u.bytes)
