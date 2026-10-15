import std/[assertions, os, strutils, tables, tempfiles]

import chronos

import fastnim
import fastnim/plugins/s3

type FakeS3 = ref object
  created: seq[S3CreateRequest]
  partSizes: seq[int]
  completed: seq[S3CompleteRequest]
  aborted: seq[S3AbortRequest]
  deleted: seq[S3DeleteRequest]

type S3ProductImageForm = object
  image* {.upload(contentTypes = ["image/png"]).}: UploadedFile

type S3ProductAssetsForm = object
  image* {.upload(contentTypes = ["image/png"]).}: UploadedFile
  manual* {.upload(contentTypes = ["application/pdf"]).}: UploadedFile

static:
  doAssert not compiles(
    default(S3Client).upload(
      default(Request),
      S3ProductAssetsForm,
      keys = (image: "products/42/image"),
    )
  )
  doAssert not compiles(
    default(S3Client).upload(
      default(Request),
      S3ProductAssetsForm,
      keys = (
        image: "products/42/image",
        manual: "products/42/manual",
        preview: "products/42/preview",
      ),
    )
  )

proc fakeTransport(state: FakeS3): S3MultipartTransport =
  let createCb: S3CreateMultipartProc = proc(
      request: S3CreateRequest
  ): Future[string] {.async: (raises: [CatchableError]).} =
    {.cast(gcsafe).}:
      state.created.add(request)
    return "upload-1"
  let partCb: S3UploadPartProc = proc(
      request: S3UploadPartRequest
  ): Future[string] {.async: (raises: [CatchableError]).} =
    {.cast(gcsafe).}:
      state.partSizes.add(request.data.len)
    return "etag-" & $request.partNumber
  let completeCb: S3CompleteMultipartProc = proc(
      request: S3CompleteRequest
  ): Future[S3CompletedObject] {.async: (raises: [CatchableError]).} =
    {.cast(gcsafe).}:
      state.completed.add(request)
    return S3CompletedObject(
      location: "s3://" & request.bucket & "/" & request.key, etag: "complete-etag"
    )
  let abortCb: S3AbortMultipartProc = proc(
      request: S3AbortRequest
  ): Future[void] {.async: (raises: [CatchableError]).} =
    {.cast(gcsafe).}:
      state.aborted.add(request)
  let deleteCb: S3DeleteObjectProc = proc(
      request: S3DeleteRequest
  ): Future[void] {.async: (raises: [CatchableError]).} =
    {.cast(gcsafe).}:
      state.deleted.add(request)
  newS3MultipartTransport(createCb, partCb, completeCb, abortCb, deleteCb)

proc productKey(metadata: UploadMetadata): string {.gcsafe.} =
  "products/42/" & metadata.filename

block streamsUsingBoundedS3Parts:
  let state = FakeS3()
  let store = newS3UploadStore(
    initS3UploadOptions("product-assets", productKey), fakeTransport(state)
  )
  let sink = waitFor store.begin(
    UploadMetadata(fieldName: "image", filename: "front.jpg", contentType: "image/jpeg")
  )
  waitFor sink.write(repeat("a", MinimumS3PartSize + 17))
  let upload = waitFor sink.complete()

  doAssert state.created.len == 1
  doAssert state.created[0].contentType == "image/jpeg"
  doAssert state.partSizes == @[MinimumS3PartSize, 17]
  doAssert state.completed[0].parts ==
    @[
      S3CompletedPart(partNumber: 1, etag: "etag-1"),
      S3CompletedPart(partNumber: 2, etag: "etag-2"),
    ]
  doAssert upload.provider == "s3"
  doAssert upload.key == "products/42/front.jpg"
  doAssert upload.location == "s3://product-assets/products/42/front.jpg"
  doAssert upload.etag == "complete-etag"

  waitFor upload.remove()
  doAssert state.deleted.len == 1

block abortsIncompleteUpload:
  let state = FakeS3()
  let store = newS3UploadStore(
    initS3UploadOptions("product-assets", productKey), fakeTransport(state)
  )
  let sink =
    waitFor store.begin(UploadMetadata(fieldName: "image", filename: "back.jpg"))
  waitFor sink.write("partial")
  waitFor sink.abort()
  waitFor sink.abort()
  doAssert state.aborted.len == 1
  doAssert state.completed.len == 0

block rejectsEmptyMultipartUpload:
  let state = FakeS3()
  let store = newS3UploadStore(
    initS3UploadOptions("product-assets", productKey), fakeTransport(state)
  )
  let sink =
    waitFor store.begin(UploadMetadata(fieldName: "image", filename: "empty.jpg"))
  doAssertRaises ValueError:
    discard waitFor sink.complete()
  waitFor sink.abort()
  doAssert state.completed.len == 0
  doAssert state.aborted.len == 1

block pluginRegistersStore:
  let state = FakeS3()
  let options = initS3UploadOptions("product-assets", productKey)
  let app = initFastNim(logs = false)
  let s3 = s3Plugin(options, fakeTransport(state))
  app.installPlugin(s3)
  doAssert not app.s3UploadStore().isNil

block uploadsParsedDiskFile:
  let state = FakeS3()
  let directory = createTempDir("fastnim-s3-upload-", "")
  let path = directory / "product.png"
  writeFile(path, "image bytes")
  let s3 = s3Plugin(
    initS3UploadOptions("product-assets", productKey), fakeTransport(state)
  )
  let file = UploadedFile(
    fieldName: "image",
    filename: "product.png",
    contentType: "image/png",
    size: 11,
    storage: UploadStorage.Disk,
    path: path,
  )
  let uploaded = waitFor s3.upload(file, key = "products/42/primary.png")
  doAssert uploaded.filename == "product.png"
  doAssert uploaded.stored.provider == "s3"
  doAssert uploaded.stored.key == "products/42/primary.png"
  doAssert state.partSizes == @[11]
  removeFile(path)
  removeDir(directory)

block streamsConfiguredUploadDirectlyToS3:
  const boundary = "fastnim-s3-test"
  let body =
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"image\"; " &
    "filename=\"product.png\"\r\n" &
    "Content-Type: image/png\r\n\r\n" &
    "image bytes\r\n--" & boundary & "--\r\n"
  var headers = initTable[string, string]()
  headers["content-type"] = "multipart/form-data; boundary=" & boundary
  let request = initRequest(HttpMethod.Post, "/upload", headers, body)
  let state = FakeS3()
  let s3 = s3Plugin(
    initS3UploadOptions("product-assets", productKey), fakeTransport(state)
  )
  let uploaded = waitFor s3.upload(
    request, S3ProductImageForm, key = "products/42/primary"
  )

  doAssert state.partSizes == @[11]
  doAssert uploaded.storage == UploadStorage.External
  doAssert uploaded.path.len == 0
  doAssert uploaded.data.len == 0
  doAssert uploaded.stored.key == "products/42/primary"

block streamsTypedFilesToDifferentS3Folders:
  const boundary = "fastnim-s3-assets"
  let body =
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"image\"; " &
    "filename=\"product.png\"\r\n" &
    "Content-Type: image/png\r\n\r\nimage bytes\r\n" &
    "--" & boundary & "\r\n" &
    "Content-Disposition: form-data; name=\"manual\"; " &
    "filename=\"guide.pdf\"\r\n" &
    "Content-Type: application/pdf\r\n\r\npdf bytes\r\n" &
    "--" & boundary & "--\r\n"
  var headers = initTable[string, string]()
  headers["content-type"] = "multipart/form-data; boundary=" & boundary
  let request = initRequest(HttpMethod.Post, "/upload", headers, body)
  let state = FakeS3()
  let s3 = s3Plugin(
    initS3UploadOptions("product-assets", productKey), fakeTransport(state)
  )
  let assets = waitFor s3.upload(
    request,
    S3ProductAssetsForm,
    keys = (
      image: "products/42/images/primary",
      manual: "products/42/manuals/guide.pdf",
    ),
  )

  doAssert assets.image.stored.key == "products/42/images/primary"
  doAssert assets.manual.stored.key == "products/42/manuals/guide.pdf"
  doAssert state.created.len == 2

block validatesConfiguration:
  let state = FakeS3()
  doAssertRaises ValueError:
    discard initS3UploadOptions("", productKey)
  doAssertRaises ValueError:
    discard initS3UploadOptions(
      "product-assets", productKey, partSize = MinimumS3PartSize - 1
    )
  doAssertRaises ValueError:
    discard newS3UploadStore(default(S3UploadOptions), fakeTransport(state))
  doAssertRaises ValueError:
    discard initS3Config("bucket", "us-east-1", "", "secret", productKey)
  let optionsWithoutKey = initS3UploadOptions("product-assets")
  let storeWithoutKey = newS3UploadStore(
    optionsWithoutKey, fakeTransport(state)
  )
  doAssertRaises ValueError:
    discard waitFor storeWithoutKey.begin(
      UploadMetadata(fieldName: "image", filename: "product.png")
    )
  let config = initS3Config(
    bucket = "bucket",
    region = "us-east-1",
    accessKey = "access",
    secretKey = "secret",
    endpoint = "http://127.0.0.1:9000",
  )
  let configuredPlugin = s3Plugin(config)
  let app = initFastNim(logs = false)
  app.installPlugin(configuredPlugin)
  doAssert not app.s3UploadStore().isNil
