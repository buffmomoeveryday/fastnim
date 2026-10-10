## Serves a static asset directory, one single file, and embedded assets.
##
## Run with `nim c -r --path:src examples/static.nim`, then visit
## `http://127.0.0.1:8000/static/` and `http://127.0.0.1:8000/`.

import chronos
import fastnim

let app = initFastNim()

# Disk directory with index.html, MIME types, caching, Range, and HEAD.
app.serveStatic("/static", directory = "examples/static")
# Exact-path single file.
app.serveSingleFile("/favicon.ico", "examples/static/favicon.ico")

# Baked into the binary: no asset directory needed at deploy time.
app.serveStaticEmbedded("/embedded", "examples/static")

app.get("/"):
  text("try /static/, /embedded/, and /favicon.ico")

let server = app.serve(port = 8000)
waitFor server.join()
