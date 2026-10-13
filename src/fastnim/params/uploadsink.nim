## Storage-neutral streaming upload contracts.
##
## Multipart parsing owns validation and feeds bounded chunks into an
## ``UploadSink``. Storage packages implement ``UploadStore`` without becoming
## dependencies of FastNim core.

import chronos

type
  UploadMetadata* = object ## Metadata known before a file's content is consumed.
    fieldName*: string ## Multipart form field name.
    filename*: string ## Client filename retained only as metadata.
    contentType*: string ## Declared file content type.

  UploadRemoveProc* = proc(): Future[void] {.closure, gcsafe, async: (raises: []).}
    ## Removes a completed upload during rollback or explicit cleanup.

  StoredUpload* = object ## Storage-neutral identity returned after an upload completes.
    provider*: string ## Backend name, such as ``s3``.
    key*: string ## Backend-specific stable object key.
    location*: string ## URI or other displayable object location.
    etag*: string ## Optional backend entity tag or version identifier.
    remove: UploadRemoveProc

  UploadWriteProc* = proc(data: string): Future[void] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .} ## Writes the next binary-safe upload chunk.
  UploadCompleteProc* =
    proc(): Future[StoredUpload] {.closure, gcsafe, async: (raises: [CatchableError]).}
    ## Commits an upload and returns its storage identity.
  UploadAbortProc* = proc(): Future[void] {.closure, gcsafe, async: (raises: []).}
    ## Aborts an incomplete upload without raising.

  UploadSink* = ref object
    ## One stateful upload destination owned by one multipart file part.
    write: UploadWriteProc
    complete: UploadCompleteProc
    abort: UploadAbortProc

  UploadBeginProc* = proc(metadata: UploadMetadata): Future[UploadSink] {.
    closure, gcsafe, async: (raises: [CatchableError])
  .} ## Starts storage for a validated file part.

  UploadStore* = ref object ## Factory for independent streaming upload sinks.
    begin: UploadBeginProc

proc initStoredUpload*(
    provider, key: string, location = "", etag = "", remove: UploadRemoveProc = nil
): StoredUpload =
  ## Creates generic metadata for a completed backend upload.
  StoredUpload(
    provider: provider, key: key, location: location, etag: etag, remove: remove
  )

proc newUploadSink*(
    write: UploadWriteProc, complete: UploadCompleteProc, abort: UploadAbortProc
): UploadSink =
  ## Creates a stateful sink from its lifecycle callbacks.
  if write.isNil or complete.isNil or abort.isNil:
    raise newException(ValueError, "upload sink callbacks cannot be nil")
  UploadSink(write: write, complete: complete, abort: abort)

proc newUploadStore*(begin: UploadBeginProc): UploadStore =
  ## Creates an upload store from a sink factory callback.
  if begin.isNil:
    raise newException(ValueError, "upload store begin callback cannot be nil")
  UploadStore(begin: begin)

proc begin*(
    store: UploadStore, metadata: UploadMetadata
): Future[UploadSink] {.async: (raises: [CatchableError]).} =
  ## Starts a sink for ``metadata``.
  if store.isNil:
    raise newException(ValueError, "upload store cannot be nil")
  result = await store.begin(metadata)
  if result.isNil:
    raise newException(ValueError, "upload store returned a nil sink")

proc write*(
    sink: UploadSink, data: string
): Future[void] {.async: (raises: [CatchableError]).} =
  ## Writes one binary-safe chunk to ``sink``.
  if sink.isNil:
    raise newException(ValueError, "upload sink cannot be nil")
  await sink.write(data)

proc complete*(
    sink: UploadSink
): Future[StoredUpload] {.async: (raises: [CatchableError]).} =
  ## Commits ``sink`` and returns its storage identity.
  if sink.isNil:
    raise newException(ValueError, "upload sink cannot be nil")
  return await sink.complete()

proc abort*(sink: UploadSink): Future[void] {.async: (raises: []).} =
  ## Aborts ``sink``. Calling backend implementations repeatedly must be safe.
  if not sink.isNil:
    await sink.abort()

proc remove*(upload: StoredUpload): Future[void] {.async: (raises: []).} =
  ## Removes a completed upload when its backend supplied cleanup support.
  if not upload.remove.isNil:
    await upload.remove()
