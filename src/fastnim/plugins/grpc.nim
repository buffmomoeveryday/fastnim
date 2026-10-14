## Native gRPC plugin with unary and streaming route DSLs.
##
## The listener implements HTTP/2, gRPC message framing, protobuf payloads,
## metadata, status trailers, and optional TLS termination through Chronos's
## statically compiled BearSSL transport.

import std/[macros, options, strutils, tables]

import chronos
import chronos/streams/[asyncstream, tlsstream]

import ../context/state, ../plugin, ../routing/router
import ../grpc/[hpack, protobuf, schema, types]

export protobuf, types

const
  GrpcPluginName = "grpc"
  GrpcRuntimeKey = "runtime"
  Http2Preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
  FrameData = 0'u8
  FrameHeaders = 1'u8
  FrameRstStream = 3'u8
  FrameSettings = 4'u8
  FramePing = 6'u8
  FrameGoAway = 7'u8
  FrameWindowUpdate = 8'u8
  FrameContinuation = 9'u8
  FlagEndStream = 0x01'u8
  FlagAck = 0x01'u8
  FlagEndHeaders = 0x04'u8
  FlagPadded = 0x08'u8
  FlagPriority = 0x20'u8

type
  GrpcTlsConfig* = object ## TLS certificate material for a gRPC listener.
    certificate*: TLSCertificate ## Parsed PEM certificate chain.
    privateKey*: TLSPrivateKey ## Parsed unencrypted PKCS#8 PEM private key.

  GrpcOptions* = object ## Configuration for the native gRPC listener.
    address*: string ## Address on which the listener binds.
    port*: uint16 ## TCP port on which the listener binds.
    maxMessageSize*: int ## Maximum uncompressed protobuf message size.
    tls*: GrpcTlsConfig ## Optional TLS configuration; empty selects h2c.

  GrpcServer* = ref object ## Handle for a running gRPC listener.
    stream: StreamServer

  GrpcRouteKind* {.pure.} = enum ## Message cardinality of a registered RPC.
    Unary
    ServerStreaming
    ClientStreaming
    BidirectionalStreaming

  GrpcRoute* = object ## A registered RPC endpoint.
    path*: string ## Fully qualified RPC path.
    kind*: GrpcRouteKind ## Request and response streaming shape.
    handler*: GrpcRawStreamHandler ## Typed adapter compiled by a route macro.

  GrpcRuntime = ref object
    options: GrpcOptions
    routes: seq[GrpcRoute]

  GrpcConnection = ref object
    reader: AsyncStreamReader
    writer: AsyncStreamWriter
    transport: StreamTransport
    tlsStream: TLSAsyncStream
    writeLock: AsyncLock
    flowChanged: AsyncEvent
    encoder: HpackEncoder
    connectionWindow: int64
    initialStreamWindow: int64
    maxFrameSize: int

  Http2Frame = object
    kind: byte
    flags: byte
    streamId: int32
    payload: seq[byte]

  GrpcStreamState = ref object
    headers: Table[string, string]
    headerBlock: seq[byte]
    body: seq[byte]
    waitingContinuation: bool
    endStream: bool
    pendingEndStream: bool
    started: bool
    finished: bool
    input: AsyncQueue[Option[seq[byte]]]
    connection: GrpcConnection
    streamId: int32
    maxMessageSize: int
    sentHeaders: bool
    sentMessages: int
    sendWindow: int64

proc initGrpcTlsConfig*(certificatePem, privateKeyPem: string): GrpcTlsConfig =
  ## Parses PEM certificate material for TLS termination.
  if certificatePem.len == 0 or privateKeyPem.len == 0:
    raise newException(ValueError, "gRPC TLS certificate and key cannot be empty")
  GrpcTlsConfig(
    certificate: TLSCertificate.init(certificatePem),
    privateKey: TLSPrivateKey.init(privateKeyPem),
  )

func tlsEnabled*(options: GrpcOptions): bool =
  ## Returns whether the listener terminates TLS itself.
  options.tls.certificate != nil and options.tls.privateKey != nil

proc initGrpcOptions*(
    address = "127.0.0.1", port: uint16 = 50051,
    maxMessageSize = 4 * 1024 * 1024,
    tls = GrpcTlsConfig(),
): GrpcOptions =
  ## Creates validated native gRPC listener settings.
  if address.len == 0:
    raise newException(ValueError, "gRPC listener address cannot be empty")
  if maxMessageSize <= 0:
    raise newException(ValueError, "gRPC maximum message size must be positive")
  if (tls.certificate == nil) != (tls.privateKey == nil):
    raise newException(ValueError, "gRPC TLS requires both certificate and key")
  GrpcOptions(
    address: address, port: port, maxMessageSize: maxMessageSize, tls: tls
  )

proc grpcPlugin*(options = initGrpcOptions()): Plugin =
  ## Creates the native unary and streaming gRPC plugin.
  initPlugin(
    GrpcPluginName,
    "0.1.0",
    proc(app: Application) =
      app.pluginContext(GrpcPluginName).setContext(
        GrpcRuntimeKey, GrpcRuntime(options: options, routes: @[])
      ),
  )

proc grpcRuntime(app: Application): GrpcRuntime =
  let pluginCtx = app.pluginContext(GrpcPluginName)
  if not pluginCtx.has(GrpcRuntimeKey):
    raise newException(
      ValueError,
      "gRPC plugin is not installed; call app.install(grpcPlugin()) first",
    )
  pluginCtx.get(GrpcRuntimeKey, GrpcRuntime)

proc addGrpcRoute*(
    app: Application, path: string, kind: GrpcRouteKind,
    handler: GrpcRawStreamHandler,
) =
  ## Registers a compiled gRPC handler.
  if path.len < 4 or path[0] != '/' or path.count('/') != 2:
    raise newException(
      ValueError, "gRPC paths must use /package.Service/Method"
    )
  if handler.isNil:
    raise newException(ValueError, "gRPC route handler cannot be nil")
  let runtime = app.grpcRuntime()
  for route in runtime.routes:
    if route.path == path:
      raise newException(ValueError, "duplicate gRPC route: " & path)
  runtime.routes.add(GrpcRoute(path: path, kind: kind, handler: handler))

proc replaceGrpcNames(node, requestParam, callParam: NimNode): NimNode =
  if node.kind == nnkIdent:
    if eqIdent(node, "request"):
      return requestParam
    if eqIdent(node, "call"):
      return callParam
    return node
  result = copyNimNode(node)
  for child in node:
    result.add(replaceGrpcNames(child, requestParam, callParam))

template checkedGrpcResponse*[T](model: T): seq[byte] =
  ## Checks an explicit handler return against its declared response type.
  encodeProtobuf(model)

proc encodeReturns(node, responseType: NimNode): NimNode =
  if node.kind == nnkReturnStmt and node.len == 1:
    let encoder = newTree(
      nnkBracketExpr, ident("checkedGrpcResponse"), responseType
    )
    return newTree(nnkReturnStmt, newCall(encoder, node[0]))
  result = copyNimNode(node)
  for child in node:
    result.add(encodeReturns(child, responseType))

macro grpc*(app: Application, path: typed, args: varargs[untyped]): untyped =
  ## Registers a typed unary RPC.
  ##
  ## ``request`` is the decoded request model and ``call`` exposes metadata and
  ## application context. The final expression, or an explicit ``return``, must
  ## have the declared response type.
  ##
  ## ```nim
  ## app.grpc(
  ##   "/hello.Greeter/SayHello", request = HelloRequest,
  ##   responses = HelloReply,
  ## ):
  ##   HelloReply(message: "Hello " & request.name)
  ## ```
  var requestType = newEmptyNode()
  var responseType = newEmptyNode()
  var protoPath = newEmptyNode()
  var routeBody = newEmptyNode()
  for argument in args:
    if argument.kind == nnkExprEqExpr:
      case $argument[0]
      of "request":
        requestType = argument[1]
      of "responses", "response":
        responseType = argument[1]
      of "proto":
        protoPath = argument[1]
      else:
        error("unsupported gRPC route option: " & $argument[0], argument)
    elif routeBody.kind == nnkEmpty:
      routeBody = argument
    else:
      error("gRPC routes accept one handler block", argument)
  if requestType.kind == nnkEmpty:
    error("gRPC routes require `request = MessageType`", path)
  if responseType.kind == nnkEmpty:
    error("gRPC routes require `responses = MessageType`", path)
  if protoPath.kind == nnkEmpty:
    error("gRPC routes require `proto = \"schema.proto\"`", path)
  if routeBody.kind == nnkEmpty or routeBody.kind != nnkStmtList:
    error("gRPC routes require a handler block", path)
  let resolvedProtoPath = newLit(resolveProtoPath(protoPath))

  let callParam = genSym(nskParam, "call")
  let payloadParam = genSym(nskParam, "payload")
  let requestParam = genSym(nskLet, "request")
  let responseParam = genSym(nskLet, "response")
  let unaryHandler = genSym(nskLet, "grpcUnaryHandler")
  let handler = genSym(nskLet, "grpcStreamHandler")
  let receiveParam = genSym(nskParam, "receive")
  let sendParam = genSym(nskParam, "send")
  let incoming = genSym(nskLet, "incoming")
  var rewritten = encodeReturns(
    replaceGrpcNames(routeBody, requestParam, callParam), responseType
  )
  let finalExpression = rewritten[^1]
  if finalExpression.kind != nnkReturnStmt:
    rewritten.del(rewritten.len - 1)
    rewritten.add(quote do:
      let `responseParam`: `responseType` = `finalExpression`
      return encodeProtobuf(`responseParam`)
    )

  result = quote do:
    validateGrpcContract(
      `resolvedProtoPath`, `path`, `requestType`, `responseType`, false, false
    )
    let `unaryHandler`: GrpcRawHandler = proc(
        `callParam`: GrpcCall, `payloadParam`: seq[byte]
    ): Future[seq[byte]] {.async: (raises: [CatchableError]).} =
      let `requestParam`: `requestType` =
        decodeProtobuf(`payloadParam`, `requestType`)
      `rewritten`
    let `handler`: GrpcRawStreamHandler = proc(
        `callParam`: GrpcCall, `receiveParam`: GrpcRawReceive,
        `sendParam`: GrpcRawSend,
    ): Future[void] {.async: (raises: [CatchableError]).} =
      let `incoming` = await `receiveParam`()
      if `incoming`.isNone:
        raise grpcError(GrpcStatus.InvalidArgument, "unary request is missing")
      {.cast(gcsafe).}:
        let response = await `unaryHandler`(`callParam`, `incoming`.get())
        await `sendParam`(response)
      if (await `receiveParam`()).isSome:
        raise grpcError(
          GrpcStatus.InvalidArgument, "unary RPC received multiple messages"
        )
    addGrpcRoute(`app`, `path`, GrpcRouteKind.Unary, `handler`)

proc parseStreamingArgs(
    path: NimNode, args: NimNode, requestType, responseType, protoPath,
    routeBody: var NimNode,
) {.compileTime.} =
  for argument in args:
    if argument.kind == nnkExprEqExpr:
      case $argument[0]
      of "request":
        requestType = argument[1]
      of "responses", "response":
        responseType = argument[1]
      of "proto":
        protoPath = argument[1]
      else:
        error("unsupported gRPC streaming route option: " & $argument[0], argument)
    elif routeBody.kind == nnkEmpty:
      routeBody = argument
    else:
      error("gRPC streaming routes accept one handler block", argument)
  if requestType.kind == nnkEmpty:
    error("gRPC streaming routes require `request = MessageType`", path)
  if responseType.kind == nnkEmpty:
    error("gRPC streaming routes require `responses = MessageType`", path)
  if protoPath.kind == nnkEmpty:
    error("gRPC streaming routes require `proto = \"schema.proto\"`", path)
  if routeBody.kind != nnkStmtList:
    error("gRPC streaming routes require a handler block", path)

proc replaceStreamNames(
    node, requestParam, streamParam, callParam: NimNode
): NimNode =
  if node.kind == nnkIdent:
    if eqIdent(node, "request") and requestParam.kind != nnkEmpty:
      return requestParam
    if eqIdent(node, "stream"):
      return streamParam
    if eqIdent(node, "call"):
      return callParam
    return node
  result = copyNimNode(node)
  for child in node:
    result.add(replaceStreamNames(child, requestParam, streamParam, callParam))

macro grpcServerStream*(
    app: Application, path: typed, args: varargs[untyped]
): untyped =
  ## Registers a unary-request, server-streaming RPC.
  ##
  ## ``request`` is decoded once; use ``await stream.send(response)`` any
  ## number of times from the handler block.
  var requestType = newEmptyNode()
  var responseType = newEmptyNode()
  var protoPath = newEmptyNode()
  var routeBody = newEmptyNode()
  parseStreamingArgs(path, args, requestType, responseType, protoPath, routeBody)
  let resolvedProtoPath = newLit(resolveProtoPath(protoPath))
  let callParam = genSym(nskParam, "call")
  let receiveParam = genSym(nskParam, "receive")
  let sendParam = genSym(nskParam, "send")
  let requestParam = genSym(nskLet, "request")
  let streamParam = genSym(nskLet, "stream")
  let incoming = genSym(nskLet, "incoming")
  let handler = genSym(nskLet, "grpcServerStreamHandler")
  let boundBody = replaceStreamNames(
    routeBody, requestParam, streamParam, callParam
  )
  result = quote do:
    validateGrpcContract(
      `resolvedProtoPath`, `path`, `requestType`, `responseType`, false, true
    )
    let `handler`: GrpcRawStreamHandler = proc(
        `callParam`: GrpcCall, `receiveParam`: GrpcRawReceive,
        `sendParam`: GrpcRawSend,
    ): Future[void] {.async: (raises: [CatchableError]).} =
      let `incoming` = await `receiveParam`()
      if `incoming`.isNone:
        raise grpcError(GrpcStatus.InvalidArgument, "request is missing")
      let `requestParam`: `requestType` =
        decodeProtobuf(`incoming`.get(), `requestType`)
      if (await `receiveParam`()).isSome:
        raise grpcError(
          GrpcStatus.InvalidArgument,
          "server-streaming RPC received multiple requests",
        )
      let `streamParam` = initGrpcStream[`requestType`, `responseType`](
        `receiveParam`, `sendParam`
      )
      `boundBody`
    addGrpcRoute(
      `app`, `path`, GrpcRouteKind.ServerStreaming, `handler`
    )

macro grpcClientStream*(
    app: Application, path: typed, args: varargs[untyped]
): untyped =
  ## Registers a client-streaming RPC whose final expression is one response.
  var requestType = newEmptyNode()
  var responseType = newEmptyNode()
  var protoPath = newEmptyNode()
  var routeBody = newEmptyNode()
  parseStreamingArgs(path, args, requestType, responseType, protoPath, routeBody)
  let resolvedProtoPath = newLit(resolveProtoPath(protoPath))
  let callParam = genSym(nskParam, "call")
  let receiveParam = genSym(nskParam, "receive")
  let sendParam = genSym(nskParam, "send")
  let streamParam = genSym(nskLet, "stream")
  let responseParam = genSym(nskLet, "response")
  let handler = genSym(nskLet, "grpcClientStreamHandler")
  let boundBody = replaceStreamNames(
    routeBody, newEmptyNode(), streamParam, callParam
  )
  result = quote do:
    validateGrpcContract(
      `resolvedProtoPath`, `path`, `requestType`, `responseType`, true, false
    )
    let `handler`: GrpcRawStreamHandler = proc(
        `callParam`: GrpcCall, `receiveParam`: GrpcRawReceive,
        `sendParam`: GrpcRawSend,
    ): Future[void] {.async: (raises: [CatchableError]).} =
      let `streamParam` = initGrpcStream[`requestType`, `responseType`](
        `receiveParam`, `sendParam`
      )
      let `responseParam`: `responseType` = block:
        `boundBody`
      await `sendParam`(encodeProtobuf(`responseParam`))
    addGrpcRoute(
      `app`, `path`, GrpcRouteKind.ClientStreaming, `handler`
    )

macro grpcBidirectionalStream*(
    app: Application, path: typed, args: varargs[untyped]
): untyped =
  ## Registers a bidirectional streaming RPC.
  ##
  ## Use ``await stream.receive()`` and ``await stream.send(response)`` in the
  ## handler. Sending may happen before the client closes its request stream.
  var requestType = newEmptyNode()
  var responseType = newEmptyNode()
  var protoPath = newEmptyNode()
  var routeBody = newEmptyNode()
  parseStreamingArgs(path, args, requestType, responseType, protoPath, routeBody)
  let resolvedProtoPath = newLit(resolveProtoPath(protoPath))
  let callParam = genSym(nskParam, "call")
  let receiveParam = genSym(nskParam, "receive")
  let sendParam = genSym(nskParam, "send")
  let streamParam = genSym(nskLet, "stream")
  let handler = genSym(nskLet, "grpcBidirectionalHandler")
  let boundBody = replaceStreamNames(
    routeBody, newEmptyNode(), streamParam, callParam
  )
  result = quote do:
    validateGrpcContract(
      `resolvedProtoPath`, `path`, `requestType`, `responseType`, true, true
    )
    let `handler`: GrpcRawStreamHandler = proc(
        `callParam`: GrpcCall, `receiveParam`: GrpcRawReceive,
        `sendParam`: GrpcRawSend,
    ): Future[void] {.async: (raises: [CatchableError]).} =
      let `streamParam` = initGrpcStream[`requestType`, `responseType`](
        `receiveParam`, `sendParam`
      )
      `boundBody`
    addGrpcRoute(
      `app`, `path`, GrpcRouteKind.BidirectionalStreaming, `handler`
    )

template grpcStream*(app, path: untyped, args: varargs[untyped]): untyped =
  ## Short alias for ``grpcBidirectionalStream``.
  grpcBidirectionalStream(app, path, args)

proc addUint32(output: var seq[byte], value: uint32) =
  output.add(byte(value shr 24))
  output.add(byte(value shr 16))
  output.add(byte(value shr 8))
  output.add(byte(value))

proc readUint32(data: openArray[byte], position: int): uint32 =
  if position < 0 or position + 4 > data.len:
    raise newException(ValueError, "truncated HTTP/2 integer")
  (uint32(data[position]) shl 24) or
    (uint32(data[position + 1]) shl 16) or
    (uint32(data[position + 2]) shl 8) or uint32(data[position + 3])

proc readExact(connection: GrpcConnection, length: int): Future[seq[byte]] {.
    async: (raises: [CancelledError, AsyncStreamError, ValueError])
.} =
  if length == 0:
    return @[]
  result = await connection.reader.read(length)
  if result.len != length:
    raise newException(ValueError, "unexpected end of HTTP/2 connection")

proc readFrame(connection: GrpcConnection): Future[Http2Frame] {.
    async: (raises: [CancelledError, AsyncStreamError, ValueError])
.} =
  let header = await connection.readExact(9)
  let length =
    (int(header[0]) shl 16) or (int(header[1]) shl 8) or int(header[2])
  if length > 16_384:
    raise newException(ValueError, "HTTP/2 frame exceeds advertised maximum")
  result = Http2Frame(
    kind: header[3], flags: header[4],
    streamId: int32(header.readUint32(5) and 0x7fff_ffff'u32),
    payload: await connection.readExact(length),
  )

proc frameBytes(kind, flags: byte, streamId: int32, payload: seq[byte]): seq[byte] =
  result = @[
    byte(payload.len shr 16), byte(payload.len shr 8), byte(payload.len),
    kind, flags,
  ]
  result.addUint32(uint32(streamId) and 0x7fff_ffff'u32)
  result.add(payload)

proc writeFrame(
    connection: GrpcConnection, kind, flags: byte, streamId: int32,
    payload: seq[byte],
): Future[void] {.async: (raises: [CancelledError, AsyncStreamError]).} =
  await connection.writeLock.acquire()
  try:
    await connection.writer.write(frameBytes(kind, flags, streamId, payload))
  finally:
    try:
      connection.writeLock.release()
    except AsyncLockError:
      raiseAssert "gRPC connection write lock was released unexpectedly"

proc headerFragment(frame: Http2Frame): seq[byte] =
  var first = 0
  var last = frame.payload.len
  if (frame.flags and FlagPadded) != 0:
    if frame.payload.len == 0:
      raise newException(ValueError, "truncated padded HTTP/2 frame")
    first = 1
    last -= int(frame.payload[0])
  if (frame.flags and FlagPriority) != 0:
    first += 5
  if first > last:
    raise newException(ValueError, "invalid HTTP/2 header padding")
  result = frame.payload[first..<last]

proc dataFragment(frame: Http2Frame): seq[byte] =
  var first = 0
  var last = frame.payload.len
  if (frame.flags and FlagPadded) != 0:
    if frame.payload.len == 0:
      raise newException(ValueError, "truncated padded HTTP/2 frame")
    first = 1
    last -= int(frame.payload[0])
  if first > last:
    raise newException(ValueError, "invalid HTTP/2 data padding")
  result = frame.payload[first..<last]

proc grpcFrame(payload: seq[byte]): seq[byte] =
  result = @[0'u8]
  result.addUint32(uint32(payload.len))
  result.add(payload)

proc findRoute(runtime: GrpcRuntime, path: string): GrpcRoute =
  for route in runtime.routes:
    if route.path == path:
      return route

proc sendHeaders(state: GrpcStreamState): Future[void] {.
    async: (raises: [CancelledError, AsyncStreamError, ValueError])
.} =
  if not state.sentHeaders:
    let headers = state.connection.encoder.encode([
      (":status", "200"),
      ("content-type", "application/grpc"),
      ("grpc-encoding", "identity"),
    ])
    await state.connection.writeFrame(
      FrameHeaders, FlagEndHeaders, state.streamId, headers
    )
    state.sentHeaders = true

proc sendMessage(state: GrpcStreamState, payload: seq[byte]): Future[void] {.
    async: (raises: [CancelledError, AsyncStreamError, ValueError, GrpcError])
.} =
  if state.finished:
    raise newException(ValueError, "cannot send after the gRPC stream finished")
  if payload.len > state.maxMessageSize:
    raise grpcError(
      GrpcStatus.ResourceExhausted, "gRPC response exceeds configured limit"
    )
  await state.sendHeaders()
  let framed = grpcFrame(payload)
  var position = 0
  while position < framed.len:
    while state.connection.connectionWindow <= 0 or state.sendWindow <= 0:
      state.connection.flowChanged.clear()
      await state.connection.flowChanged.wait()
    let available = min(
      int64(state.connection.maxFrameSize),
      min(state.connection.connectionWindow, state.sendWindow),
    )
    let last = min(position + int(available), framed.len)
    let length = int64(last - position)
    state.connection.connectionWindow -= length
    state.sendWindow -= length
    await state.connection.writeFrame(
      FrameData, 0, state.streamId, framed[position..<last]
    )
    position = last
  inc state.sentMessages

proc finishStream(
    state: GrpcStreamState, status: GrpcStatus, message = ""
): Future[void] {.
    async: (raises: [CancelledError, AsyncStreamError, ValueError])
.} =
  if state.finished:
    return
  await state.sendHeaders()
  var fields = @[("grpc-status", $ord(status))]
  if message.len > 0:
    fields.add(("grpc-message", encodeGrpcMessage(message)))
  let trailers = state.connection.encoder.encode(fields)
  await state.connection.writeFrame(
    FrameHeaders, FlagEndHeaders or FlagEndStream, state.streamId, trailers
  )
  state.finished = true

proc runRoute(
    app: Application, route: GrpcRoute, state: GrpcStreamState
): Future[void] {.async: (raises: []).} =
  var inputEnded = false
  let receive: GrpcRawReceive = proc(): Future[Option[seq[byte]]] {.
      async: (raises: [CatchableError])
  .} =
    if inputEnded:
      return none(seq[byte])
    result = await state.input.get()
    if result.isNone:
      inputEnded = true
  let send: GrpcRawSend = proc(payload: seq[byte]): Future[void] {.
      async: (raises: [CatchableError])
  .} =
    await state.sendMessage(payload)
  try:
    let call = GrpcCall(
      path: state.headers.getOrDefault(":path"),
      metadata: state.headers,
      context: app.context,
    )
    await route.handler(call, receive, send)
    if route.kind in {GrpcRouteKind.Unary, GrpcRouteKind.ClientStreaming} and
        state.sentMessages != 1:
      raise grpcError(
        GrpcStatus.Internal, "RPC handler must send exactly one response"
      )
    await state.finishStream(GrpcStatus.Ok)
  except GrpcError as exc:
    try:
      await state.finishStream(exc.status, exc.msg)
    except CatchableError:
      discard
  except ProtobufError as exc:
    try:
      await state.finishStream(GrpcStatus.InvalidArgument, exc.msg)
    except CatchableError:
      discard
  except CatchableError:
    try:
      await state.finishStream(GrpcStatus.Internal, "internal server error")
    except CatchableError:
      discard

proc startRoute(
    app: Application, runtime: GrpcRuntime, state: GrpcStreamState
): Future[void] {.async: (raises: [CancelledError, AsyncStreamError, ValueError]).} =
  if state.started:
    return
  state.started = true
  let contentType = state.headers.getOrDefault("content-type")
  if state.headers.getOrDefault(":method") != "POST" or
      not contentType.startsWith("application/grpc"):
    await state.finishStream(
      GrpcStatus.Internal, "invalid gRPC request headers"
    )
    return
  let route = runtime.findRoute(state.headers.getOrDefault(":path"))
  if route.handler.isNil:
    await state.finishStream(GrpcStatus.Unimplemented, "method not found")
    return
  asyncSpawn runRoute(app, route, state)

proc feedMessages(state: GrpcStreamState, data: seq[byte]): Future[void] {.
    async: (raises: [CancelledError, ProtobufError, ValueError])
.} =
  state.body.add(data)
  while state.body.len >= 5:
    if state.body[0] != 0:
      raise newException(
        ProtobufError, "compressed gRPC messages are not supported"
      )
    let length = int(state.body.readUint32(1))
    if length > state.maxMessageSize:
      raise newException(
        ProtobufError, "gRPC message exceeds configured limit"
      )
    if state.body.len < length + 5:
      return
    let payload =
      if length == 0: @[]
      else: state.body[5..<length + 5]
    await state.input.addLast(some(payload))
    if state.body.len == length + 5:
      state.body.setLen(0)
    else:
      state.body = state.body[length + 5..^1]

proc endInput(state: GrpcStreamState): Future[void] {.
    async: (raises: [CancelledError, ProtobufError])
.} =
  if state.body.len != 0:
    raise newException(ProtobufError, "truncated gRPC message")
  if not state.endStream:
    state.endStream = true
    await state.input.addLast(none(seq[byte]))

proc abortInput(state: GrpcStreamState): Future[void] {.
    async: (raises: [CancelledError])
.} =
  state.body.setLen(0)
  if not state.endStream:
    state.endStream = true
    await state.input.addLast(none(seq[byte]))

proc processConnection(
    app: Application, runtime: GrpcRuntime, connection: GrpcConnection
): Future[void] {.
    async: (
      raises: [CancelledError, AsyncStreamError, ValueError, ProtobufError]
    )
.} =
  let preface = await connection.readExact(Http2Preface.len)
  for index, value in Http2Preface:
    if preface[index] != byte(value):
      raise newException(ValueError, "invalid HTTP/2 client preface")
  await connection.writeFrame(FrameSettings, 0, 0, @[])

  var decoder = initHpackDecoder()
  var streams = initTable[int32, GrpcStreamState]()
  try:
    while true:
      let frame = await connection.readFrame()
      case frame.kind
      of FrameSettings:
        if (frame.flags and FlagAck) == 0:
          if frame.streamId != 0 or frame.payload.len mod 6 != 0:
            raise newException(ValueError, "invalid HTTP/2 settings frame")
          var position = 0
          while position < frame.payload.len:
            let identifier =
              (uint16(frame.payload[position]) shl 8) or
              uint16(frame.payload[position + 1])
            let value = frame.payload.readUint32(position + 2)
            case identifier
            of 4:
              if value > 0x7fff_ffff'u32:
                raise newException(ValueError, "invalid HTTP/2 stream window")
              let delta = int64(value) - connection.initialStreamWindow
              connection.initialStreamWindow = int64(value)
              for _, state in streams:
                state.sendWindow += delta
              connection.flowChanged.fire()
            of 5:
              if value < 16_384 or value > 16_777_215:
                raise newException(ValueError, "invalid HTTP/2 maximum frame size")
              connection.maxFrameSize = int(value)
            else:
              discard
            position += 6
          await connection.writeFrame(FrameSettings, FlagAck, 0, @[])
      of FramePing:
        if (frame.flags and FlagAck) == 0 and frame.payload.len == 8:
          await connection.writeFrame(FramePing, FlagAck, 0, frame.payload)
      of FrameHeaders:
        if frame.streamId == 0:
          raise newException(ValueError, "HTTP/2 headers require a stream")
        var state = streams.getOrDefault(frame.streamId)
        if state.isNil:
          state = GrpcStreamState(
            headers: initTable[string, string](),
            input: newAsyncQueue[Option[seq[byte]]](),
            connection: connection,
            streamId: frame.streamId,
            maxMessageSize: runtime.options.maxMessageSize,
            sendWindow: connection.initialStreamWindow,
          )
        state.headerBlock.add(frame.headerFragment())
        state.waitingContinuation = (frame.flags and FlagEndHeaders) == 0
        state.pendingEndStream = (frame.flags and FlagEndStream) != 0
        if not state.waitingContinuation:
          state.headers = decoder.decode(state.headerBlock)
          state.headerBlock.setLen(0)
        streams[frame.streamId] = state
        if not state.waitingContinuation:
          await startRoute(app, runtime, state)
          if state.pendingEndStream:
            await state.endInput()
      of FrameContinuation:
        if frame.streamId notin streams or
            not streams[frame.streamId].waitingContinuation:
          raise newException(ValueError, "unexpected HTTP/2 continuation")
        streams[frame.streamId].headerBlock.add(frame.payload)
        if (frame.flags and FlagEndHeaders) != 0:
          streams[frame.streamId].headers =
            decoder.decode(streams[frame.streamId].headerBlock)
          streams[frame.streamId].headerBlock.setLen(0)
          streams[frame.streamId].waitingContinuation = false
          await startRoute(app, runtime, streams[frame.streamId])
          if streams[frame.streamId].pendingEndStream:
            await streams[frame.streamId].endInput()
      of FrameData:
        if frame.streamId notin streams:
          raise newException(ValueError, "HTTP/2 data for unknown stream")
        let state = streams[frame.streamId]
        try:
          await state.feedMessages(frame.dataFragment())
          if (frame.flags and FlagEndStream) != 0:
            await state.endInput()
        except ProtobufError as exc:
          await state.abortInput()
          await state.finishStream(GrpcStatus.InvalidArgument, exc.msg)
        if frame.payload.len > 0:
          var increment: seq[byte]
          increment.addUint32(uint32(frame.payload.len))
          await connection.writeFrame(FrameWindowUpdate, 0, 0, increment)
          await connection.writeFrame(
            FrameWindowUpdate, 0, frame.streamId, increment
          )
      of FrameWindowUpdate:
        if frame.payload.len != 4:
          raise newException(ValueError, "invalid HTTP/2 window update")
        let increment = int64(frame.payload.readUint32(0) and 0x7fff_ffff'u32)
        if increment == 0:
          raise newException(ValueError, "zero HTTP/2 window increment")
        if frame.streamId == 0:
          if connection.connectionWindow + increment > 0x7fff_ffff'i64:
            raise newException(ValueError, "HTTP/2 connection window overflow")
          connection.connectionWindow += increment
        elif frame.streamId in streams:
          let state = streams[frame.streamId]
          if state.sendWindow + increment > 0x7fff_ffff'i64:
            raise newException(ValueError, "HTTP/2 stream window overflow")
          state.sendWindow += increment
        connection.flowChanged.fire()
      of FrameRstStream:
        if frame.streamId in streams:
          let state = streams[frame.streamId]
          if not state.endStream:
            await state.endInput()
          state.finished = true
      of FrameGoAway:
        break
      else:
        discard
  finally:
    for _, state in streams:
      if not state.endStream:
        try:
          await state.endInput()
        except CatchableError:
          discard
    decoder.close()

proc serveGrpc*(
    app: Application, address = "", port: uint16 = 0
): GrpcServer =
  ## Starts the installed gRPC HTTP/2 listener with configured TLS or h2c.
  app.load()
  let runtime = app.grpcRuntime()
  let selectedAddress = if address.len == 0: runtime.options.address else: address
  let selectedPort = if port == 0: runtime.options.port else: port
  let callback: StreamCallback2 = proc(
      server: StreamServer, client: StreamTransport
  ) {.async: (raises: []).} =
    discard server
    var connection: GrpcConnection
    try:
      let rawReader = newAsyncStreamReader(client)
      let rawWriter = newAsyncStreamWriter(client)
      var reader = rawReader
      var writer = rawWriter
      var secure: TLSAsyncStream
      if runtime.options.tlsEnabled():
        secure = newTLSServerAsyncStream(
          rawReader,
          rawWriter,
          runtime.options.tls.privateKey,
          runtime.options.tls.certificate,
          minVersion = TLSVersion.TLS12,
          maxVersion = TLSVersion.TLS12,
          flags = {TLSFlags.NoRenegotiation, TLSFlags.FailOnAlpnMismatch},
          alpnProtocols = ["h2"],
        )
        await secure.handshake()
        if secure.getSelectedAlpnProtocol() != "h2":
          raise newException(ValueError, "gRPC TLS client did not negotiate h2")
        reader = secure.reader
        writer = secure.writer
      connection = GrpcConnection(
        reader: reader,
        writer: writer,
        transport: client,
        tlsStream: secure,
        writeLock: newAsyncLock(),
        flowChanged: newAsyncEvent(),
        encoder: initHpackEncoder(),
        connectionWindow: 65_535,
        initialStreamWindow: 65_535,
        maxFrameSize: 16_384,
      )
      await processConnection(app, runtime, connection)
    except CancelledError:
      discard
    except CatchableError:
      discard
    finally:
      if not connection.isNil:
        connection.encoder.close()
      await client.closeWait()
  let stream = createStreamServer(
    initTAddress(selectedAddress, Port(selectedPort)), callback
  )
  stream.start()
  GrpcServer(stream: stream)

proc stopGrpc*(app: Application, server: GrpcServer) =
  ## Stops and closes a gRPC listener. Existing connections close independently.
  discard app
  if not server.stream.closed():
    server.stream.stop()
    server.stream.close()

proc join*(server: GrpcServer): Future[void] {.async: (raises: [CancelledError]).} =
  ## Waits until the gRPC listener is closed.
  await server.stream.join()
