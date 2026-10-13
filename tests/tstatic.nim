import std/[os, tables]

import fastnim

proc makeDiskFixtures(): string =
  result = getTempDir() / "fastnim_tstatic"
  if dirExists(result):
    removeDir(result)
  createDir(result)
  createDir(result / "docs")
  writeFile(result / "hello.txt", "hello static")
  writeFile(result / "app.css", "body { color: red; }")
  writeFile(result / "data.json", """{"a":1}""")
  writeFile(result / "index.html", "<h1>home</h1>")
  writeFile(result / "docs" / "index.html", "<h1>docs</h1>")
  writeFile(result / ".hidden", "secret")
  writeFile(result / "favicon.ico", "icon-bytes")

proc headersOf(items: openArray[(string, string)]): Headers =
  result = initTable[string, string]()
  for item in items:
    result[item[0]] = item[1]

block diskServingAndMime:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveStatic("/static", directory = dir)

  let txt = app.handleSync(initRequest(HttpMethod.Get, "/static/hello.txt"))
  doAssert txt.status == 200
  doAssert txt.body == "hello static"
  doAssert txt.headers["content-type"] == "text/plain; charset=utf-8"
  doAssert txt.headers["content-length"] == "12"
  doAssert txt.headers["accept-ranges"] == "bytes"
  doAssert txt.headers["etag"].len > 0
  doAssert txt.headers["last-modified"].len > 0
  doAssert txt.headers["cache-control"] == "public, max-age=3600"

  let css = app.handleSync(initRequest(HttpMethod.Get, "/static/app.css"))
  doAssert css.status == 200
  doAssert css.headers["content-type"] == "text/css; charset=utf-8"

  let js = app.handleSync(initRequest(HttpMethod.Get, "/static/data.json"))
  doAssert js.headers["content-type"] == "application/json; charset=utf-8"

  let nested = app.handleSync(initRequest(HttpMethod.Get, "/static/docs/index.html"))
  doAssert nested.status == 200
  doAssert nested.body == "<h1>docs</h1>"

block indexAndRedirect:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveStatic("/static", directory = dir)

  let root = app.handleSync(initRequest(HttpMethod.Get, "/static"))
  doAssert root.status == 200
  doAssert root.body == "<h1>home</h1>"

  let slash = app.handleSync(initRequest(HttpMethod.Get, "/static/"))
  doAssert slash.body == "<h1>home</h1>"

  let redirect = app.handleSync(initRequest(HttpMethod.Get, "/static/docs"))
  doAssert redirect.status == 307
  doAssert redirect.headers["location"] == "/static/docs/"

  let repeated = app.handleSync(
    initRequest(HttpMethod.Get, "/static/docs?tag=nim&tag=web")
  )
  doAssert repeated.headers["location"] == "/static/docs/?tag=nim&tag=web"

  let docs = app.handleSync(initRequest(HttpMethod.Get, "/static/docs/"))
  doAssert docs.status == 200
  doAssert docs.body == "<h1>docs</h1>"

block fallthroughToAppHandlers:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.onError(
    404, proc(request: Request): Response = text(statusNotFound, "custom:" & request.path)
  )
  app.serveStatic("/static", directory = dir)
  app.get("/hello"):
    text("route")

  doAssert app.routes.len == 1
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/static/missing.txt")).body ==
    "custom:/static/missing.txt"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/other/hello.txt")).status == 404
  doAssert app.handleSync(initRequest(HttpMethod.Post, "/static/hello.txt")).status ==
    404
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/hello")).body == "route"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/static/.hidden")).status == 404

block traversalBlocked:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveStatic("/static", directory = dir)

  doAssert app.handleSync(initRequest(HttpMethod.Get, "/static/../hello.txt")).status ==
    404
  doAssert app.handleSync(
    initRequest(HttpMethod.Get, "/static/%2e%2e/%2e%2e/etc/passwd")
  ).status == 404
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/static/%2e%2e/x")).status ==
    404

block headAndConditional:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveStatic("/static", directory = dir)

  let get = app.handleSync(initRequest(HttpMethod.Get, "/static/hello.txt"))
  let head = app.handleSync(initRequest(HttpMethod.Head, "/static/hello.txt"))
  doAssert head.status == 200
  doAssert head.body == ""
  doAssert head.headers["content-length"] == "12"
  doAssert head.headers["etag"] == get.headers["etag"]

  let cached = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt",
      headersOf({"If-None-Match": get.headers["etag"]}),
    )
  )
  doAssert cached.status == 304
  doAssert cached.body == ""

  let wildcard = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt", headersOf({"If-None-Match": "*"})
    )
  )
  doAssert wildcard.status == 304

  let since = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt",
      headersOf({"If-Modified-Since": get.headers["last-modified"]}),
    )
  )
  doAssert since.status == 304

  let stale = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt",
      headersOf({"If-None-Match": "\"0-0\""}),
    )
  )
  doAssert stale.status == 200

block rangeRequests:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveStatic("/static", directory = dir)

  let first = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt", headersOf({"Range": "bytes=0-4"})
    )
  )
  doAssert first.status == 206
  doAssert first.body == "hello"
  doAssert first.headers["content-range"] == "bytes 0-4/12"
  doAssert first.headers["content-length"] == "5"

  let suffix = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt", headersOf({"Range": "bytes=-6"})
    )
  )
  doAssert suffix.status == 206
  doAssert suffix.body == "static"

  let openEnded = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt", headersOf({"Range": "bytes=6-"})
    )
  )
  doAssert openEnded.body == "static"
  doAssert openEnded.headers["content-range"] == "bytes 6-11/12"

  let clamped = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt", headersOf({"Range": "bytes=6-999"})
    )
  )
  doAssert clamped.status == 206
  doAssert clamped.body == "static"

  let unsat = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt", headersOf({"Range": "bytes=999-"})
    )
  )
  doAssert unsat.status == 416
  doAssert unsat.headers["content-range"] == "bytes */12"

  let multi = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt",
      headersOf({"Range": "bytes=0-1,3-4"}),
    )
  )
  doAssert multi.status == 416

  let malformed = app.handleSync(
    initRequest(
      HttpMethod.Get, "/static/hello.txt", headersOf({"Range": "bytes=abc"})
    )
  )
  doAssert malformed.status == 200
  doAssert malformed.body == "hello static"

block largeFileStreamsThroughAdapter:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveStatic("/big", directory = dir, streamThreshold = 8)

  let streamed = app.handleSync(initRequest(HttpMethod.Get, "/big/hello.txt"))
  doAssert streamed.status == 200
  doAssert streamed.body == ""
  doAssert streamed.isFileResponse
  doAssert streamed.sendFile == absolutePath(dir) / "hello.txt"
  doAssert streamed.fileOffset == 0
  doAssert streamed.fileLength == 12
  doAssert streamed.headers["content-length"] == "12"

  let ranged = app.handleSync(
    initRequest(HttpMethod.Get, "/big/hello.txt", headersOf({"Range": "bytes=0-3"}))
  )
  doAssert ranged.status == 206
  doAssert ranged.isFileResponse
  doAssert ranged.fileOffset == 0
  doAssert ranged.fileLength == 4
  doAssert ranged.headers["content-range"] == "bytes 0-3/12"

  let head = app.handleSync(initRequest(HttpMethod.Head, "/big/hello.txt"))
  doAssert not head.isFileResponse
  doAssert head.body == ""
  doAssert head.headers["content-length"] == "12"

block singleFile:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveSingleFile("/favicon.ico", dir / "favicon.ico")

  let icon = app.handleSync(initRequest(HttpMethod.Get, "/favicon.ico"))
  doAssert icon.status == 200
  doAssert icon.body == "icon-bytes"
  doAssert icon.headers["content-type"] == "image/x-icon"
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/other.ico")).status == 404
  doAssert app.handleSync(initRequest(HttpMethod.Post, "/favicon.ico")).status == 404

block embeddedDirectory:
  let app = initFastNim(logs = false)
  app.serveStaticEmbedded("/emb", "fixtures/static")

  let txt = app.handleSync(initRequest(HttpMethod.Get, "/emb/hello.txt"))
  doAssert txt.status == 200
  doAssert txt.body == "embedded hello\n"
  doAssert txt.headers["content-type"] == "text/plain; charset=utf-8"

  let root = app.handleSync(initRequest(HttpMethod.Get, "/emb"))
  doAssert root.status == 200
  doAssert root.body == "<h1>embedded</h1>\n"

  let css = app.handleSync(initRequest(HttpMethod.Get, "/emb/css/app.css"))
  doAssert css.status == 200
  doAssert css.headers["content-type"] == "text/css; charset=utf-8"

  doAssert app.handleSync(initRequest(HttpMethod.Get, "/emb/missing.txt")).status ==
    404
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/emb/%2e%2e/x")).status == 404

  let cached = app.handleSync(
    initRequest(
      HttpMethod.Get, "/emb/hello.txt",
      headersOf({"If-None-Match": txt.headers["etag"]}),
    )
  )
  doAssert cached.status == 304

  let ranged = app.handleSync(
    initRequest(
      HttpMethod.Get, "/emb/hello.txt", headersOf({"Range": "bytes=0-7"})
    )
  )
  doAssert ranged.status == 206
  doAssert ranged.body == "embedded"

block singleEmbeddedFile:
  let app = initFastNim(logs = false)
  app.serveSingleEmbeddedFile("/robots.txt", "fixtures/static/hello.txt")

  let res = app.handleSync(initRequest(HttpMethod.Get, "/robots.txt"))
  doAssert res.status == 200
  doAssert res.body == "embedded hello\n"

block spaFallbackAndNoCache:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  app.serveStatic(
    "/app", directory = dir, spaFallback = "index.html", maxAge = 0
  )

  let fallback = app.handleSync(initRequest(HttpMethod.Get, "/app/unknown/route"))
  doAssert fallback.status == 200
  doAssert fallback.body == "<h1>home</h1>"
  doAssert "cache-control" notin fallback.headers

block invalidMountsRaise:
  let dir = makeDiskFixtures()
  let app = initFastNim(logs = false)
  doAssertRaises ValueError:
    app.serveStatic("static", directory = dir)
  doAssertRaises ValueError:
    app.serveStatic("/static", directory = dir / "missing")
  doAssertRaises ValueError:
    app.serveSingleFile("/icon", dir / "missing.ico")
  doAssertRaises ValueError:
    app.serveSingleFile("icon", dir / "favicon.ico")
  doAssertRaises ValueError:
    app.serveStatic("/static", directory = dir, maxAge = -1)

block staticHelpers:
  doAssert guessContentType("app.js") == "text/javascript; charset=utf-8"
  doAssert guessContentType("photo.JPG") == "image/jpeg"
  doAssert guessContentType("clip.mp4") == "video/mp4"
  doAssert guessContentType("unknown.zzz") == "application/octet-stream"
  doAssert safeRelPath("a/./b").rel == "a/b"
  doAssert not safeRelPath("../../x").ok
  doAssert safeRelPath("a/../b").rel == "b"
