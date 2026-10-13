## Request body, header, and handler deadline limits.
##
## Oversized bodies and uploads return ``413``. Oversized header names, values,
## counts, and the raw header block return ``431``. Chronos returns ``408`` when
## a client stalls while sending headers and ``400`` for a malformed request.
## A handler that exceeds ``handlerTimeout`` returns ``503``.
##
## Server-sent events and WebSocket routes are not subject to
## ``handlerTimeout``. Blocking calls such as ``os.sleep`` cannot be cancelled;
## handlers must await Chronos operations.
##
## ``maxBodySize`` is the outer cap. A multipart endpoint's ``maxRequestSize``
## must be less than or equal to it. A smaller body cap rejects the request
## before ``parseMultipart`` runs. A handler deadline cancels multipart parsing
## and removes partial uploads.

import std/[parseutils, strutils, tables]

import chronos

const
  BodyTooLargeDetail* = "request body exceeds the size limit"
    ## JSON ``detail`` for a ``413`` body limit.
  HeaderNameTooLargeDetail* = "request header name exceeds the size limit"
    ## JSON ``detail`` for a header name that exceeds its limit.
  HeaderValueTooLargeDetail* = "request header value exceeds the size limit"
    ## JSON ``detail`` for a header value that exceeds its limit.
  TooManyHeadersDetail* = "request contains too many headers"
    ## JSON ``detail`` for a header count that exceeds its limit.
  HandlerTimeoutDetail* = "request handler timed out"
    ## JSON ``detail`` for a ``503`` handler deadline.

type RequestLimits* = object
  ## Caps applied before parsing and to each HTTP handler invocation.
  ##
  ## ``maxBodySize``, ``maxHeadersSize``, and ``headersTimeout`` are copied
  ## into the Chronos server when ``serve`` starts. Header name, value, and
  ## count limits, plus ``handlerTimeout``, are read on each request.
  maxBodySize*: int ## Maximum request-body bytes, including ``Content-Length``.
  maxHeadersSize*: int ## Maximum raw header-block bytes enforced by Chronos.
  maxHeaderNameSize*: int ## Maximum bytes in one header name.
  maxHeaderValueSize*: int ## Maximum bytes in one header value.
  maxHeaderCount*: int ## Maximum number of distinct header names.
  headersTimeout*: Duration ## How long Chronos waits for the header block.
  handlerTimeout*: Duration
    ## Deadline for one HTTP handler. ``InfiniteDuration`` disables it.
    ## Server-sent events and WebSocket routes are exempt.

proc validateRequestLimits*(limits: RequestLimits) =
  ## Raises ``ValueError`` when ``limits`` breaks the ``initRequestLimits`` contract.
  if limits.maxBodySize <= 0 or limits.maxHeadersSize <= 0 or
      limits.maxHeaderNameSize <= 0 or limits.maxHeaderValueSize <= 0 or
      limits.maxHeaderCount <= 0:
    raise newException(ValueError, "request limits must be positive")
  if limits.maxHeaderNameSize > limits.maxHeadersSize or
      limits.maxHeaderValueSize > limits.maxHeadersSize:
    raise newException(
      ValueError, "header name and value limits must fit in the header block"
    )
  if limits.headersTimeout.isZero():
    raise newException(
      ValueError, "headers timeout must be positive or infinite"
    )
  if limits.handlerTimeout.isZero():
    raise newException(
      ValueError, "handler timeout must be positive or infinite"
    )

proc initRequestLimits*(
    maxBodySize = 32 * 1024 * 1024,
    maxHeadersSize = 8192,
    maxHeaderNameSize = 256,
    maxHeaderValueSize = 8192,
    maxHeaderCount = 100,
    headersTimeout = 10.seconds,
    handlerTimeout = 30.seconds,
): RequestLimits =
  ## Creates request limits.
  ##
  ## Every size must be positive. ``maxHeaderNameSize`` and
  ## ``maxHeaderValueSize`` must be less than or equal to ``maxHeadersSize``.
  ## A timeout must be positive or ``InfiniteDuration``.
  ##
  ## ``maxBodySize`` defaults to 32 MiB. ``maxHeadersSize`` defaults to
  ## Chronos' 8192-byte header block. ``handlerTimeout`` defaults to 30
  ## seconds and applies to each HTTP handler, not to server-sent events or
  ## WebSockets. Keep ``maxBodySize`` greater than or equal to any multipart
  ## ``maxRequestSize``; the smaller body cap rejects the request first.
  result = RequestLimits(
    maxBodySize: maxBodySize,
    maxHeadersSize: maxHeadersSize,
    maxHeaderNameSize: maxHeaderNameSize,
    maxHeaderValueSize: maxHeaderValueSize,
    maxHeaderCount: maxHeaderCount,
    headersTimeout: headersTimeout,
    handlerTimeout: handlerTimeout,
  )
  validateRequestLimits(result)

proc headerValue(headers: Table[string, string], name: string): string =
  if name in headers:
    return headers.getOrDefault(name)
  for key, value in headers:
    if key.toLowerAscii() == name:
      return value

proc headerLimitDetail*(
    headers: Table[string, string], limits: RequestLimits
): string {.raises: [].} =
  ## Returns the ``431`` detail for a header violation, or ``""`` when allowed.
  ##
  ## The count is the number of entries in ``headers``. The Chronos adapter
  ## lowercases names and combines duplicates before this check. The raw
  ## header block is limited separately by ``maxHeadersSize``.
  if headers.len > limits.maxHeaderCount:
    return TooManyHeadersDetail
  for key, value in headers:
    if key.len > limits.maxHeaderNameSize:
      return HeaderNameTooLargeDetail
    if value.len > limits.maxHeaderValueSize:
      return HeaderValueTooLargeDetail

proc bodyLimitDetail*(
    headers: Table[string, string], body: string, limits: RequestLimits
): string {.raises: [].} =
  ## Returns the ``413`` detail when the body exceeds ``maxBodySize``.
  ##
  ## A numeric ``Content-Length`` above the cap is rejected even when ``body``
  ## is still empty, so streaming uploads are refused before they are parsed.
  ## A length equal to the cap is allowed. An unparsable length is left for
  ## the body parser.
  let declared = headerValue(headers, "content-length")
  if declared.len > 0:
    var size: BiggestInt
    try:
      if parseBiggestInt(declared, size) == declared.len and
          size > limits.maxBodySize:
        return BodyTooLargeDetail
    except ValueError:
      discard
  if body.len > limits.maxBodySize:
    return BodyTooLargeDetail
