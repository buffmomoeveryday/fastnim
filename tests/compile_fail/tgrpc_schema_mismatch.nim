import fastnim

type
  HelloRequest = object
    name: string
    world: string

  HelloReply = object
    message: string

let app = initFastNim(logs = false)
app.install(grpcPlugin())

app.grpc(
  "/hello.Greeter/SayHello",
  proto = "../../examples/hello.proto",
  request = HelloRequest,
  responses = HelloReply,
):
  HelloReply(message: request.name)
