## Product upload endpoints backed by the optional FastNim S3 plugin.
##
## Compile from the repository root with:
##   nim c --path:src examples/product_image_upload_s3.nim
##
## Configure AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment.
## AWS_SESSION_TOKEN is optional; set S3_ENDPOINT for MinIO-compatible services.
##
## Upload an image and PDF manual to different S3 prefixes with:
##   curl -F 'image=@product.png' -F 'manual=@manual.pdf' \
##     http://127.0.0.1:8000/products/42/assets

import std/[json, os]

import chronos

import fastnim
import fastnim/plugins/s3 as s3ext

let app = initFastNim()

let s3 = s3ext.s3Plugin(
  s3ext.initS3Config(
    bucket = "product-assets",
    region = getEnv("AWS_REGION", "us-east-1"),
    accessKey = getEnv("AWS_ACCESS_KEY_ID"),
    secretKey = getEnv("AWS_SECRET_ACCESS_KEY"),
    sessionToken = getEnv("AWS_SESSION_TOKEN"),
    endpoint = getEnv("S3_ENDPOINT"),
  )
)

app.install:
  s3

type
  ProductImageForm = object
    image* {.upload(
      contentTypes = ["image/jpeg", "image/png"],
      maxRequestSize = 11 * 1024 * 1024,
      maxFileSize = 10 * 1024 * 1024,
    ).}: UploadedFile

  ProductAssetsForm = object
    image* {.upload(
      contentTypes = ["image/jpeg", "image/png"],
      maxRequestSize = 16 * 1024 * 1024,
      maxFileSize = 10 * 1024 * 1024,
    ).}: UploadedFile
    manual* {.upload(
      contentTypes = ["application/pdf"],
      maxRequestSize = 16 * 1024 * 1024,
      maxFileSize = 5 * 1024 * 1024,
    ).}: UploadedFile

app.post("/products/{productId}/image"):
  let productId = request.pathParam("productId")
  
  let image = await s3.upload(
    request,
    ProductImageForm,
    key = "products/" & productId & "/primary",
  )

  return json(
    %*{
      "productId": productId,
      "contentType": image.contentType,
      "size": image.size,
      "objectKey": image.stored.key,
      "location": image.stored.location,
    }
  )

app.post("/products/{productId}/assets"):
  let productId = request.pathParam("productId")
  let assets: ProductAssetsForm = await s3.upload(
    request,
    ProductAssetsForm,
    keys = (
      image: "products/" & productId & "/images/primary",
      manual: "products/" & productId & "/manuals/spec.pdf",
    ),
  )

  return json(
    %*{
      "productId": productId,
      "image": {
        "contentType": assets.image.contentType,
        "size": assets.image.size,
        "objectKey": assets.image.stored.key,
        "location": assets.image.stored.location,
      },
      "manual": {
        "contentType": assets.manual.contentType,
        "size": assets.manual.size,
        "objectKey": assets.manual.stored.key,
        "location": assets.manual.stored.location,
      },
    }
  )

when isMainModule:
  let server = app.serve(maxRequestBodySize = 16 * 1024 * 1024)
  waitFor server.join()
