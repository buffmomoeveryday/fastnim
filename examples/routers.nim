## Run with: nim c -r --path:src examples/routers.nim
## Groups endpoints with ``newRouter`` and mounts them via ``app.addRouter``.

import std/json

import fastnim

type
  CreateUser = object
    name: string

  User = object
    id: int
    name: string

proc requireAuth(request: Request, next: NextHandler): Response =
  if request.header("authorization") == "":
    return json("""{"detail":"missing credentials"}""", 401)
  next(request)

let userRouter = initRouter(prefix = "/users", tags = @["users"])

userRouter.get("/{id}"):
  %*{"id": request.pathParam("id")}

userRouter.post("/", body = CreateUser, responses = @[(201, User)]):
  created User(id: 1, name: body.name)

let adminRouter = initRouter(prefix = "/admin", tags = @["admin"])
adminRouter.use(requireAuth)

adminRouter.get("/stats"):
  %*{"uptime": "ok"}

let app = initFastNim()
app.addRouter(userRouter, prefix = "/v1")
app.addRouter(adminRouter, prefix = "/v1")

let server = app.serve(port = 8090)
echo "Listening at http://127.0.0.1:8090"
waitFor server.join()
