import std/options

import chronos

import fastnim
import fastnim/plugins/grpc

type
  HelloRequest = object
    name: string

  HelloReply = object
    message: string

let grpcApp = initFastNim()
grpcApp.installPlugin(grpcPlugin())

grpcApp.grpc(
  "/hello.Greeter/SayHello",
  proto = "hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  if request.name.len == 0:
    raise grpcError(GrpcStatus.InvalidArgument, "name is required")
  return HelloReply(message: "Hello, " & request.name)

grpcApp.grpcServerStream(
  "/hello.Greeter/SayHelloManyTimes",
  proto = "hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  for index in 1 .. 3:
    await stream.send(HelloReply(message: "Hello, " & request.name & " #" & $index))

grpcApp.grpcStream(
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

when isMainModule:
  echo "running at 127.0.0.1:50051"
  waitFor grpcApp.serveGrpc().join()
