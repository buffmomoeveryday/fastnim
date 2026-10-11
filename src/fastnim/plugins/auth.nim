## Authentication plugin for FastNim applications.
##
## Enable any combination of ``Bearer``, ``Basic``, ``ApiKey``, ``Jwt``
## (HS256), and ``Session`` schemes, scope them with ``includePaths`` /
## ``excludePaths`` URL patterns, and install ``authPlugin``:
##
## ```nim
## let authOpts = initAuthOptions(
##   schemes = {AuthScheme.Basic},
##   basicUsers = {"ada": "correct horse"}.toTable,
##   excludePaths = @["/health", "/openapi.json"],
## )
## app.install(authPlugin(authOpts))
##
## app.get("/me"):
##   json(%*{"user": request.authSubject()})
## ```
##
## Verified requests carry ``x-auth-subject`` and ``x-auth-scheme`` headers
## downstream. Those headers are always stripped first, so clients cannot
## spoof them — never trust values a client sends directly.
##
## ``app.use`` middleware does not run for SSE or WebSocket routes. Inside
## ``app.sse`` blocks, verify explicitly with ``authenticate`` (wrapping the
## call for shared options, as in the websocket broadcast example):
##
## ```nim
## app.sse("/live"):
##   let identity = await authenticate(request, authOpts)
##   if identity.isNil:
##     return
## ```

import std/[json, strutils, tables]

import chronos

import fastnim/[context/http, params/extract, plugin, routing/router]
import fastnim/plugins/auth/[patterns, schemes, session]

export schemes, patterns, session

const
  AuthSubjectHeader* = "x-auth-subject"
    ## Downstream header carrying the verified subject.
  AuthSchemeHeader* = "x-auth-scheme"
    ## Downstream header carrying the verifying scheme name.

type
  AuthOptions* = object ## Configuration installed by ``authPlugin``.
    schemes*: set[AuthScheme] ## Accepted mechanisms; must not be empty.
    includePaths*: seq[string]
      ## Protected URL patterns (``{name}`` and trailing ``*`` allowed).
    excludePaths*: seq[string] ## Public URL patterns; exclusions always win.
    realm*: string ## Authentication realm reported in challenges.
    bearerTokens*: Table[string, string]
      ## Static bearer token to subject mapping.
    apiKeys*: Table[string, string] ## Static API key to subject mapping.
    apiKeyHeader*: string ## Header carrying API keys.
    apiKeyQuery*: string
      ## Query parameter also accepted for API keys; empty disables it.
    basicUsers*: Table[string, string]
      ## Username to password mapping. Passwords are compared in constant
      ## time, but for production look users up in a real credential store
      ## with a password hasher instead of keeping them here.
    jwtSecrets*: seq[string]
      ## HS256 secrets tried in order, so rotation is hitless.
    jwtLeewaySeconds*: int ## Clock skew accepted for ``exp``/``nbf``.
    sessionStore*: SessionStore ## Enables the session scheme when set.
    sessionCookie*: string ## Cookie carrying session ids.

proc initAuthOptions*(
    schemes: set[AuthScheme] = {AuthScheme.Bearer},
    includePaths: seq[string] = @["/*"],
    excludePaths: seq[string] = @[],
    realm = "fastnim",
    bearerTokens = initTable[string, string](),
    apiKeys = initTable[string, string](),
    apiKeyHeader = "x-api-key",
    apiKeyQuery = "",
    basicUsers = initTable[string, string](),
    jwtSecrets: seq[string] = @[],
    jwtLeewaySeconds = 60,
    sessionStore: SessionStore = nil,
    sessionCookie = "session_id",
): AuthOptions =
  ## Creates auth configuration, failing fast on certain misconfiguration.
  ##
  ## Static tables map credentials to subjects. A scheme that is enabled but
  ## has nowhere to verify against (empty tables, no secrets, nil store) is
  ## rejected, except bearer tokens when JWT is also enabled, since JWTs
  ## arrive as bearer tokens too.
  if schemes.len == 0:
    raise newException(ValueError, "auth schemes cannot be empty")
  if realm.len == 0:
    raise newException(ValueError, "auth realm cannot be empty")
  if jwtLeewaySeconds < 0:
    raise newException(ValueError, "JWT leeway cannot be negative")
  if apiKeyHeader.len == 0:
    raise newException(ValueError, "API key header cannot be empty")
  if sessionCookie.len == 0:
    raise newException(ValueError, "session cookie name cannot be empty")
  for pattern in includePaths & excludePaths:
    if pattern != "*" and (pattern.len == 0 or pattern[0] != '/'):
      raise newException(ValueError, "auth patterns must start with '/'")
  if AuthScheme.Basic in schemes and basicUsers.len == 0:
    raise newException(ValueError, "basic auth needs basicUsers")
  if AuthScheme.ApiKey in schemes and apiKeys.len == 0:
    raise newException(ValueError, "API key auth needs apiKeys")
  if AuthScheme.Jwt in schemes and jwtSecrets.len == 0:
    raise newException(ValueError, "JWT auth needs jwtSecrets")
  if AuthScheme.Bearer in schemes and bearerTokens.len == 0 and
      AuthScheme.Jwt notin schemes:
    raise newException(ValueError, "bearer auth needs bearerTokens or JWT")
  if AuthScheme.Session in schemes and sessionStore.isNil:
    raise newException(ValueError, "session auth needs a sessionStore")
  AuthOptions(
    schemes: schemes,
    includePaths: includePaths,
    excludePaths: excludePaths,
    realm: realm,
    bearerTokens: bearerTokens,
    apiKeys: apiKeys,
    apiKeyHeader: apiKeyHeader.toLowerAscii(),
    apiKeyQuery: apiKeyQuery,
    basicUsers: basicUsers,
    jwtSecrets: jwtSecrets,
    jwtLeewaySeconds: jwtLeewaySeconds,
    sessionStore: sessionStore,
    sessionCookie: sessionCookie,
  )

proc authSubject*(request: Request): string {.inline, raises: [].} =
  ## Returns the verified subject set by the auth middleware, or "".
  request.header(AuthSubjectHeader)

proc authScheme*(request: Request): string {.inline, raises: [].} =
  ## Returns the verifying scheme name set by the auth middleware, or "".
  request.header(AuthSchemeHeader)

proc authenticate*(request: Request, options: AuthOptions): Future[AuthIdentity] {.
    async: (raises: [CatchableError]).} =
  ## Asynchronously verifies ``request`` credentials and returns the identity,
  ## or nil.
  ##
  ## The first recognized scheme decides, fail-closed: a present-but-invalid
  ## credential is rejected without trying weaker schemes. Bearer tokens are
  ## checked against static tokens first, then as JWTs. Use it directly in
  ## ``app.sse`` handlers, which middleware never reaches.
  let authorization = request.header("authorization")
  if authorization.len > 0:
    if authorization.len > 7 and
        authorization[0 .. 6].cmpIgnoreCase("bearer ") == 0:
      let token = authorization[7 ..^ 1].strip()
      if AuthScheme.Bearer in options.schemes:
        let subject = lookupSubject(token, options.bearerTokens)
        if subject.len > 0:
          return AuthIdentity(subject: subject, scheme: AuthScheme.Bearer,
            claims: newJObject())
      if AuthScheme.Jwt in options.schemes:
        try:
          let claims = verifyJwtHs256(
            token, options.jwtSecrets, options.jwtLeewaySeconds
          )
          let subject = claims.getOrDefault("sub").getStr("")
          if subject.len > 0:
            return AuthIdentity(subject: subject, scheme: AuthScheme.Jwt,
              claims: claims)
        except ValueError:
          discard
      return nil
    if authorization.len > 6 and
        authorization[0 .. 5].cmpIgnoreCase("basic ") == 0:
      if AuthScheme.Basic notin options.schemes:
        return nil
      let (user, password, ok) = basicCredentials(request)
      if not ok:
        return nil
      var expected = ""
      var known = false
      for name, stored in options.basicUsers:
        if secureCompare(user, name):
          known = true
          expected = stored
      if known and secureCompare(password, expected):
        return AuthIdentity(subject: user, scheme: AuthScheme.Basic,
          claims: newJObject())
      return nil
    return nil

  if AuthScheme.ApiKey in options.schemes:
    let key = apiKey(request, options.apiKeyHeader, options.apiKeyQuery)
    if key.len > 0:
      let subject = lookupSubject(key, options.apiKeys)
      if subject.len > 0:
        return AuthIdentity(subject: subject, scheme: AuthScheme.ApiKey,
          claims: newJObject())
      return nil

  if AuthScheme.Session in options.schemes and not options.sessionStore.isNil:
    let subject = await sessionSubject(
      options.sessionStore, sessionIdCookie(request, options.sessionCookie)
    )
    if subject.len > 0:
      return AuthIdentity(subject: subject, scheme: AuthScheme.Session,
        claims: newJObject())
    if sessionIdCookie(request, options.sessionCookie).len > 0:
      return nil

  nil

proc wwwAuthenticate*(options: AuthOptions): string =
  ## Builds the ``WWW-Authenticate`` challenge for enabled schemes.
  ##
  ## Only Bearer (covering JWT) and Basic have registered challenge schemes;
  ## API keys and sessions authenticate without one, so the header is omitted
  ## when neither applies.
  var parts: seq[string] = @[]
  if AuthScheme.Bearer in options.schemes or AuthScheme.Jwt in options.schemes:
    parts.add("Bearer realm=\"" & options.realm & "\"")
  if AuthScheme.Basic in options.schemes:
    parts.add("Basic realm=\"" & options.realm & "\"")
  parts.join(", ")

proc unauthorized*(
    missing: bool, options: AuthOptions
): Response =
  ## Creates a 401 JSON response with the scheme challenge when applicable.
  result = json(
    %*{
      "detail":
        if missing:
          "authentication required"
        else:
          "invalid credentials"
    },
    401,
  )
  let challenge = wwwAuthenticate(options)
  if challenge.len > 0:
    result.setHeader("www-authenticate", challenge)

proc hasCredentials(request: Request, options: AuthOptions): bool =
  request.header("authorization").len > 0 or
    (AuthScheme.ApiKey in options.schemes and
      apiKey(request, options.apiKeyHeader, options.apiKeyQuery).len > 0) or
    (AuthScheme.Session in options.schemes and not options.sessionStore.isNil and
      sessionIdCookie(request, options.sessionCookie).len > 0)

proc isPreflight(request: Request): bool {.inline.} =
  ## Detects CORS preflight, which carries no credentials by design.
  request.method == HttpMethod.Options and request.header("origin").len > 0 and
    request.header("access-control-request-method").len > 0

proc authMiddleware(options: AuthOptions): Middleware =
  result = proc(
      request: Request, next: NextHandler
  ): Future[Response] {.async: (raises: [CatchableError]).} =
    var clean = request
    clean.headers.del(AuthSubjectHeader)
    clean.headers.del(AuthSchemeHeader)
    if isPreflight(clean) or
        not isProtected(clean.path, options.includePaths, options.excludePaths):
      return await next(clean)
    let missing = not hasCredentials(clean, options)
    let identity = await authenticate(clean, options)
    if identity.isNil:
      return unauthorized(missing, options)
    clean.headers[AuthSubjectHeader] = identity.subject
    clean.headers[AuthSchemeHeader] = $identity.scheme
    return await next(clean)

proc contributeAuth(document: var JsonNode) =
  if "paths" notin document:
    return
  for _, pathItem in document["paths"]:
    for _, operation in pathItem:
      if operation.kind == JObject and "responses" in operation:
        operation["responses"]["401"] = %*{
          "description": "Unauthorized",
          "content": {
            "application/json": {"schema": {"type": "object"}}
          },
        }

proc authPlugin*(
    options = initAuthOptions(), name = "auth", version = "0.1.0"
): Plugin =
  ## Creates the authentication plugin.
  ##
  ## Install it (after CORS middleware, if any, so preflights keep working)
  ## and protect routes with ``includePaths``/``excludePaths``. Handlers read
  ## the verified caller with ``authSubject``; SSE handlers verify with
  ## ``await authenticate`` since middleware never reaches them.
  initPlugin(
    name,
    version,
    proc(app: Application) =
      app.use(authMiddleware(options))
      app.addOpenApiContributor(contributeAuth),
  )
