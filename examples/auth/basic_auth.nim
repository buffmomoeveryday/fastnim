## Run with: nim c -r --path:src examples/auth/basic_auth.nim
##
## HTTP Basic authentication. Users live in a static table here; in
## production look them up in a real credential store and verify passwords
## with a password hasher (bcrypt/argon2/scrypt), never plaintext.
##
## Try it:
##   curl http://127.0.0.1:8101/health
##   curl -u ada:s3cret http://127.0.0.1:8101/me
##   curl -u ada:wrong http://127.0.0.1:8101/me -i   # 401 + Basic challenge

import std/[json, tables]

import chronos

import fastnim
import fastnim/plugins/auth

let app = initFastNim()
app.install(
  authPlugin(
    initAuthOptions(
      schemes = {AuthScheme.Basic},
      basicUsers = {"ada": "s3cret", "linus": "torvalds"}.toTable,
      excludePaths = @["/health"],
      realm = "demo",
    )
  )
)

app.get("/health"):
  text("ok")

app.get("/me"):
  json(%*{"user": request.authSubject(), "scheme": request.authScheme()})

let server = app.serve(port = 8101)
echo "Basic auth demo: http://127.0.0.1:8101/me (try curl -u ada:s3cret ...)"
waitFor server.join()
