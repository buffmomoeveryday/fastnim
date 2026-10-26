import std/[assertions, os, strutils, tables, tempfiles]

import chronos

import fastnim/context/http
import fastnim/params/[multipart, uploadsink]
import fastnim/routing/router
import fastnim/testing

const Boundary = "fastnim-test-boundary"

type FakeUploadState = ref object
  chunks: seq[string]
  completed, aborted, removed: int

type ProductImageForm = object
  image* {.
    upload(
      contentTypes = ["image/jpeg", "image/png"],
      storage = UploadStorage.Memory,
      memorySizeCap = 1024,
      maxRequestSize = 4096,
      maxFileSize = 1024,
    )
  .}: UploadedFile

type ProductAssetsForm = object
  image* {.
    upload(
      contentTypes = ["image/png"],
      storage = UploadStorage.Memory,
      memorySizeCap = 1024,
      maxRequestSize = 4096,
      maxFileSize = 1024,
    )
  .}: UploadedFile
  manual* {.
    upload(
      contentTypes = ["application/pdf"],
      storage = UploadStorage.Memory,
      memorySizeCap = 1024,
      maxRequestSize = 4096,
      maxFileSize = 512,
    )
  .}: UploadedFile

proc newFakeUploadStore(state: FakeUploadState): UploadStore =
  let begin: UploadBeginProc = proc(
      metadata: UploadMetadata
  ): Future[UploadSink] {.async: (raises: [CatchableError]).} =
    let write: UploadWriteProc = proc(
        data: string
    ): Future[void] {.async: (raises: [CatchableError]).} =
      {.cast(gcsafe).}:
        state.chunks.add(data)
    let completeCb: UploadCompleteProc = proc(): Future[StoredUpload] {.
        async: (raises: [CatchableError])
    .} =
      {.cast(gcsafe).}:
        inc(state.completed)
      let removeCb: UploadRemoveProc = proc(): Future[void] {.async: (raises: []).} =
        {.cast(gcsafe).}:
          inc(state.removed)
      return initStoredUpload(
        "fake", metadata.filename, "fake://" & metadata.filename, "etag", removeCb
      )
    let abortCb: UploadAbortProc = proc(): Future[void] {.async: (raises: []).} =
      {.cast(gcsafe).}:
        inc(state.aborted)
    return newUploadSink(write, completeCb, abortCb)
  newUploadStore(begin)

proc multipartBody(parts: openArray[string]): string =
  for part in parts:
    result.add("--" & Boundary & "\r\n")
    result.add(part)
  result.add("--" & Boundary & "--\r\n")

proc fieldPart(name, value: string): string =
  "Content-Disposition: form-data; name=\"" & name & "\"\r\n\r\n" & value & "\r\n"

proc filePart(name, filename, contentType, value: string): string =
  "Content-Disposition: form-data; name=\"" & name & "\"; filename=\"" & filename &
    "\"\r\nContent-Type: " & contentType & "\r\n\r\n" & value & "\r\n"

proc multipartRequest(body: string): Request =
  var headers = initTable[string, string]()
  headers["content-type"] = "multipart/form-data; boundary=\"" & Boundary & "\""
  initRequest(HttpMethod.Post, "/upload", headers, body)

proc removeUpload(path: string) =
  if path.len > 0 and fileExists(path):
    removeFile(path)

block mixedFieldsAndMemoryFile:
  let body = multipartBody(
    [
      fieldPart("title", "Red mug"),
      filePart("image", "mug.png", "image/png", "PNG\0DATA"),
    ]
  )
  let options =
    initMultipartOptions(storage = UploadStorage.Memory, memorySizeCap = 1024)
  let form = waitFor parseMultipart(multipartRequest(body), options)
  doAssert form.firstField("title") == "Red mug"
  doAssert form.files.len == 1
  doAssert form.files[0].fieldName == "image"
  doAssert form.files[0].filename == "mug.png"
  doAssert form.files[0].contentType == "image/png"
  doAssert form.files[0].size == 8
  doAssert form.files[0].data == "PNG\0DATA"

block multipleFilesAndRepeatedFields:
  let body = multipartBody(
    [
      fieldPart("tag", "front"),
      fieldPart("tag", "catalog"),
      filePart("images", "front.jpg", "image/jpeg", "one"),
      filePart("images", "back.jpg", "image/jpeg", "two"),
    ]
  )
  let options =
    initMultipartOptions(storage = UploadStorage.Memory, memorySizeCap = 1024)
  let form = waitFor parseMultipart(multipartRequest(body), options)
  doAssert form.fields["tag"] == @["front", "catalog"]
  doAssert form.files.len == 2
  doAssert form.files[0].filename == "front.jpg"
  doAssert form.files[1].filename == "back.jpg"

block streamsFileToDisk:
  let directory = createTempDir("fastnim-multipart-", "")
  let content = repeat("0123456789abcdef", 128 * 1024)
  let body =
    multipartBody([filePart("image", "large.bin", "application/octet-stream", content)])
  let options = initMultipartOptions(
    uploadDir = directory,
    chunkSize = 4096,
    limits =
      initUploadLimits(maxRequestSize = 3 * 1024 * 1024, maxFileSize = 3 * 1024 * 1024),
  )
  var offset = 0
  var reads = 0
  var largestRead = 0
  let read: BodyReadProc = proc(
      maxBytes: int
  ): Future[string] {.async: (raises: [CatchableError]).} =
    {.cast(gcsafe).}:
      inc(reads)
      largestRead = max(largestRead, maxBytes)
      if offset >= body.len:
        return ""
      let count = min(maxBytes, body.len - offset)
      result = body[offset ..< offset + count]
      offset += count
  let close: BodyCloseProc = proc(): Future[void] {.async: (raises: []).} =
    discard
  var request = multipartRequest("")
  request.attachBodySource(newRequestBodySource(read, close))
  let form = waitFor parseMultipart(request, options)
  waitFor request.closeBodySource()
  doAssert form.files.len == 1
  doAssert form.files[0].storage == UploadStorage.Disk
  doAssert form.files[0].size == content.len
  doAssert readFile(form.files[0].path) == content
  doAssert reads > 100
  doAssert largestRead == 4096
  removeUpload(form.files[0].path)
  removeDir(directory)

block rejectsOversizedFileThroughApplicationBoundary:
  let app = initFastNim(logs = false)
  let options = initMultipartOptions(
    storage = UploadStorage.Memory,
    memorySizeCap = 1024,
    limits = initUploadLimits(maxRequestSize = 4096, maxFileSize = 3),
  )
  app.post("/upload"):
    discard await request.parseMultipart(options)
    text("uploaded")

  let response = app.handleSync(
    multipartRequest(
      multipartBody([filePart("image", "large.png", "image/png", "four")])
    )
  )
  doAssert response.status == 413
  doAssert "size limit" in response.body

block enforcesFileCount:
  let options = initMultipartOptions(
    storage = UploadStorage.Memory,
    memorySizeCap = 1024,
    limits = initUploadLimits(maxFiles = 1),
  )
  let body = multipartBody(
    [
      filePart("image", "one.png", "image/png", "one"),
      filePart("image", "two.png", "image/png", "two"),
    ]
  )
  var rejected = false
  try:
    discard waitFor parseMultipart(multipartRequest(body), options)
  except MultipartError as exc:
    rejected = exc.status == 413
  doAssert rejected

block enforcesContentTypeHook:
  let allowImages: UploadContentTypeHook = proc(
      fieldName, filename, contentType: string
  ): bool {.gcsafe, raises: [].} =
    contentType in ["image/jpeg", "image/png"]
  let options = initMultipartOptions(
    storage = UploadStorage.Memory,
    memorySizeCap = 1024,
    limits = initUploadLimits(allowContentType = allowImages),
  )
  let body =
    multipartBody([filePart("image", "payload.exe", "application/octet-stream", "bad")])
  var rejected = false
  try:
    discard waitFor parseMultipart(multipartRequest(body), options)
  except MultipartError as exc:
    rejected = exc.status == 415
  doAssert rejected

block parsesDeclarativeSingleUpload:
  let config = initUploadConfig(
    fieldName = "image",
    contentTypes = ["image/jpeg", "image/png"],
    storage = UploadStorage.Memory,
    memorySizeCap = 1024,
    maxRequestSize = 4096,
    maxFileSize = 1024,
  )
  let body = multipartBody(
    [
      fieldPart("caption", "Front view"),
      filePart("image", "product.png", "image/png", "image bytes"),
    ]
  )
  let image = waitFor multipartRequest(body).parseUpload(config)
  doAssert image.fieldName == "image"
  doAssert image.filename == "product.png"
  doAssert image.contentType == "image/png"
  doAssert image.data == "image bytes"

block parsesTypedSingleUpload:
  let body =
    multipartBody([filePart("image", "product.png", "image/png", "image bytes")])
  let form = waitFor multipartRequest(body).parseUpload(ProductImageForm)
  doAssert form.image.fieldName == "image"
  doAssert form.image.filename == "product.png"
  doAssert form.image.contentType == "image/png"
  doAssert form.image.data == "image bytes"

block parsesTypedMultipleUploads:
  let body = multipartBody(
    [
      filePart("manual", "guide.pdf", "application/pdf", "pdf bytes"),
      filePart("image", "product.png", "image/png", "image bytes"),
    ]
  )
  let form = waitFor multipartRequest(body).parseUpload(ProductAssetsForm)
  doAssert form.image.filename == "product.png"
  doAssert form.image.data == "image bytes"
  doAssert form.manual.filename == "guide.pdf"
  doAssert form.manual.data == "pdf bytes"

block enforcesPerFieldSizeForMultipleUploads:
  let configs = @[
    initUploadConfig(
      "image",
      storage = UploadStorage.Memory,
      memorySizeCap = 1024,
      maxRequestSize = 4096,
      maxFileSize = 1024,
    ),
    initUploadConfig(
      "manual",
      storage = UploadStorage.Memory,
      memorySizeCap = 1024,
      maxRequestSize = 4096,
      maxFileSize = 3,
    ),
  ]
  let body = multipartBody(
    [
      filePart("image", "product.png", "image/png", "ok"),
      filePart("manual", "guide.pdf", "application/pdf", "four"),
    ]
  )
  var rejected = false
  try:
    discard waitFor multipartRequest(body).parseUploads(configs)
  except MultipartError as exc:
    rejected = exc.status == 413
  doAssert rejected

block declarativeUploadRequiresConfiguredFile:
  let config = initUploadConfig(
    fieldName = "image",
    contentTypes = ["image/png"],
    storage = UploadStorage.Memory,
    memorySizeCap = 1024,
  )
  let body =
    multipartBody([filePart("attachment", "product.png", "image/png", "image bytes")])
  var rejected = false
  try:
    discard waitFor multipartRequest(body).parseUpload(config)
  except MultipartError as exc:
    rejected = exc.status == 400 and "image" in exc.msg
  doAssert rejected

block declarativeUploadEnforcesContentTypes:
  let config = initUploadConfig(
    fieldName = "image",
    contentTypes = ["image/png"],
    storage = UploadStorage.Memory,
    memorySizeCap = 1024,
  )
  let body =
    multipartBody([filePart("image", "product.exe", "application/octet-stream", "bad")])
  var rejected = false
  try:
    discard waitFor multipartRequest(body).parseUpload(config)
  except MultipartError as exc:
    rejected = exc.status == 415
  doAssert rejected

block declarativeUploadValidatesConfiguration:
  doAssertRaises ValueError:
    discard initUploadConfig("")
  doAssertRaises ValueError:
    discard initUploadConfig("image", contentTypes = [""])

block memoryModeRequiresAndEnforcesCap:
  doAssertRaises ValueError:
    discard initMultipartOptions(storage = UploadStorage.Memory)

  let options = initMultipartOptions(storage = UploadStorage.Memory, memorySizeCap = 3)
  let body = multipartBody([filePart("image", "large.png", "image/png", "four")])
  var rejected = false
  try:
    discard waitFor parseMultipart(multipartRequest(body), options)
  except MultipartError as exc:
    rejected = exc.status == 413
  doAssert rejected

block cancellationRemovesPartialDiskFile:
  proc exercise() {.async.} =
    let directory = createTempDir("fastnim-cancel-", "")
    let prefix =
      "--" & Boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"image\"; filename=\"slow.bin\"\r\n" &
      "Content-Type: application/octet-stream\r\n\r\n" & repeat("x", 4096)
    var sent = false
    var closed = false
    let read: BodyReadProc = proc(
        maxBytes: int
    ): Future[string] {.async: (raises: [CatchableError]).} =
      if not sent:
        sent = true
        return prefix
      await sleepAsync(1.hours)
      return ""
    let close: BodyCloseProc = proc(): Future[void] {.async: (raises: []).} =
      closed = true

    var request = multipartRequest("")
    request.attachBodySource(newRequestBodySource(read, close))
    let options = initMultipartOptions(uploadDir = directory, chunkSize = 1024)
    let parsing = parseMultipart(request, options)
    await sleepAsync(20.milliseconds)
    await parsing.cancelAndWait()
    await request.closeBodySource()
    doAssert closed
    var entries = 0
    for kind, path in walkDir(directory):
      discard kind
      discard path
      inc(entries)
    doAssert entries == 0
    removeDir(directory)

  waitFor exercise()

block cancellationAbortsExternalUpload:
  proc exercise() {.async.} =
    let state = FakeUploadState()
    let prefix =
      "--" & Boundary & "\r\n" &
      "Content-Disposition: form-data; name=\"image\"; filename=\"slow.bin\"\r\n" &
      "Content-Type: application/octet-stream\r\n\r\n" & repeat("x", 4096)
    var sent = false
    let read: BodyReadProc = proc(
        maxBytes: int
    ): Future[string] {.async: (raises: [CatchableError]).} =
      if not sent:
        sent = true
        return prefix
      await sleepAsync(1.hours)
      return ""
    let close: BodyCloseProc = proc(): Future[void] {.async: (raises: []).} =
      discard

    var request = multipartRequest("")
    request.attachBodySource(newRequestBodySource(read, close))
    let options = initMultipartOptions(chunkSize = 1024)
    let parsing = parseMultipart(request, options, newFakeUploadStore(state))
    await sleepAsync(20.milliseconds)
    await parsing.cancelAndWait()
    await request.closeBodySource()
    doAssert state.chunks.join().len > 0
    doAssert state.aborted == 1
    doAssert state.completed == 0

  waitFor exercise()

block streamsThroughExternalStore:
  let state = FakeUploadState()
  let options = initMultipartOptions(
    limits = initUploadLimits(maxRequestSize = 4096, maxFileSize = 1024)
  )
  let body =
    multipartBody([filePart("image", "product.png", "image/png", "image bytes")])
  let form =
    waitFor parseMultipart(multipartRequest(body), options, newFakeUploadStore(state))
  doAssert state.chunks.join() == "image bytes"
  doAssert state.completed == 1
  doAssert state.aborted == 0
  doAssert form.files[0].storage == UploadStorage.External
  doAssert form.files[0].stored.provider == "fake"
  doAssert form.files[0].stored.location == "fake://product.png"

block abortsExternalStoreAfterLimitFailure:
  let state = FakeUploadState()
  let options = initMultipartOptions(
    limits = initUploadLimits(maxRequestSize = 4096, maxFileSize = 3)
  )
  let body = multipartBody([filePart("image", "too-large.png", "image/png", "four")])
  var rejected = false
  try:
    discard
      waitFor parseMultipart(multipartRequest(body), options, newFakeUploadStore(state))
  except MultipartError as exc:
    rejected = exc.status == 413
  doAssert rejected
  doAssert state.completed == 0
  doAssert state.aborted == 1

block rollsBackCompletedExternalUploadsAfterLaterFailure:
  let state = FakeUploadState()
  let options = initMultipartOptions(
    limits =
      initUploadLimits(maxRequestSize = 4096, maxFileSize = 1024, maxFieldSize = 3)
  )
  let body = multipartBody(
    [
      filePart("image", "product.png", "image/png", "ok"),
      fieldPart("caption", "too long"),
    ]
  )
  var rejected = false
  try:
    discard
      waitFor parseMultipart(multipartRequest(body), options, newFakeUploadStore(state))
  except MultipartError as exc:
    rejected = exc.status == 413
  doAssert rejected
  doAssert state.completed == 1
  doAssert state.removed == 1
