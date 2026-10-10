## Compile-time embedding macros for static file serving.
##
## This module holds the heavy macro logic behind ``serveStaticEmbedded``
## and ``serveSingleEmbeddedFile``. Runtime serving lives in
## ``fastnim/static/files``; the macros generate calls into it with file
## contents baked in via ``staticRead``.

import std/[macros, os, strutils, tables]

import fastnim/static/files

const defaultDenyExts* =
  [".mp4", ".mov", ".avi", ".mkv", ".webm", ".mp3", ".wav", ".flac", ".ogg", ".opus"]
  ## Media extensions rejected by ``serveStaticEmbedded`` by default.
  ## Embed small text assets; stream media from disk with ``serveStatic``.

proc resolveStaticDir(directory, callDir: string): string {.compileTime.} =
  ## Resolves ``directory`` to an absolute path for ``staticRead``.
  ##
  ## ``staticRead`` resolves relative paths against the source file, so
  ## candidates are anchored on the macro call site first, then the project.
  if isAbsolute(directory):
    if dirExists(directory):
      return directory
  else:
    let base = getProjectPath()
    for candidate in [
      callDir / directory, base / directory, parentDir(base) / directory
    ]:
      # ``staticRead`` needs an absolute path; relative candidates cannot
      # be resolved without the process working directory.
      if isAbsolute(candidate) and dirExists(candidate):
        return candidate
  raise newException(
    ValueError,
    "static directory not found: " & directory & " (relative to " & callDir &
      " or the project)",
  )

proc resolveStaticFile(file, callDir: string): string {.compileTime.} =
  ## Resolves ``file`` to an absolute path for ``staticRead``.
  if isAbsolute(file):
    if fileExists(file):
      return file
  else:
    let base = getProjectPath()
    for candidate in [callDir / file, base / file, parentDir(base) / file]:
      if isAbsolute(candidate) and fileExists(candidate):
        return candidate
  raise newException(
    ValueError,
    "static file not found: " & file & " (relative to " & callDir & " or the project)",
  )

proc daysFromCivil(y, m, d: int): int64 {.compileTime.} =
  ## Days since 1970-01-01 using pure integer math (VM-safe).
  var year = y
  if m <= 2:
    year -= 1
  let era = (if year >= 0: year else: year - 399) div 400
  let yoe = year - era * 400
  let mp =
    if m > 2:
      m - 3
    else:
      m + 9
  let doy = (153 * mp + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

proc buildHttpMoment(): tuple[unix: int64, httpDate: string] {.compileTime.} =
  ## Build moment as Unix time and HTTP date, derived from
  ## ``CompileDate``/``CompileTime``.
  ##
  ## Embedded files record the build moment instead of a filesystem mtime
  ## because ``stat`` and timezones are unavailable to the compile-time VM.
  const weekDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  const months =
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  proc two(n: int): string =
    if n < 10:
      "0" & $n
    else:
      $n

  let dp = CompileDate.split('-')
  let tp = CompileTime.split(':')
  let year = dp[0].parseInt
  let month = dp[1].parseInt
  let day = dp[2].parseInt
  let days = daysFromCivil(year, month, day)
  let unix =
    days * 86400 + tp[0].parseInt.int64 * 3600 + tp[1].parseInt.int64 * 60 +
    tp[2].parseInt.int64
  let httpDate =
    weekDays[(days mod 7 + 7 + 4) mod 7] & ", " & two(day) & " " & months[month - 1] &
    " " & $year & " " & two(tp[0].parseInt) & ":" & two(tp[1].parseInt) & ":" &
    two(tp[2].parseInt) & " GMT"
  (unix, httpDate)

proc embeddedFileNode(
    absPath: string, maxEmbedBytes: int, denyExts: seq[string]
): NimNode {.compileTime.} =
  ## Builds an ``EmbeddedFile`` constructor for ``absPath``.
  ##
  ## Content is read with ``staticRead`` because ordinary file I/O is
  ## unavailable to the compile-time VM. Validators derive from the build
  ## moment and the content size.
  if absPath.splitFile().ext.toLowerAscii() in denyExts:
    raise newException(
      ValueError,
      "static file " & absPath &
        " has a denied media extension; serve it from disk with serveStatic instead",
    )
  let content = staticRead(absPath)
  let size = content.len
  if size > maxEmbedBytes:
    raise newException(
      ValueError,
      "static file " & absPath & " (" & $size & " bytes) exceeds maxEmbedBytes (" &
        $maxEmbedBytes & "); serve it from disk with serveStatic instead",
    )
  let moment = buildHttpMoment()
  let mtimeUnix = moment.unix
  let etag = makeEtag(size.int64, mtimeUnix)
  let lastMod = moment.httpDate
  let contentType = guessContentType(absPath)
  let contentLit = newLit(content)
  let contentTypeLit = newLit(contentType)
  let etagLit = newLit(etag)
  let lastModLit = newLit(lastMod)
  let mtimeLit = newLit(mtimeUnix)
  let sizeLit = newLit(size.int)
  result = quote:
    EmbeddedFile(
      content: `contentLit`,
      contentType: `contentTypeLit`,
      etag: `etagLit`,
      lastModified: `lastModLit`,
      mtime: `mtimeLit`,
      size: `sizeLit`,
    )

macro serveStaticEmbedded*(
    app: typed,
    prefix: static[string],
    directory: static[string],
    args: varargs[untyped],
): untyped =
  ## Serves ``directory`` at ``prefix`` with every file baked into the binary.
  ##
  ## ```nim
  ## app.serveStaticEmbedded("/static", "static", maxAge = 86400)
  ## ```
  ##
  ## ``directory`` is resolved at compile time against the calling source
  ## file first, then the project (use an absolute path to be explicit).
  ## Files larger than ``maxEmbedBytes`` (default 1 MiB) or
  ## with an extension in ``denyExts`` (media formats by default) are
  ## rejected at compile time; serve those from disk with ``serveStatic``.
  var indexFile = newLit("index.html")
  var maxAge = newLit(3600)
  var allowDotfiles = newLit(false)
  var spaFallback = newLit("")
  var maxEmbedBytes = 1_048_576
  var denyExts: seq[string] = @[]
  for item in defaultDenyExts:
    denyExts.add(item)

  for argument in args:
    if argument.kind != nnkExprEqExpr:
      error("serveStaticEmbedded options must use `name = value`", argument)
    case $argument[0]
    of "indexFile":
      if argument[1].kind != nnkStrLit:
        error("indexFile must be a string literal", argument[1])
      indexFile = newLit(argument[1].strVal)
    of "maxAge":
      if argument[1].kind notin {nnkIntLit .. nnkUInt64Lit}:
        error("maxAge must be an integer literal", argument[1])
      maxAge = newLit(argument[1].intVal.int)
    of "allowDotfiles":
      if argument[1].kind != nnkIdent or ($argument[1] notin ["true", "false"]):
        error("allowDotfiles must be true or false", argument[1])
      allowDotfiles = newLit($argument[1] == "true")
    of "spaFallback":
      if argument[1].kind != nnkStrLit:
        error("spaFallback must be a string literal", argument[1])
      spaFallback = newLit(argument[1].strVal)
    of "maxEmbedBytes":
      if argument[1].kind notin {nnkIntLit .. nnkUInt64Lit}:
        error("maxEmbedBytes must be an integer literal", argument[1])
      maxEmbedBytes = argument[1].intVal.int
    of "denyExts":
      let listNode =
        if argument[1].kind == nnkPrefix:
          argument[1][1]
        else:
          argument[1]
      if listNode.kind != nnkBracket:
        error("denyExts must be a literal list such as @[\".mp4\"]", argument[1])
      denyExts = @[]
      for item in listNode:
        if item.kind != nnkStrLit:
          error("denyExts entries must be string literals", item)
        denyExts.add(item.strVal.toLowerAscii())
    else:
      error("unsupported serveStaticEmbedded option: " & $argument[0], argument)

  var absDir = ""
  try:
    absDir = resolveStaticDir(
      directory, parentDir(instantiationInfo(fullPaths = true).filename)
    )
  except ValueError as exc:
    error(exc.msg)

  let tableSym = genSym(nskVar, "embeddedFiles")
  var assigns = newStmtList()
  try:
    for absPath in walkDirRec(absDir):
      let rel = relativePath(absPath, absDir).replace(DirSep, '/')
      let fileNode = embeddedFileNode(absPath, maxEmbedBytes, denyExts)
      assigns.add(
        newAssignment(newTree(nnkBracketExpr, tableSym, newLit(rel)), fileNode)
      )
  except ValueError as exc:
    error(exc.msg)

  let prefixLit = newLit(prefix)
  result = quote:
    block:
      var `tableSym` = initTable[string, EmbeddedFile]()
      `assigns`
      serveEmbeddedFiles(
        `app`,
        `prefixLit`,
        `tableSym`,
        indexFile = `indexFile`,
        maxAge = `maxAge`,
        allowDotfiles = `allowDotfiles`,
        spaFallback = `spaFallback`,
      )

macro serveSingleEmbeddedFile*(
    app: typed, path: static[string], file: static[string], args: varargs[untyped]
): untyped =
  ## Serves one compile-time file at the exact route ``path``.
  ##
  ## ```nim
  ## app.serveSingleEmbeddedFile("/favicon.ico", "static/favicon.ico")
  ## ```
  var maxAge = newLit(3600)
  var maxEmbedBytes = 1_048_576
  var denyExts: seq[string] = @[]
  for item in defaultDenyExts:
    denyExts.add(item)

  for argument in args:
    if argument.kind != nnkExprEqExpr:
      error("serveSingleEmbeddedFile options must use `name = value`", argument)
    case $argument[0]
    of "maxAge":
      if argument[1].kind notin {nnkIntLit .. nnkUInt64Lit}:
        error("maxAge must be an integer literal", argument[1])
      maxAge = newLit(argument[1].intVal.int)
    of "maxEmbedBytes":
      if argument[1].kind notin {nnkIntLit .. nnkUInt64Lit}:
        error("maxEmbedBytes must be an integer literal", argument[1])
      maxEmbedBytes = argument[1].intVal.int
    of "denyExts":
      let listNode =
        if argument[1].kind == nnkPrefix:
          argument[1][1]
        else:
          argument[1]
      if listNode.kind != nnkBracket:
        error("denyExts must be a literal list such as @[\".mp4\"]", argument[1])
      denyExts = @[]
      for item in listNode:
        if item.kind != nnkStrLit:
          error("denyExts entries must be string literals", item)
        denyExts.add(item.strVal.toLowerAscii())
    else:
      error("unsupported serveSingleEmbeddedFile option: " & $argument[0], argument)

  var absFile = ""
  try:
    absFile =
      resolveStaticFile(file, parentDir(instantiationInfo(fullPaths = true).filename))
  except ValueError as exc:
    error(exc.msg)

  var fileNode: NimNode
  try:
    fileNode = embeddedFileNode(absFile, maxEmbedBytes, denyExts)
  except ValueError as exc:
    error(exc.msg)

  let pathLit = newLit(path)
  result = quote:
    serveSingleEmbedded(`app`, `pathLit`, `fileNode`, maxAge = `maxAge`)
