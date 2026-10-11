## Benchmark target for `benchmarks/bench.sh`.
##
## Build with: `nim c -d:release --path:src benchmarks/server.nim`
## Run with: `PORT=8090 ./benchmarks/server` (the bench script does this).
##
## Three representative endpoints:
##   GET  /hello          tiny JSON payload (baseline throughput)
##   GET  /items/{itemId} path + query parameter extraction with a JSON echo
##   POST /items          JSON body parsing and serialization

import chronos
import std/[json, os, strutils]

import fastnim

type
  CreateItem = object
    displayName {.jsonName: "display_name".}: string

  CreatedItem = object
    id: int
    displayName {.jsonName: "display_name".}: string

# Framework logs are disabled so results measure request handling,
# not console I/O.
let app = initFastNim(logs = false)

app.get("/hello"):
  %*{"message": "Hello from FastNim"}

app.get("/items/{itemId}"):
  let itemId = request.pathParam("itemId")
  let page = request.queryParam("page", "1")
  let limit = request.queryParam("limit", "20")
  %*{"itemId": itemId, "page": page, "limit": limit}

app.post("/items", body = CreateItem, responses = @[(201, CreatedItem)]):
  created CreatedItem(id: 1, displayName: body.displayName)

let port = getEnv("PORT", "8090").parseInt().uint16
let server = app.serve(port = port)
echo "Benchmark server listening at http://127.0.0.1:" & $port
waitFor server.join()
