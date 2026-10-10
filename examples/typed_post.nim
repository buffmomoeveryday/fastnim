import strutils
import fastnim
import tables

import fastnim/plugins/ratelimit

proc addResponseHeadersMiddleware(request: Request, next: NextHandler): Response =
  var response = next request
  response.setHeader("x-powered-by", "fastnim")
  response


type
  CreateUser = object
    name: string
    email: string

  User = object
    id: int
    name: string
    email: string

  ApiError = object
    detail: string

var users: seq[User] = @[]



let app = initFastNim()

app.install:
  rateLimitPlugin(initRateLimitOptions(limit = 5, windowSeconds = 60))


app.middlewares:
  addResponseHeadersMiddleware


app.delete(
  "/users/{id}",
  responses = @[(204, void), (404, ApiError)],
  tags = @["users"],
  summary = "Delete a user",
  description = "Deletes a user by ID.",
  operationId = "deleteUser",
):
  let id = request.pathParams["id"].parseInt()
  var index = -1

  for position, user in users:
    if user.id == id:
      index = position
      break

  if index == -1:
    notFound ApiError(detail: "User not found")
  else:
    users.del index
    noContent void



app.get(
  "/users",
  responses = @[(200, seq[User])],
  tags = @["users"],
  summary = "Get all users",
  description = "Returns a list of all users.",
  operationId = "getUsers",
):
  ok users




app.post(
  "/users",
  body = CreateUser,
  responses = @[(201, User), (400, ApiError)],
  tags = @["users"],
  summary = "Create a user",
  description = "Creates a user from a validated JSON request body.",
  operationId = "createUser",
):
  if body.name.len == 0:
    badRequest ApiError(detail: "name is required")
  else:
    {.gcsafe.}:
      var user = User(id: users.len + 1, name: body.name, email: body.email)
      users.add user
    created user



let clients = newWebSocketGroup()
app.websocket("/chat"):
  await websocket.accept()
  {.gcsafe.}:
    clients.addWebSocket(websocket)
  try:
    while true:
      let message = await websocket.receiveText()
      {.gcsafe.}:
        discard await clients.broadcastText(message)
  finally:
    {.gcsafe.}:
      discard clients.removeWebSocket(websocket)




when isMainModule:
  waitFor app.serve(port = 8000).join()
