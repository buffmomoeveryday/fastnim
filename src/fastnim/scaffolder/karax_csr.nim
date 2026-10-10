## Client-rendered Karax project scaffolding for ``fastnim init``.
##
## Generates a Nim server that serves a static shell plus a JSON API, and a
## Karax client (``client/app.nim``) compiled with ``nim js``. Karax stays a
## dependency of the generated project, not of fastnim.

import std/[os, strutils]

proc writeCsrFile(path, content: string) =
  createDir(path.parentDir())
  writeFile(path, content)

proc csrNimble(name: string): string =
  """# Package

version = "0.1.0"
author = "you"
description = """" & name &
    """ - FastNim + Karax CSR"
license = "MIT"
srcDir = "src"

# Dependencies

requires "nim >= 2.2.12"
requires "chronos >= 4.0.0"
requires "karax >= 1.5.0"
# Install fastnim from its repository until it is published on nimble.
requires "fastnim >= 0.1.0"

task client, "Build the Karax client bundle into public/assets":
  exec "nim js -o:public/assets/app.js client/app.nim"
"""

proc csrApi(name: string): string =
  """## JSON endpoints consumed by the Karax client.

import fastnim

type Greeting* = object
  ## Greeting payload fetched by the client.
  message*: string

let apiRouter* = initRouter(prefix = "/api", tags = @["api"])

apiRouter.get("/hello", responses = @[(200, Greeting)]):
  ok Greeting(message: "Hello from """ &
    name & """!")
"""

proc csrMain(name: string): string =
  """## """ & name & """ - FastNim + Karax CSR.
##
## Build the client first, then run the server:
##   nimble client
##   nim c -r --path:src src/main.nim

import chronos

import fastnim
import routes/api

let web = initFastNim()
web.serveSingleFile("/", "public/index.html")
web.serveStatic("/assets", directory = "public/assets")
web.addRouter(apiRouter)

let server = web.serve(port = 8000)
echo "Listening at http://127.0.0.1:8000"
waitFor server.join()
"""

proc csrClient(name: string): string =
  result = """## Karax client. Build with `nimble client`
## (`nim js -o:public/assets/app.js client/app.nim`).
import std/[asyncjs, jsfetch, json, sugar]
import karax/[karax, karaxdsl, kdom, vdom]

var count = 0
var greeting = "press the button below"

proc loadGreeting(ev: Event; n: VNode) =
  discard fetch(cstring"/api/hello").then(proc(res: Response): Future[cstring] =
    res.text()
  ).then(proc(body: cstring) =
    greeting = parseJson($body)["message"].getStr()
    redraw()
  )

proc render(): VNode =
  result = buildHtml(tdiv):
    h1:
      text "CSRNAME (Karax CSR)"
    p:
      text "Counter (local state, no server round-trip): " & $count
    p:
      button(onclick = () => (inc count)):
        text "+1"
      button(onclick = () => (dec count)):
        text "-1"
    p:
      text "Server says: " & greeting
    p:
      button(onclick = loadGreeting):
        text "Ask the server"

setRenderer render
"""
  result = result.replace("CSRNAME", name)

proc csrIndex(name: string): string =
  """<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>""" &
    name & """</title>
  </head>
  <body>
    <div id="ROOT"></div>
    <script src="/assets/app.js"></script>
  </body>
</html>
"""

proc csrTests(name: string): string =
  """import fastnim
import routes/api

block helloEndpoint:
  let web = initFastNim(logs = false)
  web.addRouter(apiRouter)

  let response = web.handle(initRequest(HttpMethod.Get, "/api/hello"))
  doAssert response.status == 200
  doAssert response.body == "{\"message\":\"Hello from """ &
    name & """!\"}"
"""

proc csrReadme(name: string): string =
  """# """ & name & "\n" & """

FastNim server with a client-rendered Karax app.

## Build and run

```sh
nimble client   # nim js -o:public/assets/app.js client/app.nim
nim c -r --path:src src/main.nim
```

Open http://127.0.0.1:8000. The counter runs locally in the browser; the
"Ask the server" button fetches `/api/hello`.

## Test

```sh
nimble test   # exercises the JSON API in-process
```

## Notes

- `/` serves `public/index.html`, `/assets/*` serves the compiled bundle,
  `/api/*` serves JSON. Rebuild the client after changing `client/app.nim`.
- The client uses `fetch` + `redraw` for server data; everything else is
  local Karax state.
"""

proc scaffoldKaraxCsr*(dir, name: string) =
  ## Writes a Karax CSR project into ``dir``.
  ##
  ## ``dir`` should be the empty project root; ``name`` is the project and
  ## Nimble package name.
  writeCsrFile(dir / name & ".nimble", csrNimble(name))
  writeCsrFile(dir / "config.nims", "switch(\"path\", \"src\")\n")
  writeCsrFile(dir / "src" / "main.nim", csrMain(name))
  writeCsrFile(dir / "src" / "routes" / "api.nim", csrApi(name))
  writeCsrFile(dir / "client" / "app.nim", csrClient(name))
  writeCsrFile(dir / "public" / "index.html", csrIndex(name))
  writeCsrFile(dir / "public" / "assets" / ".gitkeep", "")
  writeCsrFile(dir / "tests" / "test_api.nim", csrTests(name))
  writeCsrFile(dir / "README.md", csrReadme(name))
