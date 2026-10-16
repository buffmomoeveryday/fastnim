## Run with: nim c -r --path:src examples/typed_path_params.nim

import std/json

import fastnim

let app = initFastNim()
let cartRouter = initRouter(prefix = "/orders")

cartRouter.patch("/{id:int}/status"):
  ## ``id`` is an ``int``; invalid integer paths do not enter this handler.
  %*{"orderId": id, "updated": true}

cartRouter.get("/{id:positiveInt}/labels/{labels:csv}"):
  ## ``id`` is ``Positive`` and ``labels`` is ``seq[string]``.
  %*{"orderId": id, "labels": labels}

app.addRouter(cartRouter)
let server = app.serve(port = 8080)
waitFor server.join()
