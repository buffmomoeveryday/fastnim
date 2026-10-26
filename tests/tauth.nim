import std/[assertions, base64, json, strutils, tables, times]

import fastnim
import fastnim/plugins/auth
import nimcrypto/[hmac, sha2]

proc bearerHeaders(token: string): Headers =
  result = initTable[string, string]()
  result["authorization"] = "Bearer " & token

proc basicHeaders(user, password: string): Headers =
  result = initTable[string, string]()
  result["authorization"] = "Basic " & encode(user & ":" & password)

proc apiKeyHeaders(key: string): Headers =
  result = initTable[string, string]()
  result["x-api-key"] = key

proc sessionHeaders(id: string): Headers =
  result = initTable[string, string]()
  result["cookie"] = "session_id=" & id & "; theme=dark"

proc basicOptions(): AuthOptions =
  initAuthOptions(
    schemes = {AuthScheme.Basic},
    basicUsers = {"ada": "correct horse", "linus": "torvalds"}.toTable,
    excludePaths = @["/health"],
  )

block secureCompareBasics:
  doAssert secureCompare("abc", "abc")
  doAssert secureCompare("", "")
  doAssert not secureCompare("abc", "abd")
  doAssert not secureCompare("abc", "abcd")
  doAssert not secureCompare("", "a")

block matchPatterns:
  doAssert matchPattern("/health", "/health")
  doAssert not matchPattern("/health", "/healthz")
  doAssert matchPattern("/users/{id}", "/users/42")
  doAssert not matchPattern("/users/{id}", "/users")
  doAssert not matchPattern("/users/{id}", "/users/42/posts")
  doAssert matchPattern("/static/*", "/static/app.js")
  doAssert matchPattern("/static/*", "/static/a/b/c.css")
  doAssert matchPattern("/static/*", "/static")
  doAssert matchPattern("*", "/anything/at/all")
  doAssert not matchPattern("", "/health")
  doAssert matchPattern("/", "/")

block protectionPrecedence:
  doAssert isProtected("/users/1", @["/users/{id}"], @[])
  doAssert not isProtected("/health", @["/*"], @["/health"])
  doAssert isProtected("/anything", [], [])
  doAssert not isProtected("/public/x", @["/api/*"], @["/public/*"])

block bearerAcceptsKnownTokens:
  let app = initFastNim(logs = false)
  app.installPlugin(
    authPlugin(
      initAuthOptions(
        schemes = {AuthScheme.Bearer}, bearerTokens = {"tok-1": "ada"}.toTable
      )
    )
  )
  app.get("/me"):
    json(%*{"user": request.authSubject(), "scheme": request.authScheme()})
  let response =
    app.handleSync(initRequest(HttpMethod.Get, "/me", bearerHeaders("tok-1")))
  doAssert response.status == 200
  doAssert response.body == "{\"user\":\"ada\",\"scheme\":\"bearer\"}"

block bearerRejectsUnknownAndMissing:
  let app = initFastNim(logs = false)
  app.installPlugin(
    authPlugin(
      initAuthOptions(
        schemes = {AuthScheme.Bearer}, bearerTokens = {"tok-1": "ada"}.toTable
      )
    )
  )
  app.get("/me"):
    text("unreachable")
  let wrong = app.handleSync(initRequest(HttpMethod.Get, "/me", bearerHeaders("nope")))
  doAssert wrong.status == 401
  doAssert "Bearer" in wrong.headers.getOrDefault("www-authenticate", "")
  doAssert wrong.headers["content-type"] == "application/json; charset=utf-8"
  let missing = app.handleSync(initRequest(HttpMethod.Get, "/me"))
  doAssert missing.status == 401
  doAssert parseJson(missing.body)["message"].getStr() == "authentication required"
  doAssert parseJson(wrong.body)["message"].getStr() == "invalid credentials"

block identityHeadersCannotBeSpoofed:
  let app = initFastNim(logs = false)
  app.installPlugin(
    authPlugin(
      initAuthOptions(
        schemes = {AuthScheme.Bearer}, bearerTokens = {"tok-1": "ada"}.toTable
      )
    )
  )
  app.get("/me"):
    text(request.authSubject())
  var headers = bearerHeaders("nope")
  headers["x-auth-subject"] = "root"
  let response = app.handleSync(initRequest(HttpMethod.Get, "/me", headers))
  doAssert response.status == 401

block basicAcceptsUsers:
  let app = initFastNim(logs = false)
  app.installPlugin(authPlugin(basicOptions()))
  app.get("/me"):
    text(request.authSubject())
  let response = app.handleSync(
    initRequest(HttpMethod.Get, "/me", basicHeaders("ada", "correct horse"))
  )
  doAssert response.status == 200
  doAssert response.body == "ada"

block basicRejectsWrongPassword:
  let app = initFastNim(logs = false)
  app.installPlugin(authPlugin(basicOptions()))
  app.get("/me"):
    text("unreachable")
  let wrong =
    app.handleSync(initRequest(HttpMethod.Get, "/me", basicHeaders("ada", "wrong")))
  doAssert wrong.status == 401
  doAssert "Basic" in wrong.headers.getOrDefault("www-authenticate", "")
  var malformed = initTable[string, string]()
  malformed["authorization"] = "Basic !!!not-base64!!!"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me", malformed)).status == 401
  var missingColon = initTable[string, string]()
  missingColon["authorization"] = "Basic " & encode("nocolonhere")
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me", missingColon)).status == 401

block basicSkipsExcludedPaths:
  let app = initFastNim(logs = false)
  app.installPlugin(authPlugin(basicOptions()))
  app.get("/health"):
    text("ok")
  let response = app.handleSync(initRequest(HttpMethod.Get, "/health"))
  doAssert response.status == 200
  doAssert response.body == "ok"

block apiKeyHeaderAndQuery:
  let app = initFastNim(logs = false)
  app.installPlugin(
    authPlugin(
      initAuthOptions(
        schemes = {AuthScheme.ApiKey},
        apiKeys = {"key-1": "service-a"}.toTable,
        apiKeyQuery = "api_key",
      )
    )
  )
  app.get("/me"):
    text(request.authSubject())
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me", apiKeyHeaders("key-1"))).body ==
    "service-a"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me?api_key=key-1")).body ==
    "service-a"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me", apiKeyHeaders("bad"))).status ==
    401

block apiKeyQueryDisabledByDefault:
  let app = initFastNim(logs = false)
  app.installPlugin(
    authPlugin(
      initAuthOptions(
        schemes = {AuthScheme.ApiKey}, apiKeys = {"key-1": "service-a"}.toTable
      )
    )
  )
  app.get("/me"):
    text("unreachable")
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me?api_key=key-1")).status == 401

block jwtRoundTrip:
  let secret = "test-secret-please-rotate"
  let token = issueJwtHs256("ada", secret, ttlSeconds = 3600)
  let claims = verifyJwtHs256(token, secret)
  doAssert claims["sub"].getStr() == "ada"
  doAssert claims["exp"].getInt() > claims["iat"].getInt()

block jwtRejectsBadTokens:
  let secret = "test-secret-please-rotate"
  let token = issueJwtHs256("ada", secret, ttlSeconds = 3600)
  doAssertRaises ValueError:
    discard verifyJwtHs256(token, "wrong-secret")
  doAssertRaises ValueError:
    discard verifyJwtHs256("not.a.token", secret)
  doAssertRaises ValueError:
    discard
      verifyJwtHs256(token.split('.')[0] & ".tampered." & token.split('.')[2], secret)
  let noneToken =
    base64UrlEncode($(%*{"alg": "none", "typ": "JWT"})) & "." &
    base64UrlEncode($(%*{"sub": "ada"})) & "."
  doAssertRaises ValueError:
    discard verifyJwtHs256(noneToken, secret)

proc signTestJwt(payload: JsonNode, secret: string): string =
  ## Signs ``payload`` exactly like issueJwtHs256, for crafting edge cases.
  let signingInput =
    base64UrlEncode($(%*{"alg": "HS256", "typ": "JWT"})) & "." &
    base64UrlEncode($payload)
  let digest = sha256.hmac(secret, signingInput)
  var signature = newString(32)
  copyMem(addr signature[0], unsafeAddr digest.data[0], 32)
  signingInput & "." & base64UrlEncode(signature)

block jwtExpiredRejected:
  let secret = "test-secret-please-rotate"
  let now = epochTime().int
  let past = %*{"sub": "ada", "iat": now - 7200, "exp": now - 100}
  doAssertRaises ValueError:
    discard verifyJwtHs256(signTestJwt(past, secret), secret)
  let future = %*{"sub": "ada", "iat": now, "exp": now + 3600}
  doAssert verifyJwtHs256(signTestJwt(future, secret), secret)["sub"].getStr() == "ada"

block jwtMiddlewareAcceptsBearerJwt:
  let secret = "demo-secret-change-me"
  let app = initFastNim(logs = false)
  app.installPlugin(
    authPlugin(initAuthOptions(schemes = {AuthScheme.Jwt}, jwtSecrets = @[secret]))
  )
  app.get("/me"):
    json(%*{"user": request.authSubject(), "scheme": request.authScheme()})
  let token = issueJwtHs256("ada", secret)
  let response =
    app.handleSync(initRequest(HttpMethod.Get, "/me", bearerHeaders(token)))
  doAssert response.status == 200
  doAssert response.body == "{\"user\":\"ada\",\"scheme\":\"jwt\"}"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me")).status == 401

block sessionLoginRoundTrip:
  let store = newSessionStore()
  doAssert waitFor(sessionCount(store)) == 0
  let id = waitFor createSession(store, "ada")
  doAssert id.len > 20
  doAssert waitFor(sessionSubject(store, id)) == "ada"
  doAssert waitFor(sessionCount(store)) == 1
  doAssert waitFor(sessionSubject(store, "bogus")) == ""
  waitFor destroySession(store, id)
  doAssert waitFor(sessionSubject(store, id)) == ""
  doAssert waitFor(sessionCount(store)) == 0

block sessionExpiry:
  let store = newSessionStore()
  let id = waitFor createSession(store, "ada", ttlSeconds = -1)
  doAssert waitFor(sessionSubject(store, id)) == ""
  doAssert waitFor(sessionCount(store)) == 0

block sessionCookieHelpers:
  var response = initResponse()
  setSessionCookie(response, "session_id", "abc123", maxAge = 3600)
  let header = response.headers["set-cookie"]
  doAssert "session_id=abc123" in header
  doAssert "HttpOnly" in header
  doAssert "Max-Age=3600" in header
  doAssert "SameSite=Lax" in header
  clearSessionCookie(response, "session_id")
  doAssert "Max-Age=0" in response.headers["set-cookie"]
  var headers = initTable[string, string]()
  headers["cookie"] = "session_id=abc123; theme=dark"
  let request = initRequest(HttpMethod.Get, "/", headers)
  doAssert sessionIdCookie(request) == "abc123"
  doAssert parseCookies(request)["theme"] == "dark"

block sessionMiddlewareFlow:
  let store = newSessionStore()
  let app = initFastNim(logs = false)
  app.installPlugin(
    authPlugin(
      initAuthOptions(
        schemes = {AuthScheme.Session}, sessionStore = store, excludePaths = @["/login"]
      )
    )
  )
  app.post("/login"):
    var response = json(%*{"ok": true})
    discard await loginSession(store, response, "ada")
    response
  app.get("/me"):
    text(request.authSubject())
  let login = app.handleSync(initRequest(HttpMethod.Post, "/login"))
  doAssert login.status == 200
  doAssert "session_id=" in login.headers["set-cookie"]
  let cookie = login.headers["set-cookie"].split(';')[0]
  var headers = initTable[string, string]()
  headers["cookie"] = cookie
  let me = app.handleSync(initRequest(HttpMethod.Get, "/me", headers))
  doAssert me.status == 200
  doAssert me.body == "ada"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/me")).status == 401

block sseHelperAcceptsAndRejects:
  let options = initAuthOptions(
    schemes = {AuthScheme.Bearer}, bearerTokens = {"tok-1": "ada"}.toTable
  )
  let good = waitFor authenticate(
    initRequest(HttpMethod.Get, "/live", bearerHeaders("tok-1")), options
  )
  doAssert not good.isNil
  doAssert good.subject == "ada"
  doAssert good.scheme == AuthScheme.Bearer
  let bad = waitFor authenticate(
    initRequest(HttpMethod.Get, "/live", bearerHeaders("nope")), options
  )
  doAssert bad.isNil
  let missing = waitFor authenticate(initRequest(HttpMethod.Get, "/live"), options)
  doAssert missing.isNil

block authDocumentsUnauthorized:
  let app = initFastNim(logs = false)
  app.installPlugin(authPlugin(basicOptions()))
  app.get("/items", responses = @[(200, string)]):
    "ok"
  let document = app.openApiDocument()
  doAssert document["paths"]["/items"]["get"]["responses"]["401"]["description"].getStr ==
    "Unauthorized"

block authPluginValidation:
  doAssertRaises ValueError:
    discard initAuthOptions(schemes = {})
  doAssertRaises ValueError:
    discard initAuthOptions(schemes = {AuthScheme.Basic})
  doAssertRaises ValueError:
    discard initAuthOptions(schemes = {AuthScheme.ApiKey})
  doAssertRaises ValueError:
    discard initAuthOptions(schemes = {AuthScheme.Jwt})
  doAssertRaises ValueError:
    discard initAuthOptions(schemes = {AuthScheme.Session})
  doAssertRaises ValueError:
    discard initAuthOptions(schemes = {AuthScheme.Basic}, includePaths = @["nope"])
  let app = initFastNim(logs = false)
  app.installPlugin(authPlugin(basicOptions()))
  doAssert app.installedPlugins[^1].name == "auth"
  doAssertRaises ValueError:
    app.installPlugin(authPlugin(basicOptions()))

block corsPreflightPassesThrough:
  let app = initFastNim(logs = false)
  app.addMiddleware(cors())
  app.installPlugin(authPlugin(basicOptions()))
  app.get("/items"):
    text("ok")
  var headers = initTable[string, string]()
  headers["origin"] = "https://app.example.com"
  headers["access-control-request-method"] = "GET"
  let response = app.handleSync(initRequest(HttpMethod.Options, "/items", headers))
  doAssert response.status != 401
