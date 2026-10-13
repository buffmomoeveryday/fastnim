## Credential extraction and verification for the FastNim auth plugin.
##
## Each scheme has a small extractor (reading the ``Request``) and a verifier
## (checking against secrets). Extractors never raise; verifiers raise
## ``ValueError`` with a safe message on rejection. Secrets are always
## compared with ``secureCompare`` so mismatches take the same time no matter
## where they differ.
##
## JWT support covers HS256 (shared secret) only. RS256/ES256 need asymmetric
## cryptography and JWK fetching, which is deliberately out of scope.

import std/[base64, json, strutils, tables, times]

import nimcrypto/[hmac, sha2]

import fastnim/[context/http, params/extract]

type
  AuthScheme* {.pure.} = enum
    ## Credential mechanism accepted by the auth plugin.
    Bearer = "bearer" ## Opaque token in ``Authorization: Bearer``.
    Basic = "basic" ## Username and password in ``Authorization: Basic``.
    ApiKey = "apikey" ## Opaque key in a header or query parameter.
    Jwt = "jwt" ## Self-contained HS256 token in ``Authorization: Bearer``.
    Session = "session" ## Opaque id in a cookie, backed by ``SessionStore``.

  AuthIdentity* = ref object of RootObj
    ## Verified caller identity handed to route handlers.
    subject*: string ## Stable identifier (user, service, or session owner).
    scheme*: AuthScheme ## Mechanism that produced this identity.
    claims*: JsonNode ## JWT payload or extras; empty object otherwise.

proc secureCompare*(a, b: string): bool {.inline, raises: [].} =
  ## Compares two strings in constant time. Lengths are compared openly;
  ## every byte is always visited so mismatches cost the same anywhere.
  if a.len != b.len:
    return false
  var diff = 0
  for index in 0 ..< a.len:
    diff = diff or (ord(a[index]) xor ord(b[index]))
  diff == 0

proc secureCompareBytes*(a, b: openArray[byte]): bool {.inline, raises: [].} =
  ## Compares two byte buffers in constant time. Used for HMAC digests.
  if a.len != b.len:
    return false
  var diff = 0
  for index in 0 ..< a.len:
    diff = diff or (int(a[index]) xor int(b[index]))
  diff == 0

proc bearerToken*(request: Request): string {.inline, raises: [].} =
  ## Returns the ``Authorization: Bearer`` token, or "" when absent/malformed.
  let header = request.header("authorization")
  if header.len > 7 and header[0 .. 6].cmpIgnoreCase("bearer ") == 0:
    result = header[7 ..^ 1].strip()

proc basicCredentials*(
    request: Request
): tuple[user, password: string, ok: bool] {.raises: [].} =
  ## Decodes ``Authorization: Basic`` into its ``user:password`` parts.
  ##
  ## Returns ``ok == false`` (instead of raising) when the header is absent or
  ## malformed, so callers can fall through to the next scheme or a 401.
  let header = request.header("authorization")
  if header.len <= 6 or header[0 .. 5].cmpIgnoreCase("basic ") != 0:
    return ("", "", false)
  let decoded =
    try:
      decode(header[6 ..^ 1].strip())
    except CatchableError:
      return ("", "", false)
  let separator = decoded.find(':')
  if separator <= 0:
    return ("", "", false)
  (decoded[0 ..< separator], decoded[separator + 1 ..^ 1], true)

proc apiKey*(
    request: Request, header = "x-api-key", queryParamName = ""
): string {.inline, raises: [].} =
  ## Returns an API key from ``header``, or from ``?queryParamName=`` when set.
  ##
  ## The header wins when both are present. Pass an empty ``queryParamName``
  ## (the default) to accept keys from the header only; keys in URLs leak
  ## into logs and browser history.
  result = request.header(header).strip()
  if result.len == 0 and queryParamName.len > 0:
    result = request.queryParam(queryParamName).strip()

proc matchStaticSecret*(candidate, expected: string): bool {.inline, raises: [].} =
  ## Constant-time comparison of one presented secret against one stored one.
  secureCompare(candidate, expected)

proc lookupSubject*(
    credential: string, table: Table[string, string]
): string {.raises: [].} =
  ## Maps a presented credential to its subject without early exit.
  ##
  ## Every entry is visited with ``secureCompare`` so unknown and wrong
  ## credentials cost the same. Returns "" when nothing matches.
  result = ""
  var found = false
  for stored, subject in table:
    if secureCompare(credential, stored):
      found = true
      result = subject
  if not found:
    result = ""

proc base64UrlEncode*(data: string): string {.raises: [ValueError].} =
  ## Encodes ``data`` as unpadded base64url, as used by JWT segments.
  try:
    result = encode(data, safe = true)
  except CatchableError:
    raise newException(ValueError, "cannot encode data as base64url")
  while result.len > 0 and result[^1] == '=':
    result.setLen(result.len - 1)

proc base64UrlDecode*(data: string): string {.raises: [ValueError].} =
  ## Decodes an unpadded base64url segment. Raises ``ValueError`` when invalid.
  var padded = data.strip()
  if padded.len == 0:
    raise newException(ValueError, "empty base64url segment")
  for ch in padded:
    if ch notin {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '_'}:
      raise newException(ValueError, "invalid base64url segment")
  let remainder = padded.len mod 4
  if remainder == 1:
    raise newException(ValueError, "invalid base64url segment")
  for _ in 0 ..< ((4 - remainder) mod 4):
    padded.add('=')
  try:
    result = decode(padded)
  except CatchableError:
    raise newException(ValueError, "invalid base64url segment")

proc issueJwtHs256*(
    subject: string,
    secret: string,
    ttlSeconds = 3600,
    extra = newJObject(),
    issuer = "",
): string {.raises: [ValueError].} =
  ## Issues a signed HS256 JWT for ``subject`` valid for ``ttlSeconds``.
  ##
  ## ``extra`` claims are merged into the payload (``sub``/``iat``/``exp``
  ## always win). Keep ``ttlSeconds`` short in production and rotate secrets;
  ## never commit real secrets next to this call.
  if subject.len == 0:
    raise newException(ValueError, "JWT subject cannot be empty")
  if secret.len == 0:
    raise newException(ValueError, "JWT secret cannot be empty")
  if ttlSeconds <= 0:
    raise newException(ValueError, "JWT ttl must be positive")
  if extra.kind != JObject:
    raise newException(ValueError, "JWT extra claims must be a JSON object")
  let now = epochTime().int
  var payload = %*{"sub": subject, "iat": now, "exp": now + ttlSeconds}
  if issuer.len > 0:
    payload["iss"] = %issuer
  for name, value in extra:
    if name notin ["sub", "iat", "exp"]:
      payload[name] = value.copy()
  let signingInput =
    base64UrlEncode($(%*{"alg": "HS256", "typ": "JWT"})) & "." &
    base64UrlEncode($payload)
  let signature = sha256.hmac(secret, signingInput)
  var signatureBytes = newString(32)
  copyMem(addr signatureBytes[0], unsafeAddr signature.data[0], 32)
  signingInput & "." & base64UrlEncode(signatureBytes)

proc verifyJwtHs256*(
    token: string, secrets: openArray[string], leewaySeconds = 60
): JsonNode {.raises: [ValueError].} =
  ## Verifies an HS256 JWT against ``secrets`` and returns its payload.
  ##
  ## Secrets are tried in order so rotation is hitless. Tokens with another
  ## ``alg`` (including ``none``) are rejected outright. ``exp``/``nbf`` are
  ## enforced with ``leewaySeconds`` of clock skew. Raises ``ValueError`` with
  ## a generic message on any failure.
  const failure = "invalid JWT"
  let parts = token.strip().split('.')
  if parts.len != 3:
    raise newException(ValueError, failure)
  var header: JsonNode
  var payload: JsonNode
  try:
    header = parseJson(base64UrlDecode(parts[0]))
    payload = parseJson(base64UrlDecode(parts[1]))
  except CatchableError:
    raise newException(ValueError, failure)
  if header.kind != JObject or header.getOrDefault("alg").getStr("") != "HS256":
    raise newException(ValueError, failure)
  if payload.kind != JObject:
    raise newException(ValueError, failure)
  var signature: string
  try:
    signature = base64UrlDecode(parts[2])
  except CatchableError:
    raise newException(ValueError, failure)
  if signature.len != 32:
    raise newException(ValueError, failure)
  let signingInput = parts[0] & "." & parts[1]
  var matched = false
  for secret in secrets:
    if secret.len == 0:
      continue
    let digest = sha256.hmac(secret, signingInput)
    var digestSeq = newSeq[byte](32)
    var signatureSeq = newSeq[byte](32)
    copyMem(addr digestSeq[0], unsafeAddr digest.data[0], 32)
    copyMem(addr signatureSeq[0], addr signature[0], 32)
    if secureCompareBytes(digestSeq, signatureSeq):
      matched = true
      break
  if not matched:
    raise newException(ValueError, failure)
  let now = epochTime()
  if "exp" in payload:
    if payload["exp"].kind notin {JInt, JFloat}:
      raise newException(ValueError, failure)
    if now > payload["exp"].getFloat() + float(leewaySeconds):
      raise newException(ValueError, failure)
  if "nbf" in payload:
    if payload["nbf"].kind notin {JInt, JFloat}:
      raise newException(ValueError, failure)
    if now + float(leewaySeconds) < payload["nbf"].getFloat():
      raise newException(ValueError, failure)
  payload

proc verifyJwtHs256*(
    token, secret: string, leewaySeconds = 60
): JsonNode {.raises: [ValueError].} =
  ## Verifies an HS256 JWT against a single ``secret``.
  verifyJwtHs256(token, [secret], leewaySeconds)
