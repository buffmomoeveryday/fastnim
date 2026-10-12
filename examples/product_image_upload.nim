## Product-image upload with bounded-memory multipart parsing.
##
## Run with:
##   nim c -r --path:src examples/product_image_upload.nim
##
## Upload with:
##   curl -F 'image=@product.png' \
##     http://127.0.0.1:8000/products/42/image

import std/[json, os]

import fastnim

const ProductImageDir = "product-images"

createDir(ProductImageDir)

let productImage = initUploadConfig(
  fieldName = "image",
  contentTypes = ["image/jpeg", "image/png"],
  uploadDir = ProductImageDir,
  maxRequestSize = 6 * 1024 * 1024,
  maxFileSize = 5 * 1024 * 1024,
)

let app = initFastNim()

app.post("/products/{productId}/image"):
  let image = await request.parseUpload(productImage)
  json(
    %*{
      "productId": request.pathParam("productId"),
      "filename": image.filename,
      "contentType": image.contentType,
      "size": image.size,
      "storedAs": image.path,
    }
  )

when isMainModule:
  let server = app.serve(maxRequestBodySize = 6 * 1024 * 1024)
  waitFor server.join()
