# gRPC

FastNim can serve native gRPC on its own HTTP/2 listener. The listener speaks
HTTP/2 framing, HPACK, protobuf message framing, request metadata, and standard
gRPC status trailers. Those layers are implemented in Nim. TLS, when enabled,
uses Chronos's BearSSL backend compiled into the application.

The listener is separate from `app.serve()`. Install the plugin, register each
RPC, then start it with `serveGrpc`. A complete service is in
[`examples/grpc.nim`](../examples/grpc.nim), defined by
[`examples/hello.proto`](../examples/hello.proto).

Import the plugin with:

```nim
import chronos
import fastnim
import fastnim/plugins/grpc
```

`import fastnim/plugins` re-exports the same API.

## Service definition

[`examples/hello.proto`](../examples/hello.proto) declares one service and the
four RPC shapes:

```protobuf
syntax = "proto3";

package hello;

service Greeter {
  rpc SayHello(HelloRequest) returns (HelloReply);
  rpc SayHelloManyTimes(HelloRequest) returns (stream HelloReply);
  rpc CollectHello(stream HelloRequest) returns (HelloReply);
  rpc Chat(stream HelloRequest) returns (stream HelloReply);
}

message HelloRequest {
  string name = 1;
}

message HelloReply {
  string message = 1;
}
```

The route path is `/package.Service/Method`. For this file that is
`/hello.Greeter/SayHello` and the other three methods. A path must contain
exactly two slashes. Registering the same path twice raises `ValueError`.

Model the messages as Nim objects. Field names match after underscores are
removed and case is ignored, so protobuf `display_name` matches Nim
`displayName`. Field numbers in the `.proto` file must be `1`, `2`, `3`, and
so on, in the same order as the Nim fields. The built-in codec uses that
declaration order as the protobuf field number.

```nim
type
  HelloRequest = object
    name: string

  HelloReply = object
    message: string
```

Integer fields use the matching fixed-width Nim type, so a protobuf `int32`
field is a Nim `int32`.

| Protobuf type | Nim field type |
| --- | --- |
| `double` | `float64` |
| `float` | `float32` |
| `int32` | `int32` |
| `int64` | `int64` |
| `uint32` | `uint32` |
| `uint64` | `uint64` |
| `bool` | `bool` |
| `string` | `string` |
| `bytes` | `seq[byte]` |
| `repeated T` | `seq[T]` |
| message type | object whose type name is the message's bare name |
| enum type | enum whose type name is the enum's bare name |

`sint32`, `sint64`, `fixed32`, `fixed64`, `sfixed32`, `sfixed64`, and `map`
fields are rejected at compile time. `import` statements are skipped, so every
message the route uses must be declared in the file passed as `proto`. Nested
`message`, `enum`, `oneof`, `reserved`, `extensions`, and `option` declarations
inside a message are skipped and are not part of the checked field list.
Enum value lists are not compared; an enum is encoded and decoded as its
ordinal.

Each route passes `proto`, `request`, and `responses` (`response` is accepted
as an alias). `proto` is a compile-time string literal or `const`. A relative
path is resolved from the Nim file that contains the route. FastNim reads the
file during compilation and rejects the route when any of these differ from
the schema:

- the RPC path;
- whether the request or response is streaming;
- the request or response type name;
- the number, order, names, or types of message fields.

## Unary RPCs

Install the plugin before registering routes. `grpcPlugin()` listens on
`127.0.0.1:50051` until you pass other options.

```nim
let app = initFastNim()
app.installPlugin(grpcPlugin())

app.grpc(
  "/hello.Greeter/SayHello",
  proto = "hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  if request.name.len == 0:
    raise grpcError(GrpcStatus.InvalidArgument, "name is required")
  return HelloReply(message: "Hello, " & request.name)

when isMainModule:
  waitFor app.serveGrpc().join()
```

Inside a unary handler, `request` is the decoded request model. The final
expression, or an explicit `return`, must be the response type. `call` is the
`GrpcCall` for this RPC. A unary call must carry exactly one request message.
Zero messages, or more than one, finish the call with `InvalidArgument`.

Run the example with:

```sh
nim c -r examples/grpc.nim
```

It prints `running at 127.0.0.1:50051` and serves all four methods from
`examples/hello.proto`. From another shell, `grpcurl` can call the unary
method over cleartext HTTP/2:

```sh
grpcurl -plaintext -proto examples/hello.proto \
  -d '{"name":"Ada"}' 127.0.0.1:50051 hello.Greeter/SayHello
```

An empty `name` returns gRPC status `3` (`InvalidArgument`) with the message
`name is required`.

## Server streaming

`grpcServerStream` decodes one request, then the handler sends any number of
responses with `await stream.send(...)`. Sending nothing is valid and still
completes with status `Ok`.

```nim
app.grpcServerStream(
  "/hello.Greeter/SayHelloManyTimes",
  proto = "hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  for index in 1 .. 3:
    await stream.send(HelloReply(message: "Hello, " & request.name & " #" & $index))
```

`request` is that single decoded message. A second request message finishes
the call with `InvalidArgument`.

```sh
grpcurl -plaintext -proto examples/hello.proto \
  -d '{"name":"Ada"}' 127.0.0.1:50051 hello.Greeter/SayHelloManyTimes
```

## Client streaming

`grpcClientStream` exposes `stream` and no single `request` value. `await
stream.receive()` returns `Option[Request]`: `some` for each message, and
`none` after the client half-closes the stream. The handler's final expression
is the one response. The registration macro encodes that value and writes it
once.

```nim
app.grpcClientStream(
  "/hello.Greeter/CollectHello",
  proto = "hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  var names: seq[string]
  while true:
    let request = await stream.receive()
    if request.isNone:
      break
    names.add(request.get().name)
  HelloReply(message: names.join(", "))
```

```sh
grpcurl -plaintext -proto examples/hello.proto \
  -d '{"name":"Ada"}' -d '{"name":"Grace"}' \
  127.0.0.1:50051 hello.Greeter/CollectHello
```

## Bidirectional streaming

`grpcStream` is the short name for `grpcBidirectionalStream`. Receive and send
may be interleaved. `receive` returns `none` when the client closes its side.
The handler does not need a final response expression.

```nim
app.grpcStream(
  "/hello.Greeter/Chat",
  proto = "hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  while true:
    let request = await stream.receive()
    if request.isNone:
      break
    await stream.send(HelloReply(message: "Hello, " & request.get().name))
```

```sh
grpcurl -plaintext -proto examples/hello.proto \
  -d '{"name":"Ada"}' -d '{"name":"Grace"}' \
  127.0.0.1:50051 hello.Greeter/Chat
```

| Macro | Request | Response |
| --- | --- | --- |
| `grpc` | one `request` value | final expression or `return` |
| `grpcServerStream` | one `request` value | `await stream.send(response)` any number of times |
| `grpcClientStream` | `await stream.receive()` until `none` | final expression, sent once |
| `grpcStream` | `await stream.receive()` until `none` | `await stream.send(response)` any number of times |

Handlers run on the Chronos event loop. Await Chronos operations inside them.
A blocking call stalls every RPC sharing that thread.

## Status and failures

Raise `grpcError(status, message)` to finish a call with a specific status.
The status number is written to the `grpc-status` trailer and the message is
percent-encoded into `grpc-message`.

```nim
raise grpcError(GrpcStatus.NotFound, "greeting is not registered")
```

`newGrpcError` returns the same `ref GrpcError` when the caller needs to store
it before raising.

| Failure | Trailer status | Trailer message |
| --- | --- | --- |
| `raise grpcError(status, message)` | the given status | `message` |
| Malformed protobuf, a truncated frame, or a compressed message | `InvalidArgument` | the decode error |
| Request larger than `maxMessageSize` | `InvalidArgument` | `gRPC message exceeds configured limit` |
| Response larger than `maxMessageSize` | `ResourceExhausted` | `gRPC response exceeds configured limit` |
| Unknown RPC path | `Unimplemented` | `method not found` |
| Method other than `POST`, or a content type other than `application/grpc` | `Internal` | `invalid gRPC request headers` |
| Any other `CatchableError` | `Internal` | `internal server error` |

The numeric codes are the standard gRPC values:

| `GrpcStatus` | Code |
| --- | --- |
| `Ok` | 0 |
| `Cancelled` | 1 |
| `Unknown` | 2 |
| `InvalidArgument` | 3 |
| `DeadlineExceeded` | 4 |
| `NotFound` | 5 |
| `AlreadyExists` | 6 |
| `PermissionDenied` | 7 |
| `ResourceExhausted` | 8 |
| `FailedPrecondition` | 9 |
| `Aborted` | 10 |
| `OutOfRange` | 11 |
| `Unimplemented` | 12 |
| `Internal` | 13 |
| `Unavailable` | 14 |
| `DataLoss` | 15 |
| `Unauthenticated` | 16 |

Successful calls send `grpc-status: 0` after the response messages. Response
headers use `:status: 200`, `content-type: application/grpc`, and
`grpc-encoding: identity`. The listener accepts identity encoding. A compressed
message flag is rejected.

## Metadata and application context

`call` is available in every handler:

```nim
app.grpc(
  "/hello.Greeter/SayHello",
  proto = "hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  let authorization = call.metadata.getOrDefault("authorization")
  let database = call.context.get("database", Database)
  HelloReply(message: request.name & " via " & authorization)
```

`call.path` is the RPC path, such as `/hello.Greeter/SayHello`.
`call.metadata` is the request header table. Keys are lowercase and include
HTTP/2 pseudo-headers (`:path`, `:method`, `:scheme`, `:authority`) together
with gRPC metadata such as `authorization`. `call.context` is the application
`Context`, so values stored with `setContext` before the listener starts are
visible here. `serveGrpc` loads the application, which runs lifecycle hooks,
before it accepts connections.

## Protobuf codec

`encodeProtobuf` and `decodeProtobuf` convert between Nim objects and protobuf
bytes. Route handlers use them automatically. Zero numbers, `false`, empty
strings, empty byte sequences, and empty nested objects are omitted on encode,
matching proto3. Missing fields decode as the Nim default. Unknown field
numbers are skipped. Repeated scalars accept packed and unpacked form.

Enums use their ordinal as a varint. Nested objects are length-delimited
submessages. A route checks the request and response messages directly. A
nested object is checked by type name at the field where it appears; its own
fields are checked when that nested message is itself a route request or
response type.

A more specific `encodeProtobuf` and typedesc `decodeProtobuf` overload in the
application module replaces the built-in codec for that message type. The
route checker still requires the `.proto` field numbers to be sequential from
`1`.

`ProtobufError` is the decode failure type. The listener turns it into
`InvalidArgument`.

## Listener options

```nim
let app = initFastNim()
app.installPlugin(grpcPlugin(initGrpcOptions(
  address = "0.0.0.0",
  port = 50051,
  maxMessageSize = 4 * 1024 * 1024,
)))

let server = app.serveGrpc()
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `address` | `127.0.0.1` | Bind address. An empty address raises `ValueError`. |
| `port` | `50051` | TCP port. |
| `maxMessageSize` | 4 MiB | Largest accepted protobuf payload, before gRPC framing. Must be positive. |
| `tls` | none | Empty selects cleartext HTTP/2 (h2c). |

`serveGrpc(address, port)` overrides the plugin address when `address` is
non-empty, and the plugin port when `port` is non-zero. `stopGrpc` stops the
listener. Connections already accepted close on their own. `join` waits until
the listener is closed:

```nim
app.stopGrpc(server)
waitFor server.join()
```

## TLS

Pass PEM material to terminate TLS in the listener. The certificate is a PEM
chain. The key is an unencrypted PKCS#8 PEM private key. Both values are
required.

```nim
let tls = initGrpcTlsConfig(
  readFile("certs/server-cert.pem"),
  readFile("certs/server-key.pem"),
)
app.installPlugin(grpcPlugin(initGrpcOptions(
  address = "0.0.0.0",
  port = 443,
  tls = tls,
)))
waitFor app.serveGrpc().join()
```

The handshake allows TLS 1.2 and requires ALPN protocol `h2`. A client that
does not negotiate `h2` is disconnected. BearSSL is linked into the binary;
the listener does not load OpenSSL (`libssl` or `libcrypto`) at runtime.

With a certificate configured, point `grpcurl` at the listener with `-proto`
and the certificate flags your deployment needs, and omit `-plaintext`.
