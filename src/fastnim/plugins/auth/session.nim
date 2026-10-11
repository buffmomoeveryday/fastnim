## Cookie session store for the FastNim auth plugin.
##
## Sessions are opaque random ids kept server-side in memory; only the id
## travels in a cookie, so nothing sensitive ever leaves the server. Entries
## expire lazily on read, with an opportunistic sweep on creation to bound
## growth. Like the rate limit plugin, the table is guarded by a lock.

import std/[json, locks, strutils, sysrand, tables, times]

import fastnim/[context/http, params/extract]

import fastnim/plugins/auth/schemes

type
  SessionData* = ref object of RootObj
    ## Server-side record for one login.
    subject*: string ## Who owns the session.
    createdAt*: float ## Unix time the session was created.
    expiresAt*: float ## Unix time the session stops being valid.

  SessionStore* = ref object of RootObj
    ## In-memory session table shared by an application's handlers.
    lock: Lock
    sessions: Table[string, SessionData]
    defaultTtlSeconds*: int ## Lifetime applied when creating without a ttl.

proc newSessionStore*(defaultTtlSeconds = 86400): SessionStore =
  ## Creates an empty session store. ``defaultTtlSeconds`` must be positive.
  if defaultTtlSeconds <= 0:
    raise newException(ValueError, "session ttl must be positive")
  new(result)
  initLock(result.lock)
  result.sessions = initTable[string, SessionData]()
  result.defaultTtlSeconds = defaultTtlSeconds

proc newSessionId*(): string {.raises: [ValueError].} =
  ## Generates an unguessable 32-byte session id as unpadded base64url.
  var raw: seq[byte]
  try:
    raw = urandom(32)
  except CatchableError:
    raise newException(ValueError, "could not read random session id")
  if raw.len != 32:
    raise newException(ValueError, "could not read random session id")
  var text = newString(32)
  copyMem(addr text[0], addr raw[0], 32)
  base64UrlEncode(text)

proc sweepExpiredSessions*(store: SessionStore) =
  ## Drops expired entries. Called opportunistically on creation; call it
  ## directly as well if logins are rare but reads are frequent.
  acquire(store.lock)
  try:
    let now = epochTime()
    var expired: seq[string] = @[]
    for id, session in store.sessions:
      if now >= session.expiresAt:
        expired.add(id)
    for id in expired:
      store.sessions.del(id)
  finally:
    release(store.lock)

proc createSession*(
    store: SessionStore, subject: string, ttlSeconds = 0
): string {.raises: [ValueError].} =
  ## Creates a session for ``subject`` and returns its id.
  ##
  ## A zero ``ttlSeconds`` falls back to the store default; a negative one is
  ## already expired (mirroring cookie ``Max-Age`` semantics). Always creates
  ## a fresh id (never adopt a client-supplied one) so logins are not
  ## vulnerable to session fixation.
  if subject.len == 0:
    raise newException(ValueError, "session subject cannot be empty")
  let ttl =
    if ttlSeconds == 0:
      store.defaultTtlSeconds
    else:
      ttlSeconds
  let id = newSessionId()
  let now = epochTime()
  acquire(store.lock)
  try:
    store.sessions[id] =
      SessionData(subject: subject, createdAt: now, expiresAt: now + float(ttl))
    if store.sessions.len mod 64 == 0:
      var expired: seq[string] = @[]
      for candidate, session in store.sessions:
        if now >= session.expiresAt:
          expired.add(candidate)
      for candidate in expired:
        store.sessions.del(candidate)
  finally:
    release(store.lock)
  id

proc sessionSubject*(store: SessionStore, id: string): string {.raises: [].} =
  ## Returns the owner of ``id``, or "" when unknown or expired.
  ##
  ## Expired entries are removed on read. Comparison is exact: ids are
  ## unguessable random values, not secrets to compare in constant time.
  if id.len == 0:
    return ""
  acquire(store.lock)
  try:
    let session = store.sessions.getOrDefault(id)
    if session.isNil:
      return ""
    if epochTime() >= session.expiresAt:
      store.sessions.del(id)
      return ""
    result = session.subject
  finally:
    release(store.lock)

proc destroySession*(store: SessionStore, id: string) {.raises: [].} =
  ## Deletes ``id`` if present. Logging out must always call this.
  if id.len == 0:
    return
  acquire(store.lock)
  try:
    store.sessions.del(id)
  finally:
    release(store.lock)

proc sessionCount*(store: SessionStore): int {.raises: [].} =
  ## Returns the number of stored sessions, including expired ones.
  acquire(store.lock)
  try:
    result = store.sessions.len
  finally:
    release(store.lock)

proc parseCookies*(request: Request): Table[string, string] {.raises: [].} =
  ## Splits the ``Cookie`` header into name/value pairs.
  ##
  ## Malformed entries are skipped; surrounding quotes and whitespace are
  ## stripped from values.
  result = initTable[string, string]()
  try:
    for chunk in request.header("cookie").split(';'):
      let pair = chunk.strip()
      if pair.len == 0:
        continue
      let separator = pair.find('=')
      if separator <= 0:
        continue
      var value = pair[separator + 1 ..^ 1].strip()
      if value.len >= 2 and value[0] == '"' and value[^1] == '"':
        value = value[1 ..^ 2]
      result[pair[0 ..< separator].strip()] = value
  except CatchableError:
    discard

proc sessionIdCookie*(request: Request, name = "session_id"): string {.
    inline, raises: [].} =
  ## Returns the session id from the ``name`` cookie, or "" when absent.
  parseCookies(request).getOrDefault(name, "")

proc setSessionCookie*(
    response: var Response,
    name, id: string,
    maxAge = -1,
    path = "/",
    httpOnly = true,
    sameSite = "Lax",
    secure = false,
) {.raises: [ValueError].} =
  ## Sets the session cookie on ``response``.
  ##
  ## The cookie is always ``HttpOnly`` unless disabled, scoped to ``path``,
  ## and defaults to ``SameSite=Lax``. Pass a positive ``maxAge`` for
  ## persistent logins (matching the session ttl) and ``secure = true`` in
  ## production so browsers only send it over HTTPS.
  if name.len == 0 or id.len == 0:
    raise newException(ValueError, "session cookie name and id cannot be empty")
  var cookie = name & "=" & id & "; Path=" & path
  if maxAge >= 0:
    cookie.add("; Max-Age=" & $maxAge)
  if httpOnly:
    cookie.add("; HttpOnly")
  if sameSite.len > 0:
    cookie.add("; SameSite=" & sameSite)
  if secure:
    cookie.add("; Secure")
  response.setHeader("set-cookie", cookie)

proc clearSessionCookie*(response: var Response, name: string, path = "/") {.
    raises: [ValueError].} =
  ## Expires the session cookie immediately. Call it together with
  ## ``destroySession`` when logging out.
  if name.len == 0:
    raise newException(ValueError, "session cookie name cannot be empty")
  response.setHeader(
    "set-cookie", name & "=; Path=" & path & "; Max-Age=0; HttpOnly; SameSite=Lax"
  )

proc loginSession*(
    store: SessionStore,
    response: var Response,
    subject: string,
    ttlSeconds = 0,
    cookieName = "session_id",
    secure = false,
): string {.raises: [ValueError].} =
  ## Creates a session for ``subject`` and sets its cookie. Returns the id.
  ##
  ## ``ttlSeconds`` falls back to the store default when non-positive; pass
  ## the same ttl as ``Max-Age`` so the cookie and the entry agree.
  let id = createSession(store, subject, ttlSeconds)
  let maxAge =
    if ttlSeconds > 0:
      ttlSeconds
    else:
      store.defaultTtlSeconds
  setSessionCookie(response, cookieName, id, maxAge = maxAge, secure = secure)
  id

proc logoutSession*(
    store: SessionStore, request: Request, response: var Response,
    cookieName = "session_id",
) =
  ## Destroys the request's session (if any) and clears its cookie.
  destroySession(store, sessionIdCookie(request, cookieName))
  clearSessionCookie(response, cookieName)
