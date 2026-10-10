## Run with: nim c -r --path:src examples/html.nim
## Serves plain HTML pages with the ``html`` response helper.

import chronos
import fastnim

proc layout(title, body: string): string =
  """<!doctype html>
<html>
<head><title>""" & title & """</title></head>
<body>""" & body & """</body>
</html>"""

let api = initFastNim()


api.get("/"):
  html layout("Home", "<h1>Hello from FastNim</h1>")


api.get("/users/{name}"):
  let name = request.pathParam("name")
  html layout("User", "<h1>Hello, " & name & "</h1>")

############################# 
############################# 

let userRouter = initRouter()


type User = object
  name: string
  age: int

userRouter.get("/list",responses = @[(200,seq[User])]):
  let users = @[User(name: "Alice", age: 30), User(name: "Bob", age: 25)]
  json users


############################# 
############################# 

api.addRouter(prefix = "/user", router = userRouter, tags= @["users"])

let server = api.serve(port = 8090)
echo "Listening at http://127.0.0.1:8090"
waitFor server.join()
