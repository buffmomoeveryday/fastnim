## HTTP, SSE, and WebSocket resource limits.
##
## Oversized bodies and uploads return ``413``. Header and body-read stalls
## return ``408``. Handler timeouts and exhausted handler/SSE/WebSocket capacity
## return ``503``. Accepted connections, concurrent ordinary handlers, listen
## backlog, and keep-alive time are bounded independently.
##
## SSE and WebSocket routes have their own connection counts, I/O idle
## deadlines, message/event sizes, and heartbeat intervals. They are not
## subject to the ordinary HTTP ``handlerTimeout``.
##
## ``maxBodySize`` is the outer cap. A multipart endpoint's ``maxRequestSize``
## must be less than or equal to it. A smaller body cap rejects the request
## before ``parseMultipart`` runs. A handler deadline cancels multipart parsing
## and removes partial uploads.

import std/[parseutils, strutils]

import chronos
import ../context/http

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
  BodyReadTimeoutDetail* = "request body read timed out"
    ## JSON ``detail`` for a ``408`` body-read deadline.
  BodyRateTooLowDetail* = "request body data rate is too low"
    ## JSON ``detail`` for a ``408`` minimum body data-rate violation.
  HandlerCapacityDetail* = "server handler capacity is exhausted"
    ## JSON ``detail`` for a ``503`` concurrent-handler rejection.
  SseCapacityDetail* = "SSE connection limit is reached"
    ## JSON ``detail`` for a ``503`` SSE connection rejection.
  WebSocketCapacityDetail* = "WebSocket connection limit is reached"
    ## JSON ``detail`` for a ``503`` WebSocket connection rejection.

type
  BodyReadLimitError* = object of CatchableError
    ## Raised while a streaming body violates its deadline or minimum rate.
    detail*: string ## Stable response detail describing the violated limit.

  SseLimits* = object
    ## Resource limits applied independently to server-sent event routes.
    maxConnections*: int ## Maximum simultaneously active SSE handlers.
    idleTimeout*: Duration
      ## Maximum time allowed for an SSE write to make progress.
    maxEventSize*: int ## Maximum encoded bytes in one event.
    heartbeatInterval*: Duration
      ## Interval for SSE comment heartbeats; ``InfiniteDuration`` disables them.

  WebSocketLimits* = object
    ## Resource limits applied independently to WebSocket routes.
    maxConnections*: int ## Maximum simultaneously active WebSocket handlers.
    idleTimeout*: Duration
      ## Maximum time allowed for a WebSocket send or receive operation.
    maxMessageSize*: int ## Maximum bytes in one incoming or outgoing message.
    heartbeatInterval*: Duration
      ## Interval between WebSocket ping frames; ``InfiniteDuration`` disables them.

  RequestLimits* = object
    ## Caps applied before parsing and to each HTTP handler invocation.
    ##
    ## Transport-level values are captured when ``serve`` starts. Reconfigure
    ## limits before starting a server.
    maxBodySize*: int ## Maximum request-body bytes, including ``Content-Length``.
    maxHeadersSize*: int ## Maximum raw header-block bytes enforced by Chronos.
    maxHeaderNameSize*: int ## Maximum bytes in one header name.
    maxHeaderValueSize*: int ## Maximum bytes in one header value.
    maxHeaderCount*: int ## Maximum number of distinct header names.
    headersTimeout*: Duration ## How long Chronos waits for the header block.
    bodyReadTimeout*: Duration
      ## Total deadline for reading a request body, including multipart bodies.
    minBodyBytesPerSecond*: int
      ## Minimum sustained body rate after ``bodyReadGracePeriod``; zero disables it.
    bodyReadGracePeriod*: Duration
      ## Initial body-read period excluded from minimum-rate enforcement.
    keepAliveTimeout*: Duration
      ## Maximum idle wait for the next request on an HTTP connection.
    handlerTimeout*: Duration
      ## Deadline for one HTTP handler. ``InfiniteDuration`` disables it.
      ## Server-sent events and WebSocket routes are exempt.
    maxConnections*: int ## Maximum accepted HTTP connections.
    maxConcurrentHandlers*: int ## Maximum ordinary HTTP handlers running at once.
    backlog*: int ## TCP listen backlog passed to Chronos.
    sse*: SseLimits ## Limits for SSE connections and events.
    websocket*: WebSocketLimits ## Limits for WebSocket connections and messages.

proc validateDuration(name: string, value: Duration) =
  if not value.isInfinite() and value <= ZeroDuration:
    raise newException(ValueError, name & " must be positive or infinite")

proc initSseLimits*(
    maxConnections = 128,
    idleTimeout = 30.seconds,
    maxEventSize = 1024 * 1024,
    heartbeatInterval = 15.seconds,
): SseLimits =
  ## Creates validated SSE resource limits.
  if maxConnections <= 0 or maxEventSize <= 0:
    raise newException(ValueError, "SSE connection and event limits must be positive")
  validateDuration("SSE idle timeout", idleTimeout)
  validateDuration("SSE heartbeat interval", heartbeatInterval)
  SseLimits(
    maxConnections: maxConnections,
    idleTimeout: idleTimeout,
    maxEventSize: maxEventSize,
    heartbeatInterval: heartbeatInterval,
  )

proc initWebSocketLimits*(
    maxConnections = 128,
    idleTimeout = 30.seconds,
    maxMessageSize = 1024 * 1024,
    heartbeatInterval = 15.seconds,
): WebSocketLimits =
  ## Creates validated WebSocket resource limits.
  if maxConnections <= 0 or maxMessageSize <= 0:
    raise newException(
      ValueError, "WebSocket connection and message limits must be positive"
    )
  validateDuration("WebSocket idle timeout", idleTimeout)
  validateDuration("WebSocket heartbeat interval", heartbeatInterval)
  WebSocketLimits(
    maxConnections: maxConnections,
    idleTimeout: idleTimeout,
    maxMessageSize: maxMessageSize,
    heartbeatInterval: heartbeatInterval,
  )

proc validateRequestLimits*(limits: RequestLimits) =
  ## Raises ``ValueError`` when ``limits`` breaks the ``initRequestLimits`` contract.
  if limits.maxBodySize <= 0 or limits.maxHeadersSize <= 0 or
      limits.maxHeaderNameSize <= 0 or limits.maxHeaderValueSize <= 0 or
      limits.maxHeaderCount <= 0 or limits.maxConnections <= 0 or
      limits.maxConcurrentHandlers <= 0 or limits.backlog <= 0:
    raise newException(ValueError, "request limits must be positive")
  if limits.minBodyBytesPerSecond < 0:
    raise newException(ValueError, "minimum body data rate cannot be negative")
  if limits.maxHeaderNameSize > limits.maxHeadersSize or
      limits.maxHeaderValueSize > limits.maxHeadersSize:
    raise newException(
      ValueError, "header name and value limits must fit in the header block"
    )
  validateDuration("headers timeout", limits.headersTimeout)
  validateDuration("body read timeout", limits.bodyReadTimeout)
  if limits.bodyReadGracePeriod < ZeroDuration:
    raise newException(ValueError, "body read grace period cannot be negative")
  validateDuration("keep-alive timeout", limits.keepAliveTimeout)
  validateDuration("handler timeout", limits.handlerTimeout)
  discard initSseLimits(
    limits.sse.maxConnections,
    limits.sse.idleTimeout,
    limits.sse.maxEventSize,
    limits.sse.heartbeatInterval,
  )
  discard initWebSocketLimits(
    limits.websocket.maxConnections,
    limits.websocket.idleTimeout,
    limits.websocket.maxMessageSize,
    limits.websocket.heartbeatInterval,
  )

proc initRequestLimits*(
    maxBodySize = 32 * 1024 * 1024,
    maxHeadersSize = 8192,
    maxHeaderNameSize = 256,
    maxHeaderValueSize = 8192,
    maxHeaderCount = 100,
    headersTimeout = 10.seconds,
    bodyReadTimeout = 30.seconds,
    minBodyBytesPerSecond = 1024,
    bodyReadGracePeriod = 5.seconds,
    keepAliveTimeout = 15.seconds,
    handlerTimeout = 30.seconds,
    maxConnections = 1024,
    maxConcurrentHandlers = 256,
    backlog = 128,
    sse = initSseLimits(),
    websocket = initWebSocketLimits(),
): RequestLimits =
  ## Creates request limits.
  ##
  ## Sizes and capacity values must be positive. ``maxHeaderNameSize`` and
  ## ``maxHeaderValueSize`` must be less than or equal to ``maxHeadersSize``.
  ## A timeout must be positive or ``InfiniteDuration``.
  ##
  ## ``maxBodySize`` defaults to 32 MiB. Body reads have a 30-second total
  ## deadline and, after a five-second grace period, must sustain 1 KiB/s.
  ## Ordinary HTTP handlers default to 256 concurrent executions across at
  ## most 1024 accepted connections. Keep ``maxBodySize`` greater than or
  ## equal to any multipart ``maxRequestSize``.
  result = RequestLimits(
    maxBodySize: maxBodySize,
    maxHeadersSize: maxHeadersSize,
    maxHeaderNameSize: maxHeaderNameSize,
    maxHeaderValueSize: maxHeaderValueSize,
    maxHeaderCount: maxHeaderCount,
    headersTimeout: headersTimeout,
    bodyReadTimeout: bodyReadTimeout,
    minBodyBytesPerSecond: minBodyBytesPerSecond,
    bodyReadGracePeriod: bodyReadGracePeriod,
    keepAliveTimeout: keepAliveTimeout,
    handlerTimeout: handlerTimeout,
    maxConnections: maxConnections,
    maxConcurrentHandlers: maxConcurrentHandlers,
    backlog: backlog,
    sse: sse,
    websocket: websocket,
  )
  validateRequestLimits(result)

proc headerValue(headers: Headers, name: string): string =
  if name in headers:
    return headers.getOrDefault(name)
  for key, value in headers:
    if key.toLowerAscii() == name:
      return value

proc headerLimitDetail*(
    headers: Headers, limits: RequestLimits
): string {.raises: [].} =
  ## Returns the ``431`` detail for a header violation, or ``""`` when allowed.
  ##
  ## The count is the number of distinct names in ``headers``. Each repeated
  ## value is checked separately. The raw header block is limited separately
  ## by ``maxHeadersSize``.
  if headers.len > limits.maxHeaderCount:
    return TooManyHeadersDetail
  for key, value in headers:
    if key.len > limits.maxHeaderNameSize:
      return HeaderNameTooLargeDetail
    if value.len > limits.maxHeaderValueSize:
      return HeaderValueTooLargeDetail

proc bodyLimitDetail*(
    headers: Headers, body: string, limits: RequestLimits
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
