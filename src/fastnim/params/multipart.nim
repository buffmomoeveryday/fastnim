## Incremental ``multipart/form-data`` request parsing.
##
## File parts stream to temporary files by default. In-memory storage must be
## selected explicitly and is always guarded by ``memorySizeCap``.

import std/[macros, os, parseutils, strutils, tables, tempfiles]

import chronos

import fastnim/context/http
import fastnim/params/uploadsink

const
  DefaultChunkSize = 64 * 1024
  DefaultPartHeadersSize = 8 * 1024

type
  UploadStorage* {.pure.} = enum
    ## Storage used for uploaded file contents.
    Disk = "disk"
    Memory = "memory"
    External = "external"

  UploadContentTypeHook* =
    proc(fieldName, filename, contentType: string): bool {.closure, gcsafe, raises: [].}
    ## Decides whether a file part's declared content type is accepted.

  UploadFileSizeHook* = proc(fieldName, filename, contentType: string): int64 {.
    closure, gcsafe, raises: []
  .} ## Returns the byte limit for a file part, or zero to use ``maxFileSize``.

  UploadLimits* = object
    ## Resource limits enforced while consuming a multipart request.
    ##
    ## These are the inner cap. The application's ``maxBodySize`` is the outer
    ## cap and rejects a larger ``Content-Length`` or buffered body with
    ## ``413`` before this parser runs. Keep ``maxRequestSize`` less than or
    ## equal to ``maxBodySize``.
    maxRequestSize*: int64 ## Maximum encoded request-body bytes.
    maxFileSize*: int64 ## Maximum bytes in any individual file.
    maxFiles*: int ## Maximum number of file parts.
    maxFieldSize*: int64 ## Maximum bytes in any individual non-file field.
    allowContentType*: UploadContentTypeHook ## Optional file-type allowlist hook.
    fileSizeLimit*: UploadFileSizeHook ## Optional per-file size-limit hook.

  MultipartOptions* = object ## Controls multipart parsing and uploaded-file storage.
    storage*: UploadStorage ## Disk by default; memory is explicit opt-in.
    uploadDir*: string ## Directory for disk uploads; empty uses the system temp dir.
    memorySizeCap*: int64 ## Aggregate file-byte cap required by memory mode.
    partHeadersSize*: int ## Maximum bytes in one part's headers.
    chunkSize*: int ## Maximum body chunk requested from the transport.
    limits*: UploadLimits ## Request, file, field, count, and type limits.

  UploadConfig* = object
    ## Declarative settings for one required uploaded file field.
    ##
    ## ``parseUpload`` accepts one configuration directly. Typed upload objects
    ## combine one configuration per ``UploadedFile`` field.
    fieldName*: string ## Required multipart form field name.
    contentTypes*: seq[string] ## Accepted MIME types; empty accepts any type.
    uploadDir*: string ## Directory for disk uploads; empty uses the system temp dir.
    storage*: UploadStorage ## Disk by default; memory is explicit opt-in.
    memorySizeCap*: int64 ## Aggregate byte cap required by memory mode.
    maxRequestSize*: int64 ## Maximum encoded request-body bytes.
    maxFileSize*: int64 ## Maximum file-content bytes.
    maxFieldSize*: int64 ## Maximum bytes in an accompanying non-file field.
    partHeadersSize*: int ## Maximum bytes in one part's headers.
    chunkSize*: int ## Maximum body chunk requested from the transport.

  UploadedFile* = object ## Metadata and storage location for one uploaded file part.
    fieldName*: string ## Multipart form field name.
    filename*: string ## Client-supplied filename, retained only as metadata.
    contentType*: string ## Declared part content type.
    size*: int64 ## Exact number of file-content bytes.
    storage*: UploadStorage ## Storage holding this file's contents.
    path*: string ## Server-generated path in disk mode; empty in memory mode.
    data*: string ## Binary-safe contents in memory mode; empty in disk mode.
    stored*: StoredUpload ## Identity returned by an external upload store.

  MultipartForm* = object ## Parsed multipart fields and uploaded files.
    fields*: Table[string, seq[string]] ## Values grouped by field name.
    files*: seq[UploadedFile] ## File parts in wire order.

  MultipartError* = object of CatchableError ## Invalid or rejected multipart input.
    status*: int ## HTTP status appropriate for this failure.

  ParserState = ref object
    source: RequestBodySource
    buffer: string
    eof: bool
    totalRead: int64
    memoryBytes: int64
    boundary: string
    options: MultipartOptions
    store: UploadStore
    createdPaths: seq[string]
    completedUploads: seq[StoredUpload]

  PartInfo = object
    name: string
    filename: string
    contentType: string
    hasFilename: bool

  PartOutput = ref object
    file: File
    path: string
    fieldValue: string
    memoryValue: string
    size: int64

template upload*(
  fieldName: static[string] = "",
  contentTypes: untyped = [],
  maxFileSize: static[int64] = 10'i64 * 1024 * 1024,
  maxRequestSize: static[int64] = 32'i64 * 1024 * 1024,
  uploadDir: static[string] = "",
  storage: static[UploadStorage] = UploadStorage.Disk,
  memorySizeCap: static[int64] = 0'i64,
  maxFieldSize: static[int64] = 64'i64 * 1024,
  partHeadersSize: static[int] = DefaultPartHeadersSize,
  chunkSize: static[int] = DefaultChunkSize,
) {.pragma.}
  ## Configures an ``UploadedFile`` field for typed ``parseUpload``.
  ##
  ## The multipart field name defaults to the Nim object field name.

proc initUploadLimits*(
    maxRequestSize = 32'i64 * 1024 * 1024,
    maxFileSize = 10'i64 * 1024 * 1024,
    maxFiles = 8,
    maxFieldSize = 64'i64 * 1024,
    allowContentType: UploadContentTypeHook = nil,
    fileSizeLimit: UploadFileSizeHook = nil,
): UploadLimits =
  ## Creates upload limits. Every numeric limit must be positive.
  if maxRequestSize <= 0 or maxFileSize <= 0 or maxFiles <= 0 or maxFieldSize <= 0:
    raise newException(ValueError, "upload limits must be positive")
  UploadLimits(
    maxRequestSize: maxRequestSize,
    maxFileSize: maxFileSize,
    maxFiles: maxFiles,
    maxFieldSize: maxFieldSize,
    allowContentType: allowContentType,
    fileSizeLimit: fileSizeLimit,
  )

proc initMultipartOptions*(
    uploadDir = "",
    storage = UploadStorage.Disk,
    memorySizeCap = 0'i64,
    limits = initUploadLimits(),
    partHeadersSize = DefaultPartHeadersSize,
    chunkSize = DefaultChunkSize,
): MultipartOptions =
  ## Creates multipart options.
  ##
  ## ``UploadStorage.Memory`` is rejected unless ``memorySizeCap`` is positive.
  if storage == UploadStorage.Memory and memorySizeCap <= 0:
    raise newException(ValueError, "memory multipart storage requires a size cap")
  if partHeadersSize < 256:
    raise newException(ValueError, "multipart part header limit must be at least 256")
  if chunkSize < 256:
    raise newException(ValueError, "multipart chunk size must be at least 256")
  MultipartOptions(
    storage: storage,
    uploadDir: uploadDir,
    memorySizeCap: memorySizeCap,
    partHeadersSize: partHeadersSize,
    chunkSize: chunkSize,
    limits: limits,
  )

proc initUploadConfig*(
    fieldName: string,
    contentTypes: openArray[string] = [],
    maxFileSize = 10'i64 * 1024 * 1024,
    maxRequestSize = 32'i64 * 1024 * 1024,
    uploadDir = "",
    storage = UploadStorage.Disk,
    memorySizeCap = 0'i64,
    maxFieldSize = 64'i64 * 1024,
    partHeadersSize = DefaultPartHeadersSize,
    chunkSize = DefaultChunkSize,
): UploadConfig =
  ## Creates declarative settings for one required uploaded file.
  ##
  ## ``contentTypes`` is a MIME allowlist. An empty list accepts any declared
  ## content type. Numeric and storage settings follow ``initMultipartOptions``.
  if fieldName.strip().len == 0:
    raise newException(ValueError, "upload field name cannot be empty")
  for contentType in contentTypes:
    if contentType.strip().len == 0:
      raise newException(ValueError, "upload content types cannot be empty")
  discard initMultipartOptions(
    uploadDir = uploadDir,
    storage = storage,
    memorySizeCap = memorySizeCap,
    limits = initUploadLimits(
      maxRequestSize = maxRequestSize,
      maxFileSize = maxFileSize,
      maxFiles = 1,
      maxFieldSize = maxFieldSize,
    ),
    partHeadersSize = partHeadersSize,
    chunkSize = chunkSize,
  )
  UploadConfig(
    fieldName: fieldName,
    contentTypes: @contentTypes,
    uploadDir: uploadDir,
    storage: storage,
    memorySizeCap: memorySizeCap,
    maxRequestSize: maxRequestSize,
    maxFileSize: maxFileSize,
    maxFieldSize: maxFieldSize,
    partHeadersSize: partHeadersSize,
    chunkSize: chunkSize,
  )

proc firstField*(
    form: MultipartForm, name: string, default = ""
): string {.raises: [].} =
  ## Returns the first value for ``name``, or ``default`` when absent.
  let values = form.fields.getOrDefault(name)
  if values.len == 0:
    default
  else:
    values[0]

iterator files*(form: MultipartForm, fieldName: string): UploadedFile =
  ## Yields uploaded files belonging to ``fieldName``.
  for file in form.files:
    if file.fieldName == fieldName:
      yield file

proc raiseMultipart(status: int, message: string) {.noinline, noreturn.} =
  var error = newException(MultipartError, message)
  error.status = status
  raise error

proc stripQuotes(value: string): string =
  let clean = value.strip()
  if clean.len >= 2 and clean[0] == '"' and clean[^1] == '"':
    result = ""
    var escaped = false
    for ch in clean[1 ..^ 2]:
      if escaped:
        result.add(ch)
        escaped = false
      elif ch == '\\':
        escaped = true
      else:
        result.add(ch)
  else:
    result = clean

proc splitParameters(value: string): seq[string] =
  var start = 0
  var quoted = false
  var escaped = false
  for index, ch in value:
    if escaped:
      escaped = false
    elif quoted and ch == '\\':
      escaped = true
    elif ch == '"':
      quoted = not quoted
    elif ch == ';' and not quoted:
      result.add(value[start ..< index].strip())
      start = index + 1
  result.add(value[start ..^ 1].strip())

proc multipartBoundary(contentType: string): string =
  let parts = splitParameters(contentType)
  if parts.len == 0 or parts[0].toLowerAscii() != "multipart/form-data":
    raiseMultipart(400, "request content type is not multipart/form-data")
  for part in parts[1 ..^ 1]:
    let separator = part.find('=')
    if separator > 0 and part[0 ..< separator].strip().toLowerAscii() == "boundary":
      result = stripQuotes(part[separator + 1 ..^ 1])
      break
  if result.len == 0 or result.len > 70 or '\r' in result or '\n' in result:
    raiseMultipart(400, "multipart boundary is missing or invalid")

proc parsePartInfo(headers: Table[string, string]): PartInfo =
  if "content-disposition" notin headers:
    raiseMultipart(400, "multipart part is missing Content-Disposition")
  let parts = splitParameters(headers["content-disposition"])
  if parts.len == 0 or parts[0].toLowerAscii() != "form-data":
    raiseMultipart(400, "multipart Content-Disposition must be form-data")
  for part in parts[1 ..^ 1]:
    let separator = part.find('=')
    if separator > 0:
      let key = part[0 ..< separator].strip().toLowerAscii()
      let value = stripQuotes(part[separator + 1 ..^ 1])
      case key
      of "name":
        result.name = value
      of "filename":
        result.filename = value
        result.hasFilename = true
      else:
        discard
  if result.name.len == 0:
    raiseMultipart(400, "multipart part name is missing")
  result.contentType = headers.getOrDefault("content-type")
  if result.hasFilename and result.contentType.len == 0:
    result.contentType = "application/octet-stream"

proc parseHeaders(raw: string): Table[string, string] =
  result = initTable[string, string]()
  for line in raw.split("\r\n"):
    let separator = line.find(':')
    if separator <= 0:
      raiseMultipart(400, "malformed multipart part header")
    let name = line[0 ..< separator].strip().toLowerAscii()
    if name in result:
      raiseMultipart(400, "duplicate multipart part header")
    result[name] = line[separator + 1 ..^ 1].strip()

proc readMore(state: ParserState) {.async: (raises: [CatchableError]).} =
  if state.eof:
    return
  let chunk = await state.source.readChunk(state.options.chunkSize)
  if chunk.len == 0:
    state.eof = true
    return
  state.totalRead += chunk.len.int64
  if state.totalRead > state.options.limits.maxRequestSize:
    raiseMultipart(413, "multipart request exceeds the upload size limit")
  state.buffer.add(chunk)

proc takeUntil(
    state: ParserState, marker: string, limit: int
): Future[string] {.async: (raises: [CatchableError]).} =
  while true:
    let markerAt = state.buffer.find(marker)
    if markerAt >= 0:
      if markerAt > limit:
        raiseMultipart(400, "multipart section exceeds its header limit")
      result = state.buffer[0 ..< markerAt]
      state.buffer = state.buffer[markerAt + marker.len ..^ 1]
      return
    if state.buffer.len > limit:
      raiseMultipart(400, "multipart section exceeds its header limit")
    if state.eof:
      raiseMultipart(400, "multipart request ended unexpectedly")
    await state.readMore()

proc removeCreatedFiles(paths: seq[string]) {.raises: [].} =
  for path in paths:
    try:
      if fileExists(path):
        removeFile(path)
    except CatchableError:
      discard

proc writePartChunk(
    state: ParserState,
    info: PartInfo,
    chunk: string,
    sink: UploadSink,
    output: PartOutput,
    fileSizeLimit: int64,
): Future[void] {.async: (raises: [CatchableError]).} =
  if chunk.len == 0:
    return
  output.size += chunk.len.int64
  if info.hasFilename:
    if output.size > fileSizeLimit:
      raiseMultipart(413, "uploaded file exceeds its size limit")
    if not sink.isNil:
      await sink.write(chunk)
    else:
      case state.options.storage
      of UploadStorage.Disk:
        output.file.write(chunk)
      of UploadStorage.Memory:
        state.memoryBytes += chunk.len.int64
        if state.memoryBytes > state.options.memorySizeCap:
          raiseMultipart(413, "buffered uploads exceed the memory size cap")
        output.memoryValue.add(chunk)
      of UploadStorage.External:
        raise newException(ValueError, "external storage requires an upload store")
  else:
    if output.size > state.options.limits.maxFieldSize:
      raiseMultipart(413, "multipart field exceeds its size limit")
    output.fieldValue.add(chunk)

proc consumePart(
    state: ParserState, info: PartInfo
): Future[tuple[file: UploadedFile, fieldValue: string, finished: bool]] {.
    async: (raises: [CatchableError])
.} =
  if info.hasFilename:
    if not state.options.limits.allowContentType.isNil and
        not state.options.limits.allowContentType(
          info.name, info.filename, info.contentType
        ):
      raiseMultipart(415, "uploaded file content type is not allowed")

  var fileSizeLimit = state.options.limits.maxFileSize
  if info.hasFilename and not state.options.limits.fileSizeLimit.isNil:
    let configuredLimit =
      state.options.limits.fileSizeLimit(info.name, info.filename, info.contentType)
    if configuredLimit > 0:
      fileSizeLimit = configuredLimit

  let output = PartOutput()
  var sink: UploadSink
  var stored: StoredUpload
  var sinkCompleted = false
  if info.hasFilename and not state.store.isNil:
    sink = await state.store.begin(
      UploadMetadata(
        fieldName: info.name, filename: info.filename, contentType: info.contentType
      )
    )
  elif info.hasFilename and state.options.storage == UploadStorage.Disk:
    try:
      (output.file, output.path) =
        createTempFile("fastnim-upload-", ".tmp", state.options.uploadDir)
      state.createdPaths.add(output.path)
    except CatchableError as exc:
      raise newException(IOError, "unable to create upload file: " & exc.msg)

  let delimiter = "\r\n--" & state.boundary
  try:
    while true:
      let delimiterAt = state.buffer.find(delimiter)
      if delimiterAt >= 0:
        await state.writePartChunk(
          info, state.buffer[0 ..< delimiterAt], sink, output, fileSizeLimit
        )
        state.buffer = state.buffer[delimiterAt + delimiter.len ..^ 1]
        while state.buffer.len < 2 and not state.eof:
          await state.readMore()
        if state.buffer.startsWith("--"):
          state.buffer = state.buffer[2 ..^ 1]
          if state.buffer.len < 2 and not state.eof:
            await state.readMore()
          if state.buffer.startsWith("\r\n"):
            state.buffer = state.buffer[2 ..^ 1]
          result.finished = true
        elif state.buffer.startsWith("\r\n"):
          state.buffer = state.buffer[2 ..^ 1]
        else:
          raiseMultipart(400, "malformed multipart boundary terminator")
        break

      let keep = delimiter.len - 1
      if state.buffer.len > keep:
        let writable = state.buffer.len - keep
        await state.writePartChunk(
          info, state.buffer[0 ..< writable], sink, output, fileSizeLimit
        )
        state.buffer = state.buffer[writable ..^ 1]
      if state.eof:
        raiseMultipart(400, "multipart request ended before its final boundary")
      await state.readMore()
    if info.hasFilename and not sink.isNil:
      stored = await sink.complete()
      sinkCompleted = true
      state.completedUploads.add(stored)
  except CancelledError as exc:
    if not sink.isNil and not sinkCompleted:
      await sink.abort()
    raise exc
  except CatchableError:
    if not sink.isNil and not sinkCompleted:
      await sink.abort()
    raise
  finally:
    if output.path.len > 0:
      close(output.file)

  result.fieldValue = output.fieldValue
  if info.hasFilename:
    result.file = UploadedFile(
      fieldName: info.name,
      filename: info.filename,
      contentType: info.contentType,
      size: output.size,
      storage: if sink.isNil: state.options.storage else: UploadStorage.External,
      path: output.path,
      data: output.memoryValue,
      stored: stored,
    )

proc parseMultipart*(
    request: Request, options = initMultipartOptions(), store: UploadStore = nil
): Future[MultipartForm] {.async: (raises: [CatchableError]).} =
  ## Parses fields and files from a ``multipart/form-data`` request.
  ##
  ## Disk mode streams file contents into server-generated files. The caller
  ## owns successful files and should move or delete them when no longer needed.
  ## Partial disk files are removed after parse failure or cancellation. When
  ## ``store`` is supplied, files instead stream through its upload sinks;
  ## incomplete sinks are aborted and completed files are rolled back if a
  ## later part fails. A handler timeout cancels this future the same way:
  ## partial disk files are removed and external sinks are aborted. The
  ## application's ``maxBodySize`` can reject the body before parsing starts.
  let boundary = multipartBoundary(request.headers.getOrDefault("content-type"))
  let contentLength = request.headers.getOrDefault("content-length")
  if contentLength.len > 0:
    var declaredSize: BiggestInt
    if parseBiggestInt(contentLength, declaredSize) != contentLength.len or
        declaredSize < 0:
      raiseMultipart(400, "request Content-Length is invalid")
    if declaredSize > options.limits.maxRequestSize:
      raiseMultipart(413, "multipart request exceeds the upload size limit")
  let state = ParserState(boundary: boundary, options: options, store: store)
  if request.hasBodySource():
    state.source = request.beginBodyRead()
  else:
    state.buffer = request.body
    state.totalRead = request.body.len.int64
    state.eof = true
    if state.totalRead > options.limits.maxRequestSize:
      raiseMultipart(413, "multipart request exceeds the upload size limit")

  result = MultipartForm(fields: initTable[string, seq[string]](), files: @[])
  let opening = "--" & boundary & "\r\n"
  try:
    while state.buffer.len < opening.len and not state.eof:
      await state.readMore()
    if not state.buffer.startsWith(opening):
      raiseMultipart(400, "multipart request has an invalid opening boundary")
    state.buffer = state.buffer[opening.len ..^ 1]

    var finished = false
    while not finished:
      let rawHeaders = await state.takeUntil("\r\n\r\n", options.partHeadersSize)
      let info = parsePartInfo(parseHeaders(rawHeaders))
      if info.hasFilename and result.files.len >= options.limits.maxFiles:
        raiseMultipart(413, "multipart request contains too many files")
      let part = await state.consumePart(info)
      if info.hasFilename:
        result.files.add(part.file)
      else:
        result.fields.mgetOrPut(info.name, @[]).add(part.fieldValue)
      finished = part.finished
  except CancelledError as exc:
    removeCreatedFiles(state.createdPaths)
    for upload in state.completedUploads:
      await upload.remove()
    raise exc
  except CatchableError:
    removeCreatedFiles(state.createdPaths)
    for upload in state.completedUploads:
      await upload.remove()
    raise

proc removeUploads(files: seq[UploadedFile]): Future[void] {.async: (raises: []).} =
  for file in files:
    if file.storage == UploadStorage.External:
      await file.stored.remove()
    elif file.path.len > 0:
      removeCreatedFiles(@[file.path])

proc parseUploads*(
    request: Request, configs: seq[UploadConfig], store: UploadStore = nil
): Future[seq[UploadedFile]] {.async: (raises: [CatchableError]).} =
  ## Parses every required file declared by ``configs`` exactly once.
  ##
  ## Each configuration may set its own field name, MIME allowlist, and file
  ## size. Parser storage and request-level settings must match across fields.
  if configs.len == 0:
    raise newException(ValueError, "at least one upload configuration is required")
  let configuredUploads = configs
  let shared = configuredUploads[0]
  var largestFileSize = shared.maxFileSize
  for index, config in configuredUploads:
    if config.fieldName.len == 0:
      raise newException(ValueError, "upload field name cannot be empty")
    for previous in 0 ..< index:
      if configuredUploads[previous].fieldName == config.fieldName:
        raise
          newException(ValueError, "duplicate upload field '" & config.fieldName & "'")
    if config.uploadDir != shared.uploadDir or config.storage != shared.storage or
        config.memorySizeCap != shared.memorySizeCap or
        config.maxRequestSize != shared.maxRequestSize or
        config.maxFieldSize != shared.maxFieldSize or
        config.partHeadersSize != shared.partHeadersSize or
        config.chunkSize != shared.chunkSize:
      raise newException(
        ValueError,
        "typed upload fields must share request, storage, and parser settings",
      )
    largestFileSize = max(largestFileSize, config.maxFileSize)

  let allowConfiguredFile: UploadContentTypeHook = proc(
      fieldName, filename, contentType: string
  ): bool {.gcsafe, raises: [].} =
    discard filename
    for config in configuredUploads:
      if config.fieldName == fieldName:
        return config.contentTypes.len == 0 or contentType in config.contentTypes
    true
  let configuredFileSize: UploadFileSizeHook = proc(
      fieldName, filename, contentType: string
  ): int64 {.gcsafe, raises: [].} =
    discard filename
    discard contentType
    for config in configuredUploads:
      if config.fieldName == fieldName:
        return config.maxFileSize
    0
  let options = initMultipartOptions(
    uploadDir = shared.uploadDir,
    storage = shared.storage,
    memorySizeCap = shared.memorySizeCap,
    limits = initUploadLimits(
      maxRequestSize = shared.maxRequestSize,
      maxFileSize = largestFileSize,
      maxFiles = configuredUploads.len,
      maxFieldSize = shared.maxFieldSize,
      allowContentType = allowConfiguredFile,
      fileSizeLimit = configuredFileSize,
    ),
    partHeadersSize = shared.partHeadersSize,
    chunkSize = shared.chunkSize,
  )
  let form = await request.parseMultipart(options, store)
  for config in configuredUploads:
    var matches = 0
    for file in form.files:
      if file.fieldName == config.fieldName:
        inc(matches)
    if matches != 1:
      await removeUploads(form.files)
      raiseMultipart(
        400, "required upload field '" & config.fieldName & "' must occur exactly once"
      )
  result = form.files

proc parseUpload*(
    request: Request, config: UploadConfig, store: UploadStore = nil
): Future[UploadedFile] {.async: (raises: [CatchableError]).} =
  ## Parses exactly one required file matching ``config``.
  result = (await request.parseUploads(@[config], store))[0]

proc parseTypedUpload[T](
    request: Request, configs: seq[UploadConfig], store: UploadStore, _: typedesc[T]
): Future[T] {.async: (raises: [CatchableError]).} =
  let files = await request.parseUploads(configs, store)
  var configIndex = 0
  for name, field in fieldPairs(result):
    discard name
    when field is UploadedFile:
      let expectedName = configs[configIndex].fieldName
      for file in files:
        if file.fieldName == expectedName:
          field = file
          break
      inc(configIndex)

proc bareUploadField(node: NimNode): NimNode {.compileTime.} =
  result = node
  if result.kind == nnkPragmaExpr:
    result = result[0]
  if result.kind == nnkPostfix and result.len == 2:
    result = result[1]

proc uploadPragma(node: NimNode): NimNode {.compileTime.} =
  if node.kind != nnkPragmaExpr:
    return nil
  for pragma in node[1]:
    if pragma.kind in {nnkCall, nnkCommand} and pragma.len >= 1 and
        eqIdent(pragma[0], "upload"):
      return pragma

proc uploadConfigNode(source: NimNode): NimNode {.compileTime.} =
  let field = bareUploadField(source)
  let pragma = uploadPragma(source)
  result = newCall(bindSym"initUploadConfig")
  if pragma.isNil:
    result.add(newLit($field))
  else:
    if pragma.len < 11:
      error("invalid upload pragma", pragma)
    let configuredName = pragma[1]
    if configuredName.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
        configuredName.strVal.len == 0:
      result.add(newLit($field))
    else:
      result.add(configuredName)
    for index in 2 .. 10:
      result.add(pragma[index])

proc buildTypedUpload(request, model, store: NimNode): NimNode {.compileTime.} =
  let typeDefinition = model.getImpl
  if typeDefinition.kind != nnkTypeDef or typeDefinition.len != 3:
    error("typed parseUpload expects an object type", model)
  let objectType = typeDefinition[2]
  if objectType.kind != nnkObjectTy:
    error("typed parseUpload expects an object type", model)

  let fields = objectType[^1]
  if fields.kind != nnkRecList or fields.len == 0:
    error("typed upload objects must contain at least one UploadedFile field", model)
  var configs = newNimNode(nnkBracket)
  for definition in fields:
    if definition.kind != nnkIdentDefs or definition.len != 3:
      error("typed upload fields must be declared one per line", definition)
    if not eqIdent(definition[^2], "UploadedFile"):
      error("typed upload fields must have type UploadedFile", definition)
    configs.add(uploadConfigNode(definition[0]))

  let configSequence = newTree(nnkPrefix, ident("@"), configs)
  result = newCall(bindSym"parseTypedUpload", request, configSequence, store, model)

macro parseUpload*(request: typed, model: typedesc): untyped =
  ## Parses a typed upload object.
  ##
  ## Every field must be an ``UploadedFile``. Add the ``upload`` pragma to
  ## configure each multipart field name, MIME allowlist, and limits.
  buildTypedUpload(request, model, newNilLit())

macro parseUpload*(request: typed, model: typedesc, store: typed): untyped =
  ## Parses a typed upload object directly into ``store``.
  buildTypedUpload(request, model, store)
