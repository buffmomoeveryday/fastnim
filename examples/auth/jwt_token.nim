## Run with: nim c -r --path:src examples/auth/jwt_token.nim
##
## HS256 JWT authentication. POST /login with a username and password to
## receive a token, then present it as `Authorization: Bearer <token>`.
##
## WARNING: the signing secret below is hard-coded for the demo only. Load
## secrets from the environment in production, keep token lifetimes short,
## and rotate secrets (list several in `jwtSecrets`: old tokens keep working
## until you remove their secret).
##
## Try it:
##   curl -X POST -H 'Content-Type: application/json' \
##     -d '{"username":"ada","password":"s3cret"}' http://127.0.0.1:8103/login
##   TOKEN=<token from above>
##   curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8103/me
##   curl http://127.0.0.1:8103/me -i   # 401

import std/[json, tables]

import chronos

import fastnim
import fastnim/plugins/auth

const DemoJwtSecret = "change-me-in-production-min-32-bytes!!"

type LoginBody = object
  username: string
  password: string

type TokenResponse = object
  token: string
  expiresIn: int

const DemoUsers = {"ada": "s3cret"}.toTable
const TokenTtlSeconds = 3600

let app = initFastNim()
app.installPlugin(
  authPlugin(
    initAuthOptions(
      schemes = {AuthScheme.Jwt},
      jwtSecrets = @[DemoJwtSecret],
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
  let token = issueJwtHs256(credentials.username, DemoJwtSecret, TokenTtlSeconds)
  json(%*{"token": token, "expiresIn": TokenTtlSeconds})

app.get("/me"):
  json(%*{"user": request.authSubject(), "scheme": request.authScheme()})

let server = app.serve(port = 8103)
echo "JWT demo: POST /login, then GET /me with the token."
waitFor server.join()
