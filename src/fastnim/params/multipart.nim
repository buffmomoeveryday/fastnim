## Incremental ``multipart/form-data`` request parsing.
##
## File parts stream to temporary files by default. In-memory storage must be
## selected explicitly and is always guarded by ``memorySizeCap``.

import std/[json, macros, options, os, parseutils, strutils, tables, tempfiles]

import chronos

import ../context/http
import ../core/bytes
import ../params/uploadsink
import ../private/jsonconversion

const
  DefaultChunkSize = 64.KB
  DefaultPartHeadersSize = 8.KB

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
    uploadFieldNames*: seq[string]
      ## When non-empty, only these named parts count as file uploads.
      ## Clients such as Swagger UI often attach ``filename`` to JSON-valued
      ## nested parts; those must still parse as ordinary fields.

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
  maxFileSize: static[int64] = 10.MB,
  maxRequestSize: static[int64] = 32.MB,
  uploadDir: static[string] = "",
  storage: static[UploadStorage] = UploadStorage.Disk,
  memorySizeCap: static[int64] = 0,
  maxFieldSize: static[int64] = 64.KB,
  partHeadersSize: static[int] = DefaultPartHeadersSize,
  chunkSize: static[int] = DefaultChunkSize,
) {.pragma.}
  ## Configures an ``UploadedFile`` field for typed ``parseUpload``.
  ##
  ## The multipart field name defaults to the Nim object field name.
  ## Size limits accept byte helpers such as ``5.MB`` and ``200.KiB``.

proc initUploadLimits*(
    maxRequestSize = 32.MB,
    maxFileSize = 10.MB,
    maxFiles = 8,
    maxFieldSize = 64.KB,
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
    uploadFieldNames: openArray[string] = [],
): MultipartOptions =
  ## Creates multipart options.
  ##
  ## ``UploadStorage.Memory`` is rejected unless ``memorySizeCap`` is positive.
  ## When ``uploadFieldNames`` is non-empty, only matching parts with a
  ## ``filename`` parameter are stored as files.
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
    uploadFieldNames: @uploadFieldNames,
  )

proc isUploadPart(info: PartInfo, options: MultipartOptions): bool =
  ## True when this part should be stored as an uploaded file.
  if not info.hasFilename:
    return false
  if options.uploadFieldNames.len == 0:
    return true
  info.name in options.uploadFieldNames

proc initUploadConfig*(
    fieldName: string,
    contentTypes: openArray[string] = [],
    maxFileSize = 10.MB,
    maxRequestSize = 32.MB,
    uploadDir = "",
    storage = UploadStorage.Disk,
    memorySizeCap = 0'i64,
    maxFieldSize = 64.KB,
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
    asFile: bool,
): Future[void] {.async: (raises: [CatchableError]).} =
  if chunk.len == 0:
    return
  output.size += chunk.len.int64
  if asFile:
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
  let asFile = isUploadPart(info, state.options)
  if asFile:
    if not state.options.limits.allowContentType.isNil and
        not state.options.limits.allowContentType(
          info.name, info.filename, info.contentType
        ):
      raiseMultipart(415, "uploaded file content type is not allowed")

  var fileSizeLimit = state.options.limits.maxFileSize
  if asFile and not state.options.limits.fileSizeLimit.isNil:
    let configuredLimit =
      state.options.limits.fileSizeLimit(info.name, info.filename, info.contentType)
    if configuredLimit > 0:
      fileSizeLimit = configuredLimit

  let output = PartOutput()
  var sink: UploadSink
  var stored: StoredUpload
  var sinkCompleted = false
  if asFile and not state.store.isNil:
    sink = await state.store.begin(
      UploadMetadata(
        fieldName: info.name, filename: info.filename, contentType: info.contentType
      )
    )
  elif asFile and state.options.storage == UploadStorage.Disk:
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
          info, state.buffer[0 ..< delimiterAt], sink, output, fileSizeLimit, asFile
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
          info, state.buffer[0 ..< writable], sink, output, fileSizeLimit, asFile
        )
        state.buffer = state.buffer[writable ..^ 1]
      if state.eof:
        raiseMultipart(400, "multipart request ended before its final boundary")
      await state.readMore()
    if asFile and not sink.isNil:
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
  if asFile:
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
      let asFile = isUploadPart(info, options)
      if asFile and result.files.len >= options.limits.maxFiles:
        raiseMultipart(413, "multipart request contains too many files")
      let part = await state.consumePart(info)
      if asFile:
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

proc removeUploads*(files: seq[UploadedFile]): Future[void] {.async: (raises: []).} =
  ## Removes uploaded files from their disk or external storage.
  ##
  ## Call this when a successfully parsed upload will not be retained. Memory
  ## uploads need no explicit cleanup.
  for file in files:
    if file.storage == UploadStorage.External:
      await file.stored.remove()
    elif file.path.len > 0:
      removeCreatedFiles(@[file.path])

proc parseConfiguredMultipart(
    request: Request, configs: seq[UploadConfig], store: UploadStore = nil
): Future[MultipartForm] {.async: (raises: [CatchableError]).} =
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
  var uploadFieldNames = newSeq[string](configuredUploads.len)
  for index, config in configuredUploads:
    uploadFieldNames[index] = config.fieldName
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
    uploadFieldNames = uploadFieldNames,
  )
  result = await request.parseMultipart(options, store)
  for config in configuredUploads:
    var matches = 0
    for file in result.files:
      if file.fieldName == config.fieldName:
        inc(matches)
    if matches != 1:
      await removeUploads(result.files)
      raiseMultipart(
        400, "required upload field '" & config.fieldName & "' must occur exactly once"
      )

proc parseUploads*(
    request: Request, configs: seq[UploadConfig], store: UploadStore = nil
): Future[seq[UploadedFile]] {.async: (raises: [CatchableError]).} =
  ## Parses every required file declared by ``configs`` exactly once.
  ##
  ## Each configuration may set its own field name, MIME allowlist, and file
  ## size. Parser storage and request-level settings must match across fields.
  result = (await request.parseConfiguredMultipart(configs, store)).files

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

proc parseMultipartValue[T](raw: string, value: var T): bool {.raises: [].} =
  try:
    when T is Option:
      type Item = typeof(value.get())
      var item: Item
      if not parseMultipartValue(raw, item):
        return false
      value = some(item)
    elif T is string:
      value = raw
    elif T is char:
      if raw.len != 1:
        return false
      value = raw[0]
    elif T is bool:
      value = parseBool(raw)
    elif T is SomeInteger:
      value = T(parseBiggestInt(raw))
    elif T is SomeFloat:
      value = T(parseFloat(raw))
    elif T is enum:
      value = parseEnum[T](raw)
    else:
      value = jsonToValue(parseJson(raw), T)
    true
  except CatchableError:
    false

proc parseTypedMultipart[T](
    request: Request,
    configs: seq[UploadConfig],
    inputNames: seq[string],
    _: typedesc[T],
    store: UploadStore = nil,
): Future[T] {.async: (raises: [CatchableError]).} =
  let form = await request.parseConfiguredMultipart(configs, store)
  try:
    for submittedName, submittedValues in form.fields:
      discard submittedValues
      var known = false
      var inputIndex = 0
      for nimName, field in fieldPairs(result):
        discard nimName
        when not (field is UploadedFile):
          if submittedName == inputNames[inputIndex]:
            known = true
            break
          inc(inputIndex)
      if not known:
        raiseMultipart(400, "unexpected multipart field '" & submittedName & "'")

    var configIndex = 0
    var inputIndex = 0
    for nimName, field in fieldPairs(result):
      discard nimName
      when field is UploadedFile:
        let expectedName = configs[configIndex].fieldName
        for file in form.files:
          if file.fieldName == expectedName:
            field = file
            break
        inc(configIndex)
      else:
        let inputName = inputNames[inputIndex]
        inc(inputIndex)
        let values = form.fields.getOrDefault(inputName)
        if values.len == 0:
          when field is Option:
            type Item = typeof(field.get())
            field = none(Item)
          else:
            raiseMultipart(400, "required multipart field '" & inputName & "' is missing")
        elif values.len != 1:
          raiseMultipart(
            400, "multipart field '" & inputName & "' must occur exactly once"
          )
        elif not parseMultipartValue(values[0], field):
          raiseMultipart(400, "invalid multipart field '" & inputName & "'")
  except CatchableError:
    await removeUploads(form.files)
    raise

proc removeTypedUploads*[T](value: T): Future[void] {.async: (raises: []).} =
  ## Removes every direct ``UploadedFile`` field in a typed multipart model.
  var files: seq[UploadedFile]
  for nimName, field in fieldPairs(value):
    discard nimName
    when field is UploadedFile:
      files.add(field)
  await removeUploads(files)

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
        pragma[0].kind in {nnkIdent, nnkSym} and eqIdent(pragma[0], "upload"):
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

proc uploadConfigsNode(
    model: NimNode, requireOnlyUploads: bool
): NimNode {.compileTime.} =
  let typeDefinition = model.getImpl
  if typeDefinition.kind != nnkTypeDef or typeDefinition.len != 3:
    error("typed multipart parsing expects an object type", model)
  let objectType = typeDefinition[2]
  if objectType.kind != nnkObjectTy:
    error("typed multipart parsing expects an object type", model)

  let fields = objectType[^1]
  if fields.kind != nnkRecList or fields.len == 0:
    error("typed upload objects must contain at least one UploadedFile field", model)
  var configs = newNimNode(nnkBracket)
  for definition in fields:
    if definition.kind != nnkIdentDefs or definition.len != 3:
      error("typed multipart fields must be declared one per line", definition)
    if definition[^2].kind in {nnkIdent, nnkSym} and
        eqIdent(definition[^2], "UploadedFile"):
      configs.add(uploadConfigNode(definition[0]))
    elif requireOnlyUploads:
      error("typed upload fields must have type UploadedFile", definition)

  if configs.len == 0:
    error("typed multipart objects must contain at least one UploadedFile field", model)

  newTree(nnkPrefix, ident("@"), configs)

proc multipartInputName(source: NimNode): string {.compileTime.} =
  let field = bareUploadField(source)
  result = $field
  if source.kind != nnkPragmaExpr:
    return
  for pragma in source[1]:
    if pragma.kind in {nnkCall, nnkCommand, nnkExprColonExpr} and pragma.len >= 2 and
        pragma[0].kind in {nnkIdent, nnkSym} and eqIdent(pragma[0], "jsonName"):
      if pragma[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        error("jsonName must be a string literal", pragma)
      result = pragma[1].strVal
      if result.len == 0:
        error("jsonName cannot be empty", pragma)

proc multipartInputNamesNode(model: NimNode): NimNode {.compileTime.} =
  let typeDefinition = model.getImpl
  let fields = typeDefinition[2][^1]
  var names = newNimNode(nnkBracket)
  for definition in fields:
    if definition[^2].kind notin {nnkIdent, nnkSym} or
        not eqIdent(definition[^2], "UploadedFile"):
      names.add(newLit(multipartInputName(definition[0])))
  newTree(nnkPrefix, ident("@"), names)

proc buildTypedUpload(request, model, store: NimNode): NimNode {.compileTime.} =
  let configSequence = uploadConfigsNode(model, true)
  result = newCall(bindSym"parseTypedUpload", request, configSequence, store, model)

macro parseMultipartModel*(request: typed, model: typedesc): untyped =
  ## Parses mixed multipart fields and files into ``model``.
  ##
  ## Direct ``UploadedFile`` fields use their ``upload`` pragma. Scalars use
  ## plain form values, while nested objects and collections use JSON values.
  let configSequence = uploadConfigsNode(model, false)
  let inputNames = multipartInputNamesNode(model)
  newCall(
    bindSym"parseTypedMultipart", request, configSequence, inputNames, model
  )

macro parseMultipartModel*(
    request: typed, model: typedesc, store: typed
): untyped =
  ## Parses a mixed multipart model directly into ``store``.
  let configSequence = uploadConfigsNode(model, false)
  let inputNames = multipartInputNamesNode(model)
  newCall(
    bindSym"parseTypedMultipart", request, configSequence, inputNames, model, store
  )

macro parseUpload*(request: typed, model: typedesc): untyped =
  ## Parses a typed upload object.
  ##
  ## Every field must be an ``UploadedFile``. Add the ``upload`` pragma to
  ## configure each multipart field name, MIME allowlist, and limits.
  buildTypedUpload(request, model, newNilLit())

macro parseUpload*(request: typed, model: typedesc, store: typed): untyped =
  ## Parses a typed upload object directly into ``store``.
  buildTypedUpload(request, model, store)
