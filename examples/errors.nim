## Standard API errors and application exception mapping.
##
## Run with: ``nim c -r --path:src examples/errors.nim``

import std/tables

import fastnim

let app = initFastNim()

proc missingProduct(request: Request): Response =
  discard request
  raise newNotFoundError("product was not found", code = "product_not_found")

proc duplicateProduct(request: Request): Response =
  discard request
  raise newConflictError(
    "a product with that SKU already exists",
    code = "duplicate_sku",
    fields = {"body.sku": "must be unique"}.toTable,
  )

proc invalidProduct(request: Request): Response =
  discard request
  raise newUnprocessableEntityError(
    "validation failed",
    code = "validation_failed",
    fields = {"body.name": "must not be empty"}.toTable,
  )

proc internalFailure(request: Request): Response =
  discard request
  ## The client receives only the sanitized ``internal_server_error`` envelope.
  raise newException(IOError, "private backend details")

app.get("/products/{id}", missingProduct)
app.post("/products", duplicateProduct)
app.post("/validate", invalidProduct)
app.get("/internal-error", internalFailure)

when isMainModule:
  let server = app.serve(port = 8000)
  waitFor server.join()
