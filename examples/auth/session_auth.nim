## Run with: nim c -r --path:src examples/auth/session_auth.nim
##
## Cookie session authentication. POST /login with a username and password to
## receive an HttpOnly session cookie; the server keeps the session itself,
## so nothing sensitive ever leaves it. POST /logout destroys the session.
##
## Try it (cookies persist with -c/-b):
##   curl -c jar -X POST -H 'Content-Type: application/json' \
##     -d '{"username":"ada","password":"s3cret"}' http://127.0.0.1:8104/login
##   curl -b jar http://127.0.0.1:8104/me
##   curl -b jar -X POST http://127.0.0.1:8104/logout
##   curl -b jar http://127.0.0.1:8104/me -i   # 401 after logout

import std/[json, tables]

import chronos

import fastnim
import fastnim/plugins/auth

const DemoUsers = {"ada": "s3cret"}.toTable

let store = newSessionStore(defaultTtlSeconds = 3600)

let app = initFastNim()
app.install(
  authPlugin(
    initAuthOptions(
      schemes = {AuthScheme.Session},
      sessionStore = store,
      excludePaths = @["/health", "/login","/docs","/openapi.json"],
    )
  )
)



type
  LoginBody = object
    username: string
    password: string

  ValueKind = enum
    vkBool,
    vkString

  Message = object
    status: string
    case value:ValueKind
    of vkBool:
      boolVal: bool
    of vkString:
      strVal:string


app.get("/health"):
  return ok text("ok")

app.post("/login",body=LoginBody,responses= @[(200,Message),(401,Message)]):
  if not secureCompare(
    DemoUsers.getOrDefault(body.username, ""), body.password
  ):
    return unauthorized Message(status:"detail",value:vkString,strVal:"Invalid credential")

  var response = ok Message(status:"ok",value:vkBool, boolVal:true)
  var cookie = await loginSession(store, response, body.username)
  echo $cookie
  return response

app.get("/me"):
  return ok json(%*{"user": request.authSubject(), "scheme": request.authScheme()})

app.post("/logout",responses = @[(200,Message)]):
  var response = ok Message(status:"ok",value:vkBool, boolVal:true)
  await logoutSession(store, request, response)
  return response

let server = app.serve(port = 8104)
echo "Session demo: POST /login, then GET /me with the cookie."
waitFor server.join()
