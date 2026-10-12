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

type LoginBody = object
  username: string
  password: string

const DemoUsers = {"ada": "s3cret"}.toTable

let store = newSessionStore(defaultTtlSeconds = 3600)

let app = initFastNim()
app.install(
  authPlugin(
    initAuthOptions(
      schemes = {AuthScheme.Session},
      sessionStore = store,
      excludePaths = @["/health", "/login"],
    )
  )
)

app.get("/health"):
  text("ok")

app.post("/login"):
  var credentials: LoginBody
  if not parseJsonBody(request, credentials):
    return json(statusBadRequest, %*{"detail": "invalid JSON request body"})
  if not secureCompare(
      DemoUsers.getOrDefault(credentials.username, ""), credentials.password
  ):
    return json(statusUnauthorized, %*{"detail": "invalid credentials"})
  var response = json(%*{"ok": true})
  discard await loginSession(store, response, credentials.username)
  response

app.get("/me"):
  json(%*{"user": request.authSubject(), "scheme": request.authScheme()})

app.post("/logout"):
  var response = json(%*{"ok": true})
  await logoutSession(store, request, response)
  response

let server = app.serve(port = 8104)
echo "Session demo: POST /login, then GET /me with the cookie."
waitFor server.join()
