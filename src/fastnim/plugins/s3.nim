## Optional S3 multipart upload plugin for FastNim.
##
## S3-compatible multipart uploads with built-in asynchronous HTTP and SigV4.

import std/[algorithm, macros, strutils, times, uri]

import chronos
import chronos/apps/http/httpclient
import nimcrypto/[sha2, hmac]

import
  ../context/state, ../params/multipart, ../params/uploadsink, ../plugin, ../routing/router
from ../context/http import Request

const
  MinimumS3PartSize* = 5 * 1024 * 1024 ## Smallest non-final part accepted by Amazon S3.
  MaximumS3Parts* = 10_000 ## Maximum number of parts in one S3 multipart upload.

type
  S3KeyBuilder* =
    proc(metadata: UploadMetadata): string {.closure, gcsafe, raises: [CatchableError].}
    ## Produces the object key for one incoming file.

  S3CreateRequest* = object ## Parameters used to begin an S3 multipart upload.
    bucket*: string ## Destination bucket.
    key*: string ## Destination object key.
    contentType*: string ## MIME type assigned to the object.

  S3UploadPartRequest* = object ## Parameters and bytes for one S3 multipart part.
    bucket*: string ## Destination bucket.
    key*: string ## Destination object key.
    uploadId*: string ## Identifier returned by create multipart upload.
    partNumber*: int ## One-based S3 part number.
    data*: string ## Binary-safe part bytes.

  S3CompletedPart* = object ## Identity returned after uploading one S3 part.
    partNumber*: int ## One-based part number.
    etag*: string ## Entity tag returned by S3.

  S3CompleteRequest* = object ## Parameters used to commit an S3 multipart upload.
    bucket*: string ## Destination bucket.
    key*: string ## Destination object key.
    uploadId*: string ## Active multipart upload identifier.
    parts*: seq[S3CompletedPart] ## Uploaded parts in ascending order.

  S3AbortRequest* = object
    ## Parameters used to abort an incomplete S3 multipart upload.
    bucket*: string ## Destination bucket.
    key*: string ## Destination object key.
    uploadId*: string ## Active multipart upload identifier.

  S3DeleteRequest* = object
    ## Parameters used to delete a completed S3 object during rollback.
    bucket*: string ## Destination bucket.
    key*: string ## Destination object key.

  S3CompletedObject* = object ## Metadata returned after S3 commits the object.
    location*: string ## Object URL or URI exposed to the application.
    etag*: string ## Entity tag returned for the completed object.

  S3CreateMultipartProc* = proc(request: S3CreateRequest): Future[string] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .} ## Starts an S3 multipart upload and returns its upload identifier.
  S3UploadPartProc* = proc(request: S3UploadPartRequest): Future[string] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .} ## Uploads one part and returns its entity tag.
  S3CompleteMultipartProc* = proc(request: S3CompleteRequest): Future[S3CompletedObject] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .} ## Commits an S3 multipart upload.
  S3AbortMultipartProc* = proc(request: S3AbortRequest): Future[void] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .} ## Aborts an incomplete S3 multipart upload.
  S3DeleteObjectProc* = proc(request: S3DeleteRequest): Future[void] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .} ## Deletes a completed object.

  S3MultipartTransport* = ref object ## AWS-client adapter used by the S3 upload store.
    createMultipart: S3CreateMultipartProc
    uploadPart: S3UploadPartProc
    completeMultipart: S3CompleteMultipartProc
    abortMultipart: S3AbortMultipartProc
    deleteObject: S3DeleteObjectProc

  S3UploadOptions* = object ## Configuration for a streaming S3 upload store.
    bucket*: string ## Destination bucket.
    partSize*: int ## Maximum buffered bytes and non-final S3 part size.
    key*: S3KeyBuilder ## Application-defined object-key policy.

  S3Config* = object ## Credentials and endpoint settings for the built-in S3 client.
    bucket*: string ## Destination bucket.
    region*: string ## AWS region (also used as the SigV4 signing region).
    accessKey*: string ## AWS access key ID.
    secretKey*: string ## AWS secret access key.
    sessionToken*: string ## Optional temporary-credential token.
    endpoint*: string ## Optional S3-compatible endpoint; defaults to AWS S3.
    partSize*: int ## Maximum in-memory part buffer (minimum 5 MiB).
    key*: S3KeyBuilder ## Application-defined object-key policy.

  S3Client* = ref object ## Configured S3 upload handle returned by ``s3Plugin``.
    options: S3UploadOptions
    transport: S3MultipartTransport
    store: UploadStore
    definition: Plugin

  S3SinkState = ref object
    options: S3UploadOptions
    transport: S3MultipartTransport
    key: string
    uploadId: string
    buffer: string
    parts: seq[S3CompletedPart]
    committed: bool
    aborted: bool

proc newS3MultipartTransport*(
    createMultipart: S3CreateMultipartProc,
    uploadPart: S3UploadPartProc,
    completeMultipart: S3CompleteMultipartProc,
    abortMultipart: S3AbortMultipartProc,
    deleteObject: S3DeleteObjectProc,
): S3MultipartTransport =
  ## Creates an S3 transport from AWS-client adapter callbacks.
  if createMultipart.isNil or uploadPart.isNil or completeMultipart.isNil or
      abortMultipart.isNil or deleteObject.isNil:
    raise newException(ValueError, "S3 transport callbacks cannot be nil")
  S3MultipartTransport(
    createMultipart: createMultipart,
    uploadPart: uploadPart,
    completeMultipart: completeMultipart,
    abortMultipart: abortMultipart,
    deleteObject: deleteObject,
  )

proc initS3UploadOptions*(
    bucket: string, key: S3KeyBuilder = nil, partSize = MinimumS3PartSize
): S3UploadOptions =
  ## Creates S3 upload settings.
  ##
  ## Set ``key`` when all uploads share a key policy, or pass a key builder to
  ## ``upload`` for each request. Key builders should generate
  ## collision-resistant keys and must not trust client filenames as paths.
  ## ``partSize`` is also the sink's memory bound.
  if bucket.strip().len == 0:
    raise newException(ValueError, "S3 bucket cannot be empty")
  if partSize < MinimumS3PartSize:
    raise newException(ValueError, "S3 multipart part size must be at least 5 MiB")
  S3UploadOptions(bucket: bucket, partSize: partSize, key: key)

proc initS3Config*(
    bucket, region, accessKey, secretKey: string,
    key: S3KeyBuilder = nil,
    endpoint = "",
    sessionToken = "",
    partSize = MinimumS3PartSize,
): S3Config =
  ## Creates a built-in S3 client configuration. Set ``endpoint`` for MinIO or
  ## another S3-compatible service. ``key`` is optional when every upload call
  ## supplies its own key builder. Credentials are never read from disk/env.
  if bucket.strip().len == 0 or region.strip().len == 0:
    raise newException(ValueError, "S3 bucket and region cannot be empty")
  if accessKey.len == 0 or secretKey.len == 0:
    raise newException(ValueError, "S3 access and secret keys are required")
  if partSize < MinimumS3PartSize:
    raise newException(ValueError, "S3 multipart part size must be at least 5 MiB")
  S3Config(
    bucket: bucket,
    region: region,
    accessKey: accessKey,
    secretKey: secretKey,
    sessionToken: sessionToken,
    endpoint: endpoint,
    partSize: partSize,
    key: key,
  )

proc validate(options: S3UploadOptions) =
  if options.bucket.strip().len == 0:
    raise newException(ValueError, "S3 bucket cannot be empty")
  if options.partSize < MinimumS3PartSize:
    raise newException(ValueError, "S3 multipart part size must be at least 5 MiB")

proc uploadBufferedPart(state: S3SinkState) {.async: (raises: [CatchableError]).} =
  if state.buffer.len == 0:
    return
  if state.parts.len >= MaximumS3Parts:
    raise newException(ValueError, "S3 multipart upload exceeds 10,000 parts")
  let partNumber = state.parts.len + 1
  let etag = await state.transport.uploadPart(
    S3UploadPartRequest(
      bucket: state.options.bucket,
      key: state.key,
      uploadId: state.uploadId,
      partNumber: partNumber,
      data: state.buffer,
    )
  )
  state.parts.add(S3CompletedPart(partNumber: partNumber, etag: etag))
  state.buffer.setLen(0)

proc writeS3(state: S3SinkState, data: string) {.async: (raises: [CatchableError]).} =
  var offset = 0
  while offset < data.len:
    let count = min(state.options.partSize - state.buffer.len, data.len - offset)
    state.buffer.add(data[offset ..< offset + count])
    offset += count
    if state.buffer.len == state.options.partSize:
      await state.uploadBufferedPart()

proc abortS3(state: S3SinkState) {.async: (raises: []).} =
  if state.aborted or state.committed:
    return
  state.aborted = true
  try:
    await state.transport.abortMultipart(
      S3AbortRequest(
        bucket: state.options.bucket, key: state.key, uploadId: state.uploadId
      )
    )
  except CatchableError:
    discard

proc completeS3(
    state: S3SinkState
): Future[StoredUpload] {.async: (raises: [CatchableError]).} =
  if state.committed:
    raise newException(ValueError, "S3 upload is already complete")
  if state.aborted:
    raise newException(ValueError, "S3 upload is already aborted")
  if state.parts.len == 0 and state.buffer.len == 0:
    raise newException(ValueError, "S3 multipart upload cannot be empty")
  await state.uploadBufferedPart()
  let completed = await state.transport.completeMultipart(
    S3CompleteRequest(
      bucket: state.options.bucket,
      key: state.key,
      uploadId: state.uploadId,
      parts: state.parts,
    )
  )
  state.committed = true
  let removeCb: UploadRemoveProc = proc(): Future[void] {.async: (raises: []).} =
    try:
      await state.transport.deleteObject(
        S3DeleteRequest(bucket: state.options.bucket, key: state.key)
      )
    except CatchableError:
      discard
  return initStoredUpload("s3", state.key, completed.location, completed.etag, removeCb)

proc beginS3(
    options: S3UploadOptions,
    transport: S3MultipartTransport,
    metadata: UploadMetadata,
    keyOverride = "",
): Future[UploadSink] {.async: (raises: [CatchableError]).} =
  var objectKey = keyOverride
  if objectKey.len == 0:
    if options.key.isNil:
      raise newException(
        ValueError,
        "S3 object key is required; configure a key builder or pass one to upload",
      )
    objectKey = options.key(metadata)
  if objectKey.len == 0:
    raise newException(ValueError, "S3 object key cannot be empty")
  let uploadId = await transport.createMultipart(
    S3CreateRequest(
      bucket: options.bucket, key: objectKey, contentType: metadata.contentType
    )
  )
  if uploadId.len == 0:
    raise newException(IOError, "S3 returned an empty multipart upload ID")
  let state = S3SinkState(
    options: options, transport: transport, key: objectKey, uploadId: uploadId
  )
  let writeCb: UploadWriteProc = proc(
      data: string
  ): Future[void] {.async: (raises: [CatchableError]).} =
    await state.writeS3(data)
  let completeCb: UploadCompleteProc = proc(): Future[StoredUpload] {.
      async: (raises: [CatchableError])
  .} =
    return await state.completeS3()
  let abortCb: UploadAbortProc = proc(): Future[void] {.async: (raises: []).} =
    await state.abortS3()
  return newUploadSink(writeCb, completeCb, abortCb)

proc newS3UploadStore*(
    options: S3UploadOptions, transport: S3MultipartTransport
): UploadStore =
  ## Creates a bounded-memory FastNim upload store backed by S3 multipart upload.
  if transport.isNil:
    raise newException(ValueError, "S3 transport cannot be nil")
  options.validate()
  let beginCb: UploadBeginProc = proc(
      metadata: UploadMetadata
  ): Future[UploadSink] {.async: (raises: [CatchableError]).} =
    return await beginS3(options, transport, metadata)
  newUploadStore(beginCb)

proc hexDigest(value: string): string =
  $sha256.digest(value)

proc hmacBytes(key, value: string): string =
  let digest = sha256.hmac(key, value)
  result = newString(digest.data.len)
  for i, b in digest.data:
    result[i] = char(b)

proc uriEncode(value: string, keepSlash = false): string =
  const Hex = "0123456789ABCDEF"
  for ch in value:
    if ch in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '-', '_', '.', '~'} or
        (keepSlash and ch == '/'):
      result.add(ch)
    else:
      let b = byte(ch)
      result.add('%')
      result.add(Hex[int(b shr 4)])
      result.add(Hex[int(b and 0x0F)])

proc xmlEscape(value: string): string =
  for ch in value:
    case ch
    of '&':
      result.add("&amp;")
    of '<':
      result.add("&lt;")
    of '>':
      result.add("&gt;")
    of '"':
      result.add("&quot;")
    of '\'':
      result.add("&apos;")
    else:
      result.add(ch)

proc signedRequest(
    config: S3Config,
    session: HttpSessionRef,
    httpMethod: HttpMethod,
    key, query, body, contentType: string,
): Future[tuple[body, etag: string, location: string]] {.
    async: (raises: [CatchableError])
.} =
  let base =
    if config.endpoint.len > 0:
      config.endpoint.strip(chars = {'/'})
    else:
      "https://s3." & config.region & ".amazonaws.com"
  let parsed = parseUri(base)
  if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0:
    raise newException(ValueError, "invalid S3 endpoint: " & base)
  let pathPrefix = parsed.path.strip(chars = {'/'})
  let path =
    "/" & (if pathPrefix.len > 0: pathPrefix & "/" else: "") & uriEncode(config.bucket) &
    "/" & uriEncode(key, keepSlash = true)
  let canonicalQuery = query
  let nowUtc = now().utc
  let amzDate = nowUtc.format("yyyyMMdd'T'HHmmss'Z'")
  let shortDate = nowUtc.format("yyyyMMdd")
  let host = parsed.hostname & (if parsed.port.len > 0: ":" & parsed.port
  else: "")
  let root = parsed.scheme & "://" & host
  let target = root & path & (if query.len > 0: "?" & query else: "")
  let payloadHash = hexDigest(body)
  var canonicalHeaders =
    "host:" & host & "\n" & "x-amz-content-sha256:" & payloadHash & "\n" & "x-amz-date:" &
    amzDate & "\n"
  var signedHeaders = "host;x-amz-content-sha256;x-amz-date"
  if contentType.len > 0:
    canonicalHeaders.add("content-type:" & contentType.strip() & "\n")
    signedHeaders.add(";content-type")
  if config.sessionToken.len > 0:
    canonicalHeaders.add("x-amz-security-token:" & config.sessionToken & "\n")
    signedHeaders.add(";x-amz-security-token")
  # Include x-amz headers in canonical order (content-type is alphabetically
  # before host, so rebuild the list in sorted order).
  var headerPairs =
    @[("host", host), ("x-amz-content-sha256", payloadHash), ("x-amz-date", amzDate)]
  if contentType.len > 0:
    headerPairs.add(("content-type", contentType.strip()))
  if config.sessionToken.len > 0:
    headerPairs.add(("x-amz-security-token", config.sessionToken))
  headerPairs.sort(
    proc(a, b: (string, string)): int =
      cmp(a[0], b[0])
  )
  canonicalHeaders.setLen(0)
  signedHeaders.setLen(0)
  for pair in headerPairs:
    canonicalHeaders.add(pair[0] & ":" & pair[1] & "\n")
    if signedHeaders.len > 0:
      signedHeaders.add(';')
    signedHeaders.add(pair[0])
  let canonicalRequest =
    $httpMethod & "\n" & path & "\n" & canonicalQuery & "\n" & canonicalHeaders & "\n" &
    signedHeaders & "\n" & payloadHash
  let scope = shortDate & "/" & config.region & "/s3/aws4_request"
  let toSign =
    "AWS4-HMAC-SHA256\n" & amzDate & "\n" & scope & "\n" & hexDigest(canonicalRequest)
  let kDate = hmacBytes("AWS4" & config.secretKey, shortDate)
  let kRegion = hmacBytes(kDate, config.region)
  let kService = hmacBytes(kRegion, "s3")
  let kSigning = hmacBytes(kService, "aws4_request")
  let signature = sha256.hmac(kSigning, toSign)
  var authorization =
    "AWS4-HMAC-SHA256 Credential=" & config.accessKey & "/" & scope & ", SignedHeaders=" &
    signedHeaders & ", Signature=" & $signature
  var headers = @[
    ("host", host),
    ("x-amz-content-sha256", payloadHash),
    ("x-amz-date", amzDate),
    ("authorization", authorization),
  ]
  if contentType.len > 0:
    headers.add(("content-type", contentType))
  if config.sessionToken.len > 0:
    headers.add(("x-amz-security-token", config.sessionToken))
  var bodyBytes = newSeq[byte](body.len)
  for i, ch in body:
    bodyBytes[i] = byte(ch)
  let addressResult = getHttpAddress(target)
  if addressResult.isErr:
    raise newException(IOError, "unable to construct S3 request: " & $addressResult.error)
  let request = HttpClientRequestRef.new(
    session, addressResult.get(), httpMethod, headers = headers, body = bodyBytes
  )
  let response = await request.send()
  let responseEtag =
    if "etag" in response.headers:
      response.headers.getString("etag")
    else:
      ""
  let status = response.status
  let responseBytes = await response.getBodyBytes()
  var responseText = newString(responseBytes.len)
  for i, ch in responseBytes:
    responseText[i] = char(ch)
  if status < 200 or status >= 300:
    raise
      newException(IOError, "S3 request failed (HTTP " & $status & "): " & responseText)
  return (responseText, responseEtag, root & path)

proc builtInTransport(config: S3Config): S3MultipartTransport =
  let session = HttpSessionRef.new()
  let createCb: S3CreateMultipartProc = proc(
      request: S3CreateRequest
  ): Future[string] {.async: (raises: [CatchableError]).} =
    let response = await signedRequest(
      config, session, MethodPost, request.key, "uploads=", "", request.contentType
    )
    let start = response.body.find("<UploadId>")
    let ending = response.body.find("</UploadId>")
    if start < 0 or ending <= start:
      raise newException(IOError, "S3 did not return an UploadId")
    return response.body[start + 10 ..< ending]
  let partCb: S3UploadPartProc = proc(
      request: S3UploadPartRequest
  ): Future[string] {.async: (raises: [CatchableError]).} =
    let response = await signedRequest(
      config,
      session,
      MethodPut,
      request.key,
      "partNumber=" & $request.partNumber & "&uploadId=" & uriEncode(request.uploadId),
      request.data,
      "application/octet-stream",
    )
    if response.etag.len == 0:
      raise newException(IOError, "S3 UploadPart response did not include ETag")
    return response.etag
  let completeCb: S3CompleteMultipartProc = proc(
      request: S3CompleteRequest
  ): Future[S3CompletedObject] {.async: (raises: [CatchableError]).} =
    var xml = "<CompleteMultipartUpload>"
    for part in request.parts:
      xml.add(
        "<Part><PartNumber>" & $part.partNumber & "</PartNumber><ETag>" &
          xmlEscape(part.etag) & "</ETag></Part>"
      )
    xml.add("</CompleteMultipartUpload>")
    let response = await signedRequest(
      config,
      session,
      MethodPost,
      request.key,
      "uploadId=" & uriEncode(request.uploadId),
      xml,
      "application/xml",
    )
    if "<Error>" in response.body or "<ErrorResponse>" in response.body:
      raise newException(
        IOError, "S3 failed to complete multipart upload: " & response.body
      )
    var etag = response.etag
    if etag.len == 0:
      let start = response.body.find("<ETag>")
      let ending = response.body.find("</ETag>")
      if start >= 0 and ending > start:
        etag = response.body[start + 6 ..< ending]
    return S3CompletedObject(location: response.location, etag: etag)
  let abortCb: S3AbortMultipartProc = proc(
      request: S3AbortRequest
  ): Future[void] {.async: (raises: [CatchableError]).} =
    discard await signedRequest(
      config,
      session,
      MethodDelete,
      request.key,
      "uploadId=" & uriEncode(request.uploadId),
      "",
      "",
    )
  let deleteCb: S3DeleteObjectProc = proc(
      request: S3DeleteRequest
  ): Future[void] {.async: (raises: [CatchableError]).} =
    discard await signedRequest(config, session, MethodDelete, request.key, "", "", "")
  newS3MultipartTransport(createCb, partCb, completeCb, abortCb, deleteCb)

proc s3Plugin*(
    options: S3UploadOptions, transport: S3MultipartTransport, name = "s3"
): S3Client =
  ## Creates an installable S3 plugin and upload handle.
  ##
  ## Install the returned handle with ``app.installPlugin(s3)``. The same handle can
  ## then upload parsed ``UploadedFile`` values with ``s3.upload(file)``.
  result = S3Client(
    options: options, transport: transport, store: newS3UploadStore(options, transport)
  )
  let uploadStore = result.store
  result.definition = initPlugin(
    name,
    "0.1.0",
    proc(app: Application) =
      app.pluginContext(name).setContext("store", uploadStore),
  )

proc s3Plugin*(config: S3Config, name = "s3"): S3Client =
  ## Creates an S3 plugin with built-in SigV4 signing and Chronos HTTP.
  let options = initS3UploadOptions(config.bucket, config.key, config.partSize)
  result = s3Plugin(options, builtInTransport(config), name)

proc installPlugin*(app: Application, client: S3Client) =
  ## Installs an S3 plugin handle returned by ``s3Plugin``.
  if client.isNil:
    raise newException(ValueError, "S3 client cannot be nil")
  app.installPlugin(client.definition)

proc upload*(
    client: S3Client, file: UploadedFile, key = ""
): Future[UploadedFile] {.async: (raises: [CatchableError]).} =
  ## Streams a parsed disk or memory upload to S3 and returns it with storage
  ## metadata attached. ``key`` optionally overrides the configured key builder.
  ##
  ## External files already stored by this S3 client are returned unchanged.
  if client.isNil:
    raise newException(ValueError, "S3 client cannot be nil")
  if file.storage == UploadStorage.External:
    if file.stored.provider == "s3":
      return file
    raise newException(ValueError, "file belongs to another external store")
  if file.size <= 0:
    raise newException(ValueError, "cannot upload an empty file to S3")

  let metadata = UploadMetadata(
    fieldName: file.fieldName, filename: file.filename, contentType: file.contentType
  )
  let sink = await beginS3(client.options, client.transport, metadata, key)
  var input: File
  var inputOpen = false
  try:
    if file.path.len > 0:
      if not open(input, file.path, fmRead):
        raise newException(IOError, "unable to open uploaded file for S3")
      inputOpen = true
      while true:
        var chunk = newString(64 * 1024)
        let count = readBuffer(input, addr chunk[0], chunk.len)
        if count <= 0:
          break
        chunk.setLen(count)
        await sink.write(chunk)
    elif file.data.len > 0:
      var offset = 0
      while offset < file.data.len:
        let ending = min(offset + 64 * 1024, file.data.len)
        await sink.write(file.data[offset ..< ending])
        offset = ending
    else:
      raise newException(ValueError, "uploaded file has no readable contents")

    result = file
    result.stored = await sink.complete()
  except CancelledError as exc:
    await sink.abort()
    raise exc
  except CatchableError:
    await sink.abort()
    raise
  finally:
    if inputOpen:
      close(input)

proc requestUploadStore(client: S3Client, key: S3KeyBuilder): UploadStore =
  if client.isNil:
    raise newException(ValueError, "S3 client cannot be nil")
  let beginCb: UploadBeginProc = proc(
      metadata: UploadMetadata
  ): Future[UploadSink] {.async: (raises: [CatchableError]).} =
    let objectKey =
      if key.isNil:
        ""
      else:
        key(metadata)
    return await beginS3(client.options, client.transport, metadata, objectKey)
  newUploadStore(beginCb)

proc requestUploadStore(client: S3Client, key: string): UploadStore =
  if key.len == 0:
    raise newException(ValueError, "S3 object key cannot be empty")
  let fixedKey = key
  let keyBuilder: S3KeyBuilder = proc(
      metadata: UploadMetadata
  ): string {.gcsafe, raises: [].} =
    discard metadata
    fixedKey
  client.requestUploadStore(keyBuilder)

proc upload*(
    client: S3Client, request: Request, config: UploadConfig, key: S3KeyBuilder = nil
): Future[UploadedFile] {.async: (raises: [CatchableError]).} =
  ## Parses one configured file and streams it directly into S3.
  ##
  ## ``key`` optionally overrides the client's configured key builder. No
  ## intermediate disk or in-memory copy is created by the multipart parser.
  result = await request.parseUpload(config, client.requestUploadStore(key))

proc upload*(
    client: S3Client, request: Request, config: UploadConfig, key: string
): Future[UploadedFile] {.async: (raises: [CatchableError]).} =
  ## Parses one configured file and streams it directly to the exact S3 key.
  ##
  ## S3 objects do not require filename extensions because their content type
  ## is stored as object metadata. Use the key-builder overload only when the
  ## key itself depends on upload metadata.
  result = await request.parseUpload(config, client.requestUploadStore(key))

proc singleUploadedFile[T](
    form: Future[T]
): Future[UploadedFile] {.async: (raises: [CatchableError]).} =
  let parsed = await form
  for name, field in fieldPairs(parsed):
    discard name
    when field is UploadedFile:
      return field
  raise newException(ValueError, "typed upload object has no UploadedFile field")

proc typedUploadFieldCount(model: NimNode): int {.compileTime.} =
  let definition = model.getImpl
  if definition.kind == nnkTypeDef and definition.len == 3 and
      definition[2].kind == nnkObjectTy and definition[2][^1].kind == nnkRecList:
    definition[2][^1].len
  else:
    0

proc bareTypedUploadField(node: NimNode): NimNode {.compileTime.} =
  result = node
  if result.kind == nnkPragmaExpr:
    result = result[0]
  if result.kind == nnkPostfix and result.len == 2:
    result = result[1]

proc typedUploadFieldName(source: NimNode): NimNode {.compileTime.} =
  let field = bareTypedUploadField(source)
  result = newLit($field)
  if source.kind != nnkPragmaExpr:
    return
  for pragma in source[1]:
    if pragma.kind in {nnkCall, nnkCommand} and pragma.len >= 2 and
        eqIdent(pragma[0], "upload"):
      let configuredName = pragma[1]
      if configuredName.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit} or
          configuredName.strVal.len > 0:
        result = configuredName
      return

proc typedUploadFields(
    model: NimNode
): seq[tuple[name: string, uploadName: NimNode]] {.compileTime.} =
  let definition = model.getImpl
  if definition.kind != nnkTypeDef or definition.len != 3 or
      definition[2].kind != nnkObjectTy:
    error("typed S3 upload expects an object type", model)
  let fields = definition[2][^1]
  if fields.kind != nnkRecList or fields.len == 0:
    error("typed S3 upload expects at least one upload field", model)
  for field in fields:
    if field.kind != nnkIdentDefs or field.len != 3:
      error("typed upload fields must be declared one per line", field)
    result.add(
      (
        name: $bareTypedUploadField(field[0]),
        uploadName: typedUploadFieldName(field[0]),
      )
    )

proc buildTypedS3Upload(client, request, model, key: NimNode): NimNode {.compileTime.} =
  let store = newCall(bindSym"requestUploadStore", client, key)
  let parsed = newCall(bindSym"parseUpload", request, model, store)
  if typedUploadFieldCount(model) == 1:
    newCall(bindSym"singleUploadedFile", parsed)
  else:
    parsed

proc buildTypedS3UploadWithKeys(
    client, request, model, keys: NimNode
): NimNode {.compileTime.} =
  if keys.kind != nnkTupleConstr:
    error(
      "S3 upload keys must be a named tuple, for example " &
        "(image: \"products/1/image\", manual: \"products/1/manual\")",
      keys,
    )

  let fields = typedUploadFields(model)
  var configured: seq[tuple[name: string, value: NimNode]]
  for entry in keys:
    if entry.kind != nnkExprColonExpr or entry[0].kind notin {nnkIdent, nnkSym}:
      error("each S3 upload key must use a typed field name", entry)
    let name = $entry[0]
    var known = false
    for field in fields:
      if field.name == name:
        known = true
        break
    if not known:
      error("unknown typed upload field '" & name & "'", entry[0])
    for item in configured:
      if item.name == name:
        error("duplicate S3 key for upload field '" & name & "'", entry[0])
    configured.add((name: name, value: entry[1]))

  let metadata = genSym(nskParam, "metadata")
  var keyCase = newTree(nnkCaseStmt, newTree(nnkDotExpr, metadata, ident("fieldName")))
  for field in fields:
    var value: NimNode
    for item in configured:
      if item.name == field.name:
        value = item.value
        break
    if value.isNil:
      error("missing S3 key for upload field '" & field.name & "'", keys)
    keyCase.add(newTree(nnkOfBranch, field.uploadName, newStmtList(value)))

  let missingKey = quote:
    raise newException(
      ValueError, "no S3 key configured for upload field '" & `metadata`.fieldName & "'"
    )
  keyCase.add(newTree(nnkElse, missingKey))

  let keyBuilder = genSym(nskLet, "keyBuilder")
  let callback = newTree(
    nnkLambda,
    newEmptyNode(),
    newEmptyNode(),
    newEmptyNode(),
    newTree(
      nnkFormalParams, ident("string"), newIdentDefs(metadata, bindSym"UploadMetadata")
    ),
    newEmptyNode(),
    newEmptyNode(),
    newStmtList(keyCase),
  )
  let declaration =
    newTree(nnkLetSection, newIdentDefs(keyBuilder, bindSym"S3KeyBuilder", callback))
  result = newTree(
    nnkBlockStmt,
    newEmptyNode(),
    newStmtList(declaration, buildTypedS3Upload(client, request, model, keyBuilder)),
  )

macro upload*(client: typed, request: typed, model: typedesc): untyped =
  ## Streams a typed schema using the configured key policy.
  ##
  ## A one-file schema returns ``UploadedFile``. A multi-file schema returns
  ## the populated typed object.
  buildTypedS3Upload(client, request, model, newNilLit())

macro upload*(client: typed, request: typed, model: typedesc, key: typed): untyped =
  ## Streams a typed schema using an exact key or metadata-dependent builder.
  ##
  ## A one-file schema returns ``UploadedFile``. A multi-file schema returns
  ## the populated typed object.
  buildTypedS3Upload(client, request, model, key)

macro upload*(
    client: typed, request: typed, model: typedesc, args: varargs[untyped]
): untyped =
  ## Streams a typed schema using a named tuple of per-field S3 keys.
  ##
  ## Write ``keys = (image: "products/1/image", manual: "products/1/manual")``.
  ## Every field in the typed schema must have exactly one key. Field names are
  ## checked at compile time.
  if args.len != 1 or args[0].kind != nnkExprEqExpr or not eqIdent(args[0][0], "keys"):
    error("expected one named keys argument", args)
  buildTypedS3UploadWithKeys(client, request, model, args[0][1])

proc s3UploadStore*(app: Application, pluginName = "s3"): UploadStore =
  ## Returns the upload store registered by ``s3Plugin``.
  app.pluginContext(pluginName).get("store", UploadStore)
