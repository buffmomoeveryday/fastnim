## Static file serving for fastnim applications.
##
## The idiomatic Nim API mounts a directory at a URL prefix:
##
## ```nim
## import fastnim
##
## let app = initFastNim()
## app.serveStatic("/static", directory = "static")
## app.serveSingleFile("/favicon.ico", "static/favicon.ico")
## ```
##
## Static mounts run as ``BeforeRouting`` middleware, so they never shadow
## application routes: a request that does not match a file falls through to
## normal routing and custom 404 handlers. Mounts are intentionally excluded
## from the generated OpenAPI document.
##
## Small text assets can be baked into the binary with
## ``serveStaticEmbedded`` so deployments are a single file. Files larger
## than ``maxEmbedBytes`` or with a denied media extension are rejected at
## compile time; serve those from disk with ``serveStatic``, which streams
## large files in chunks instead of loading them into memory.

import std/[os, strutils, tables, times, uri]

import chronos

import fastnim/context/http
import fastnim/routing/router

type EmbeddedFile* = object ## A file baked into the binary at compile time.
  content*: string ## Raw file bytes served from memory.
  contentType*: string ## MIME type guessed from the file extension.
  etag*: string ## Quoted ``"<size>-<mtime>"`` validator.
  lastModified*: string ## HTTP date of the file at compile time.
  mtime*: int64 ## File modification time as a Unix timestamp.
  size*: int ## File size in bytes.

proc guessContentType*(path: string): string =
  ## Guesses the ``Content-Type`` for ``path`` from its file extension.
  ##
  ## Text types carry an explicit UTF-8 charset. Unknown extensions fall back
  ## to ``application/octet-stream``.
  case path.splitFile().ext.toLowerAscii()
  of ".html", ".htm": "text/html; charset=utf-8"
  of ".css": "text/css; charset=utf-8"
  of ".js", ".mjs": "text/javascript; charset=utf-8"
  of ".json", ".map": "application/json; charset=utf-8"
  of ".xml": "application/xml; charset=utf-8"
  of ".svg": "image/svg+xml"
  of ".txt", ".md": "text/plain; charset=utf-8"
  of ".csv": "text/csv; charset=utf-8"
  of ".wasm": "application/wasm"
  of ".pdf": "application/pdf"
  of ".zip": "application/zip"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  of ".avif": "image/avif"
  of ".bmp": "image/bmp"
  of ".ico": "image/x-icon"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".otf": "font/otf"
  of ".eot": "application/vnd.ms-fontobject"
  of ".mp3": "audio/mpeg"
  of ".ogg", ".oga": "audio/ogg"
  of ".wav": "audio/wav"
  of ".webm": "video/webm"
  of ".mp4": "video/mp4"
  of ".mov": "video/quicktime"
  of ".avi": "video/x-msvideo"
  of ".mkv": "video/x-matroska"
  else: "application/octet-stream"

proc normalizePrefix(prefix: string): string =
  if prefix.len == 0 or prefix[0] != '/':
    raise newException(ValueError, "static mount prefix must start with '/'")
  result = prefix
  while result.len > 1 and result[^1] == '/':
    result.setLen(result.len - 1)

proc getReqHeader(request: Request, name: string): string =
  let wanted = name.toLowerAscii()
  for key, value in request.headers:
    if key.toLowerAscii() == wanted:
      return value
  ""

proc safeRelPath*(decoded: string): tuple[ok: bool, rel: string] =
  ## Normalizes a decoded URL remainder into a relative path.
  ##
  ## ``..`` segments that escape the mount root return ``ok = false``.
  var parts: seq[string] = @[]
  for segment in decoded.split('/'):
    if segment.len == 0 or segment == ".":
      continue
    if segment == "..":
      if parts.len == 0:
        return (false, "")
      discard parts.pop()
    else:
      parts.add(segment)
  (true, parts.join("/"))

proc hasDotfile(rel: string): bool =
  for part in rel.split('/'):
    if part.len > 0 and part[0] == '.':
      return true
  false

proc formatHttpDate*(moment: Time): string =
  ## Formats ``moment`` as an HTTP ``Last-Modified`` date.
  moment.utc.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")

proc parseHttpDate*(value: string, moment: var Time): bool =
  ## Parses an HTTP date, returning whether it was valid.
  try:
    moment = parse(value.strip(), "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc()).toTime()
    true
  except CatchableError:
    false

proc makeEtag*(size, mtimeUnix: int64): string =
  ## Builds a quoted ``"<size>-<mtime>"`` validator for a static file.
  "\"" & $size & "-" & $mtimeUnix & "\""

proc notModified(request: Request, etag: string, mtimeUnix: int64): bool =
  let inm = getReqHeader(request, "if-none-match")
  if inm.len > 0:
    if inm.strip() == "*":
      return true
    for tag in inm.split(','):
      if tag.strip() == etag:
        return true
    return false
  let ims = getReqHeader(request, "if-modified-since")
  if ims.len > 0:
    var moment: Time
    if parseHttpDate(ims, moment) and mtimeUnix <= moment.toUnix():
      return true
  false

type RangeOutcome {.pure.} = enum
  RangeIgnore
  RangeOk
  RangeUnsatisfiable

proc parseRange(value: string, size: int64, offset, length: var int64): RangeOutcome =
  ## Parses a single ``Range: bytes=A-B`` header.
  ##
  ## ``RangeIgnore`` means the header is absent or malformed and the full
  ## file should be served. ``RangeUnsatisfiable`` maps to ``416``.
  var v = value.strip()
  if not v.toLowerAscii().startsWith("bytes="):
    return RangeOutcome.RangeIgnore
  v = v[6 ..^ 1].strip()
  if ',' in v:
    return RangeOutcome.RangeUnsatisfiable
  let dash = v.find('-')
  if dash < 0:
    return RangeOutcome.RangeIgnore
  let first = v[0 ..< dash].strip()
  let last = v[dash + 1 ..^ 1].strip()
  try:
    if first.len == 0:
      if last.len == 0:
        return RangeOutcome.RangeIgnore
      let suffix = parseBiggestInt(last)
      if suffix <= 0:
        return RangeOutcome.RangeIgnore
      if suffix >= size:
        offset = 0
        length = size
      else:
        offset = size - suffix
        length = suffix
      return RangeOutcome.RangeOk
    let start = parseBiggestInt(first)
    if start < 0 or start >= size:
      return RangeOutcome.RangeUnsatisfiable
    var finish = size - 1
    if last.len > 0:
      finish = parseBiggestInt(last)
      if finish < start:
        return RangeOutcome.RangeUnsatisfiable
      if finish >= size:
        finish = size - 1
    offset = start
    length = finish - start + 1
    RangeOutcome.RangeOk
  except ValueError:
    RangeOutcome.RangeIgnore

proc setStaticHeaders(
    response: var Response,
    contentType, etag, lastModified: string,
    contentLength: int64,
    maxAge: int,
    contentRange = "",
) =
  response.setHeader("content-type", contentType)
  response.setHeader("content-length", $contentLength)
  response.setHeader("last-modified", lastModified)
  response.setHeader("etag", etag)
  response.setHeader("accept-ranges", "bytes")
  if maxAge > 0:
    response.setHeader("cache-control", "public, max-age=" & $maxAge)
  if contentRange.len > 0:
    response.setHeader("content-range", contentRange)

proc notModifiedResponse(etag, lastModified: string, maxAge: int): Response =
  result = initResponse(statusNotModified)
  result.headers.del("content-type")
  result.setHeader("etag", etag)
  result.setHeader("last-modified", lastModified)
  if maxAge > 0:
    result.setHeader("cache-control", "public, max-age=" & $maxAge)

proc checkMaxAge(maxAge: int) =
  if maxAge < 0:
    raise newException(ValueError, "static maxAge cannot be negative")

proc readRange(filePath: string, offset, length: int64): string =
  ## Reads ``length`` bytes at ``offset`` for small-file Range responses.
  var handle: File
  if not open(handle, filePath, fmRead):
    raise newException(IOError, "cannot open static file: " & filePath)
  try:
    setFilePos(handle, offset)
    result = newString(length.int)
    let got = readBuffer(handle, addr result[0], length.int)
    result.setLen(got)
  finally:
    close(handle)

proc serveDiskFile(
    request: Request, filePath: string, maxAge, streamThreshold: int
): Response =
  ## Builds a file response for ``filePath`` with caching, Range, and
  ## HEAD support. Large files return a ``sendFile`` marker that the
  ## Chronos adapter streams in chunks.
  var info: FileInfo
  try:
    info = getFileInfo(filePath)
  except OSError:
    return text(statusNotFound, "Not Found")
  if info.kind != pcFile:
    return text(statusNotFound, "Not Found")
  let size = info.size
  let mtimeUnix = info.lastWriteTime.toUnix()
  let etag = makeEtag(size, mtimeUnix)
  let lastMod = formatHttpDate(info.lastWriteTime)
  let contentType = guessContentType(filePath)
  let headOnly = request.method == HttpMethod.Head
  if notModified(request, etag, mtimeUnix):
    return notModifiedResponse(etag, lastMod, maxAge)
  var status = 200
  var offset: int64 = 0
  var length: int64 = size
  var contentRange = ""
  if not headOnly:
    case parseRange(getReqHeader(request, "range"), size, offset, length)
    of RangeOutcome.RangeOk:
      status = 206
      contentRange = "bytes " & $offset & "-" & $(offset + length - 1) & "/" & $size
    of RangeOutcome.RangeUnsatisfiable:
      result = text(statusRangeNotSatisfiable, "Requested Range Not Satisfiable")
      result.setHeader("content-range", "bytes */" & $size)
      return result
    of RangeOutcome.RangeIgnore:
      discard
  if not headOnly and length > 0 and size >= int64(streamThreshold):
    result = initResponse()
    if status == 206:
      result.status = statusCode(statusPartialContent)
    setStaticHeaders(result, contentType, etag, lastMod, length, maxAge, contentRange)
    result.sendFile = filePath
    result.fileOffset = offset
    result.fileLength = length
    return result
  var body = ""
  result = initResponse()
  if not headOnly:
    try:
      if offset == 0 and length == size:
        body = readFile(filePath)
      else:
        body = readRange(filePath, offset, length)
    except CatchableError:
      return text(statusNotFound, "Not Found")
    result.body = body
  if status == 206:
    result.status = statusCode(statusPartialContent)
  setStaticHeaders(result, contentType, etag, lastMod, length, maxAge, contentRange)

proc respondEmbedded(request: Request, emb: EmbeddedFile, maxAge: int): Response =
  ## Builds a response for an embedded file with caching, Range, and
  ## HEAD support.
  let headOnly = request.method == HttpMethod.Head
  if notModified(request, emb.etag, emb.mtime):
    return notModifiedResponse(emb.etag, emb.lastModified, maxAge)
  var status = 200
  var offset: int64 = 0
  var length: int64 = emb.size.int64
  var contentRange = ""
  if not headOnly:
    case parseRange(getReqHeader(request, "range"), length, offset, length)
    of RangeOutcome.RangeOk:
      status = 206
      contentRange = "bytes " & $offset & "-" & $(offset + length - 1) & "/" & $emb.size
    of RangeOutcome.RangeUnsatisfiable:
      result = text(statusRangeNotSatisfiable, "Requested Range Not Satisfiable")
      result.setHeader("content-range", "bytes */" & $emb.size)
      return result
    of RangeOutcome.RangeIgnore:
      discard
  var body = ""
  if not headOnly:
    if offset == 0 and length == emb.size.int64:
      body = emb.content
    else:
      let first = offset.int
      body = emb.content[first ..< first + length.int]
  result = initResponse(body)
  if status == 206:
    result.status = statusCode(statusPartialContent)
  setStaticHeaders(
    result, emb.contentType, emb.etag, emb.lastModified, length, maxAge, contentRange
  )

proc matchPrefix(normPrefix, path: string, sub: var string): bool =
  ## Splits ``path`` into the remainder below a mounted ``normPrefix``.
  if normPrefix == "/":
    if path.len == 0 or path[0] != '/':
      return false
    sub = path[1 ..^ 1]
    return true
  if path == normPrefix:
    sub = ""
    return true
  if path.startsWith(normPrefix & "/"):
    sub = path[normPrefix.len + 1 ..^ 1]
    return true
  false

proc redirectToSlash(request: Request): Response =
  ## Redirects a directory URL without a trailing slash to its slashed form.
  var location = request.path & "/"
  if request.queryParams.len > 0:
    var first = true
    for key, value in request.queryParamPairs():
      location.add(if first: "?" else: "&")
      first = false
      location.add(encodeUrl(key) & "=" & encodeUrl(value))
  result = initResponse(statusTemporaryRedirect, "")
  result.setHeader("location", location)

proc resolveRel(decoded: string, allowDotfiles: bool, rel: var string): bool =
  ## Decodes and jails a URL remainder, rejecting traversal and dotfiles.
  if '\0' in decoded:
    return false
  let (ok, cleaned) = safeRelPath(decoded)
  if not ok:
    return false
  if not allowDotfiles and hasDotfile(cleaned):
    return false
  rel = cleaned
  true

proc serveStatic*(
    app: Application,
    prefix, directory: string,
    indexFile = "index.html",
    maxAge = 3600,
    allowDotfiles = false,
    spaFallback = "",
    streamThreshold = 1_048_576,
) =
  ## Serves ``directory`` at ``prefix`` (e.g. ``"/static"``).
  ##
  ## Only ``GET`` and ``HEAD`` requests below the prefix are handled; anything
  ## else, including missing files, directory traversal, and dotfiles, falls
  ## through to normal routing and custom 404 handlers. Directory URLs serve
  ## ``indexFile`` when present (empty ``indexFile`` disables this). Unknown
  ## subpaths serve ``spaFallback`` when set, which enables SPA hosting.
  ## Files at least ``streamThreshold`` bytes are streamed in chunks by the
  ## Chronos adapter instead of being loaded into memory.
  let normPrefix = normalizePrefix(prefix)
  checkMaxAge(maxAge)
  if not dirExists(directory):
    raise newException(ValueError, "static directory does not exist: " & directory)
  if spaFallback.len > 0 and (isAbsolute(spaFallback) or ".." in spaFallback.split('/')):
    raise
      newException(ValueError, "static spaFallback must be relative to the directory")
  let absDir = absolutePath(directory)
  app.use(
    proc(
        request: Request, next: NextHandler
    ): Future[Response] {.async: (raises: [CatchableError]).} =
      if request.method != HttpMethod.Get and request.method != HttpMethod.Head:
        return await next(request)
      var sub: string
      if not matchPrefix(normPrefix, request.path, sub):
        return await next(request)
      var rel: string
      if not resolveRel(decodeUrl(sub, false), allowDotfiles, rel):
        return await next(request)
      var filePath = ""
      if rel.len == 0:
        if indexFile.len > 0 and fileExists(absDir / indexFile):
          filePath = absDir / indexFile
      else:
        let full = absDir / rel
        if dirExists(full):
          if indexFile.len > 0 and fileExists(full / indexFile):
            if not request.path.endsWith("/"):
              return redirectToSlash(request)
            filePath = full / indexFile
        elif fileExists(full):
          filePath = full
      if filePath.len == 0:
        if spaFallback.len > 0 and fileExists(absDir / spaFallback):
          filePath = absDir / spaFallback
        else:
          return await next(request)
      serveDiskFile(request, filePath, maxAge, streamThreshold)
  )

proc serveSingleFile*(
    app: Application, path, file: string, maxAge = 3600, streamThreshold = 1_048_576
) =
  ## Serves one file at the exact route ``path`` (e.g. ``"/favicon.ico"``).
  ##
  ## Only ``GET`` and ``HEAD`` are handled; other requests fall through to
  ## normal routing. Large files stream through the Chronos adapter.
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "static file path must start with '/'")
  checkMaxAge(maxAge)
  if not fileExists(file):
    raise newException(ValueError, "static file does not exist: " & file)
  let absFile = absolutePath(file)
  app.use(
    proc(
        request: Request, next: NextHandler
    ): Future[Response] {.async: (raises: [CatchableError]).} =
      if request.method != HttpMethod.Get and request.method != HttpMethod.Head:
        return await next(request)
      if request.path != path:
        return await next(request)
      serveDiskFile(request, absFile, maxAge, streamThreshold)
  )

proc serveEmbeddedFiles*(
    app: Application,
    prefix: string,
    files: Table[string, EmbeddedFile],
    indexFile = "index.html",
    maxAge = 3600,
    allowDotfiles = false,
    spaFallback = "",
) =
  ## Serves compile-time ``files`` (relative URL paths to ``EmbeddedFile``)
  ## at ``prefix``. This is the runtime half of ``serveStaticEmbedded``.
  let normPrefix = normalizePrefix(prefix)
  checkMaxAge(maxAge)
  app.use(
    proc(
        request: Request, next: NextHandler
    ): Future[Response] {.async: (raises: [CatchableError]).} =
      if request.method != HttpMethod.Get and request.method != HttpMethod.Head:
        return await next(request)
      var sub: string
      if not matchPrefix(normPrefix, request.path, sub):
        return await next(request)
      var rel: string
      if not resolveRel(decodeUrl(sub, false), allowDotfiles, rel):
        return await next(request)
      var key = rel
      if key.len == 0:
        if indexFile.len > 0 and indexFile in files:
          key = indexFile
      if key notin files:
        if spaFallback.len > 0 and spaFallback in files:
          key = spaFallback
        else:
          return await next(request)
      respondEmbedded(request, files[key], maxAge)
  )

proc serveSingleEmbedded*(
    app: Application, path: string, file: EmbeddedFile, maxAge = 3600
) =
  ## Serves one embedded file at the exact route ``path``.
  if path.len == 0 or path[0] != '/':
    raise newException(ValueError, "static file path must start with '/'")
  checkMaxAge(maxAge)
  app.use(
    proc(
        request: Request, next: NextHandler
    ): Future[Response] {.async: (raises: [CatchableError]).} =
      if request.method != HttpMethod.Get and request.method != HttpMethod.Head:
        return await next(request)
      if request.path != path:
        return await next(request)
      respondEmbedded(request, file, maxAge)
  )
