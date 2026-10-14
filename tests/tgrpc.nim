import std/[assertions, options, strutils]

import chronos
import chronos/streams/[asyncstream, tlsstream]

import fastnim
import fastnim/grpc/hpack
import fastnim/plugins/grpc

type
  HelloRequest = object
    name: string
    count: int32

  HelloReply = object
    message: string

proc addUint32(output: var seq[byte], value: uint32) =
  output.add(byte(value shr 24))
  output.add(byte(value shr 16))
  output.add(byte(value shr 8))
  output.add(byte(value))

proc frame(kind, flags: byte, streamId: int32, payload: seq[byte]): seq[byte] =
  result = @[
    byte(payload.len shr 16), byte(payload.len shr 8), byte(payload.len),
    kind, flags,
  ]
  result.addUint32(uint32(streamId))
  result.add(payload)

proc readExact(client: StreamTransport, length: int): Future[seq[byte]] {.async.} =
  result = newSeq[byte](length)
  var position = 0
  while position < length:
    let count = await client.readOnce(addr result[position], length - position)
    doAssert count > 0
    position += count

proc readFrame(
    client: StreamTransport
): Future[tuple[kind, flags: byte, streamId: int32, payload: seq[byte]]] {.async.} =
  let header = await client.readExact(9)
  let length =
    (int(header[0]) shl 16) or (int(header[1]) shl 8) or int(header[2])
  result.kind = header[3]
  result.flags = header[4]
  result.streamId =
    int32((uint32(header[5]) shl 24) or (uint32(header[6]) shl 16) or
      (uint32(header[7]) shl 8) or uint32(header[8]))
  result.payload = await client.readExact(length)

proc readFrame(
    reader: AsyncStreamReader
): Future[tuple[kind, flags: byte, streamId: int32, payload: seq[byte]]] {.async.} =
  let header = await reader.read(9)
  let length =
    (int(header[0]) shl 16) or (int(header[1]) shl 8) or int(header[2])
  result.kind = header[3]
  result.flags = header[4]
  result.streamId =
    int32((uint32(header[5]) shl 24) or (uint32(header[6]) shl 16) or
      (uint32(header[7]) shl 8) or uint32(header[8]))
  result.payload = if length == 0: @[] else: await reader.read(length)

proc grpcMessages(data: var seq[byte]): seq[seq[byte]] =
  while data.len >= 5:
    doAssert data[0] == 0
    let length =
      (int(data[1]) shl 24) or (int(data[2]) shl 16) or
      (int(data[3]) shl 8) or int(data[4])
    if data.len < length + 5:
      break
    result.add(if length == 0: @[] else: data[5 ..< length + 5])
    if data.len == length + 5:
      data.setLen(0)
    else:
      data = data[length + 5 .. ^1]

proc grpcExchange(
    client: StreamTransport, path, authority: string, streamId: int32,
    requests: seq[seq[byte]],
): Future[tuple[responses: seq[seq[byte]], status: string]] {.async.} =
  var encoder = initHpackEncoder()
  var decoder = initHpackDecoder()
  try:
    let headers = encoder.encode([
      (":method", "POST"),
      (":scheme", "http"),
      (":path", path),
      (":authority", authority),
      ("content-type", "application/grpc"),
      ("te", "trailers"),
    ])
    discard await client.write(frame(1, 4, streamId, headers))
    var body: seq[byte]
    for request in requests:
      body.add(0'u8)
      body.addUint32(uint32(request.len))
      body.add(request)
    discard await client.write(frame(0, 1, streamId, body))

    var responseBody: seq[byte]
    while result.status.len == 0:
      let incoming = await client.readFrame()
      if incoming.streamId != streamId:
        continue
      case incoming.kind
      of 0:
        responseBody.add(incoming.payload)
        result.responses.add(responseBody.grpcMessages())
        if incoming.payload.len > 0:
          var increment: seq[byte]
          increment.addUint32(uint32(incoming.payload.len))
          discard await client.write(frame(8, 0, 0, increment))
          discard await client.write(frame(8, 0, streamId, increment))
      of 1:
        let decoded = decoder.decode(incoming.payload)
        if "grpc-status" in decoded:
          result.status = decoded["grpc-status"]
      else:
        discard
    doAssert responseBody.len == 0
  finally:
    encoder.close()
    decoder.close()

block protobufRoundTrip:
  let original = HelloRequest(name: "Ada", count: 3)
  let encoded = encodeProtobuf(original)
  doAssert encoded == @[0x0a'u8, 0x03, 0x41, 0x64, 0x61, 0x10, 0x03]
  doAssert decodeProtobuf(encoded, HelloRequest) == original

block rejectsInvalidPluginSettings:
  doAssertRaises ValueError:
    discard initGrpcOptions(maxMessageSize = 0)

block decodesRfcHuffmanHeadersWithoutNativeLibraries:
  var decoder = initHpackDecoder()
  let fields = decoder.decode(@[
    0x82'u8, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5,
    0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
  ])
  doAssert fields[":method"] == "GET"
  doAssert fields[":scheme"] == "http"
  doAssert fields[":path"] == "/"
  doAssert fields[":authority"] == "www.example.com"

block rejectsHpackHuffmanEosAsHeaderData:
  var decoder = initHpackDecoder()
  doAssertRaises ValueError:
    discard decoder.decode(@[0'u8, 0x84, 0xff, 0xff, 0xff, 0xff, 0'u8])

proc grpcClientExchange() {.async.} =
  let client = await connect(initTAddress("127.0.0.1", Port(50186)))
  try:
    discard await client.write("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    discard await client.write(frame(4, 0, 0, @[]))
    let settings = await client.readFrame()
    doAssert settings.kind == 4

    let unary = await client.grpcExchange(
      "/hello.Greeter/SayHello", "127.0.0.1:50186", 1,
      @[encodeProtobuf(HelloRequest(name: "Nim", count: 2))],
    )
    doAssert unary.status == "0"
    doAssert unary.responses.len == 1
    doAssert decodeProtobuf(unary.responses[0], HelloReply).message ==
      "Hello Nim Nim"

    let serverStream = await client.grpcExchange(
      "/hello.Greeter/ListHello", "127.0.0.1:50186", 3,
      @[encodeProtobuf(HelloRequest(name: "Ada", count: 3))],
    )
    doAssert serverStream.status == "0"
    doAssert serverStream.responses.len == 3
    doAssert decodeProtobuf(serverStream.responses[2], HelloReply).message ==
      "Hello Ada 2"

    let largeStream = await client.grpcExchange(
      "/hello.Greeter/ListHello", "127.0.0.1:50186", 5,
      @[encodeProtobuf(HelloRequest(name: "large", count: 1))],
    )
    doAssert largeStream.status == "0"
    doAssert decodeProtobuf(largeStream.responses[0], HelloReply).message.len ==
      100_000

    let clientStream = await client.grpcExchange(
      "/hello.Greeter/CollectHello", "127.0.0.1:50186", 7,
      @[
        encodeProtobuf(HelloRequest(name: "one", count: 1)),
        encodeProtobuf(HelloRequest(name: "two", count: 1)),
      ],
    )
    doAssert clientStream.status == "0"
    doAssert decodeProtobuf(clientStream.responses[0], HelloReply).message ==
      "one,two"

    let bidi = await client.grpcExchange(
      "/hello.Greeter/ChatHello", "127.0.0.1:50186", 9,
      @[
        encodeProtobuf(HelloRequest(name: "left", count: 1)),
        encodeProtobuf(HelloRequest(name: "right", count: 1)),
      ],
    )
    doAssert bidi.status == "0"
    doAssert bidi.responses.len == 2
    doAssert decodeProtobuf(bidi.responses[1], HelloReply).message == "right"

    let invalid = await client.grpcExchange(
      "/hello.Greeter/SayHello", "127.0.0.1:50186", 11,
      @[@[0x0a'u8]],
    )
    doAssert invalid.status == $ord(GrpcStatus.InvalidArgument)
  finally:
    await client.closeWait()

block exchangesUnaryGrpcOverHttp2:
  let app = initFastNim(logs = false)
  app.install(grpcPlugin(initGrpcOptions(port = 50186)))
  app.grpc(
    "/hello.Greeter/SayHello",
    proto = "fixtures/grpc.proto",
    request = HelloRequest,
    responses = HelloReply,
  ):
    HelloReply(message: "Hello " & request.name & " " & request.name)

  app.grpcServerStream(
    "/hello.Greeter/ListHello",
    proto = "fixtures/grpc.proto",
    request = HelloRequest,
    responses = HelloReply,
  ):
    if request.name == "large":
      await stream.send(HelloReply(message: repeat('x', 100_000)))
    else:
      for index in 0 ..< request.count:
        await stream.send(
          HelloReply(message: "Hello " & request.name & " " & $index)
        )

  app.grpcClientStream(
    "/hello.Greeter/CollectHello",
    proto = "fixtures/grpc.proto",
    request = HelloRequest,
    responses = HelloReply,
  ):
    var names: seq[string]
    while true:
      let item = await stream.receive()
      if item.isNone:
        break
      names.add(item.get().name)
    HelloReply(message: names.join(","))

  app.grpcStream(
    "/hello.Greeter/ChatHello",
    proto = "fixtures/grpc.proto",
    request = HelloRequest,
    responses = HelloReply,
  ):
    while true:
      let item = await stream.receive()
      if item.isNone:
        break
      await stream.send(HelloReply(message: item.get().name))

  let server = app.serveGrpc()
  try:
    waitFor grpcClientExchange()
  finally:
    app.stopGrpc(server)
    waitFor server.join()

proc tlsHandshake(port: uint16) {.async.} =
  let transport = await connect(initTAddress("127.0.0.1", Port(port)))
  let secure = newTLSClientAsyncStream(
    newAsyncStreamReader(transport),
    newAsyncStreamWriter(transport),
    "",
    flags = {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
    alpnProtocols = ["h2"],
  )
  try:
    await secure.handshake()
    doAssert secure.getSelectedAlpnProtocol() == "h2"
    await secure.writer.write("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    await secure.writer.write(frame(4, 0, 0, @[]))
    let settings = await secure.reader.readFrame()
    doAssert settings.kind == 4
  finally:
    await transport.closeWait()

block terminatesTlsAndNegotiatesHttp2:
  const
    certificatePem = staticRead("fixtures/grpc-cert.pem")
    privateKeyPem = staticRead("fixtures/grpc-key.pem")
  let app = initFastNim(logs = false)
  let tls = initGrpcTlsConfig(certificatePem, privateKeyPem)
  app.install(grpcPlugin(initGrpcOptions(port = 50187, tls = tls)))
  let server = app.serveGrpc()
  try:
    waitFor tlsHandshake(50187)
  finally:
    app.stopGrpc(server)
    waitFor server.join()
