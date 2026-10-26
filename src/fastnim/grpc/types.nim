## Public gRPC call, status, and handler types.

import std/[options, tables, uri]

import chronos

import ../context/state
import ../grpc/protobuf

type
  GrpcStatus* {.pure.} = enum ## Standard gRPC status codes.
    Ok = 0
    Cancelled = 1
    Unknown = 2
    InvalidArgument = 3
    DeadlineExceeded = 4
    NotFound = 5
    AlreadyExists = 6
    PermissionDenied = 7
    ResourceExhausted = 8
    FailedPrecondition = 9
    Aborted = 10
    OutOfRange = 11
    Unimplemented = 12
    Internal = 13
    Unavailable = 14
    DataLoss = 15
    Unauthenticated = 16

  GrpcError* = object of CatchableError
    ## Handler error translated to gRPC status trailers.
    status*: GrpcStatus ## Status sent in the ``grpc-status`` trailer.

  GrpcCall* = object ## Metadata available to a gRPC handler.
    path*: string ## Fully qualified RPC path, such as ``/hello.Greeter/SayHello``.
    metadata*: Table[string, string] ## Request metadata with lowercase keys.
    context*: Context ## Application-scoped FastNim context.

  GrpcRawHandler* = proc(call: GrpcCall, payload: seq[byte]): Future[seq[byte]] {.
    closure, async: (raises: [CatchableError])
  .} ## Internal protobuf-bytes handler used by the transport.

  GrpcRawReceive* =
    proc(): Future[Option[seq[byte]]] {.closure, async: (raises: [CatchableError]).}
    ## Receives the next framed protobuf payload or ``none`` at end of input.

  GrpcRawSend* = proc(payload: seq[byte]): Future[void] {.
    closure, async: (raises: [CatchableError])
  .} ## Sends one framed protobuf payload.

  GrpcRawStreamHandler* = proc(
    call: GrpcCall, receive: GrpcRawReceive, send: GrpcRawSend
  ): Future[void] {.closure, async: (raises: [CatchableError]).}
    ## Handles any streaming RPC shape using raw protobuf payloads.

  GrpcStream*[Request, Response] = object
    ## Typed bidirectional message stream exposed inside streaming handlers.
    receiveRaw: GrpcRawReceive
    sendRaw: GrpcRawSend

proc newGrpcError*(status: GrpcStatus, message: string): ref GrpcError =
  ## Creates a handler error returned as gRPC trailers.
  result = newException(GrpcError, message)
  result.status = status

proc grpcError*(status: GrpcStatus, message: string): ref GrpcError {.inline.} =
  ## Creates a handler error suitable for ``raise grpcError(...)``.
  newGrpcError(status, message)

proc encodeGrpcMessage*(message: string): string =
  ## Percent-encodes a gRPC status message for the ``grpc-message`` trailer.
  encodeUrl(message, usePlus = false)

proc initGrpcStream*[Request, Response](
    receive: GrpcRawReceive, send: GrpcRawSend
): GrpcStream[Request, Response] =
  ## Creates a typed stream adapter around transport callbacks.
  GrpcStream[Request, Response](receiveRaw: receive, sendRaw: send)

proc receive*[Request, Response](
    stream: GrpcStream[Request, Response]
): Future[Option[Request]] {.async: (raises: [CatchableError]).} =
  ## Receives and decodes the next request, or returns ``none`` after client EOF.
  let payload = await stream.receiveRaw()
  if payload.isSome:
    return some(decodeProtobuf(payload.get(), Request))
  none(Request)

proc send*[Request, Response](
    stream: GrpcStream[Request, Response], message: Response
): Future[void] {.async: (raises: [CatchableError]).} =
  ## Encodes and sends one response message.
  await stream.sendRaw(encodeProtobuf(message))
