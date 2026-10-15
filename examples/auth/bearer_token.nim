## Run with: nim c -r --path:src examples/auth/bearer_token.nim
##
## Opaque bearer tokens and API keys. Both map static secrets to subjects;
## for database/HMAC-backed lookups, use the exported schemes primitives
## (`bearerToken`, `apiKey`, `lookupSubject`, `secureCompare`) inside your own
## middleware instead of the static tables.
##
## Try it:
##   curl -H "Authorization: Bearer tok-ada-1" http://127.0.0.1:8102/me
##   curl -H "X-API-Key: key-svc-1" http://127.0.0.1:8102/me
##   curl "http://127.0.0.1:8102/me?api_key=key-svc-1"
##   curl http://127.0.0.1:8102/me -i   # 401 + Bearer challenge

import std/[json, tables]

import chronos

import fastnim
import fastnim/plugins/auth

let app = initFastNim()
app.installPlugin(
  authPlugin(
    initAuthOptions(
      schemes = {AuthScheme.Bearer, AuthScheme.ApiKey},
      bearerTokens = {"tok-ada-1": "ada"}.toTable,
      apiKeys = {"key-svc-1": "billing-service"}.toTable,
      apiKeyQuery = "api_key",
      excludePaths = @["/health"],
    )
  )
)

app.get("/health"):
  text("ok")

app.get("/me"):
  json(%*{"user": request.authSubject(), "scheme": request.authScheme()})

let server = app.serve(port = 8102)
echo "Bearer/API-key demo: http://127.0.0.1:8102/me"
waitFor server.join()
