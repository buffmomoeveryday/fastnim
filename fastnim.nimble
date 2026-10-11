# Package

version = "0.1.0"
author = "Siddhartha Khanal"
description = "A small FastNim API-inspired web framework for Chronos"
license = "MIT"
srcDir = "src"
bin = @["fastnim"]
binDir = "bin"

# Dependencies

requires "nim >= 2.2.12"
requires "chronos >= 4.0.0"
requires "websock >= 0.4.2"
requires "nimcrypto >= 0.7.0"

task docs, "Generate HTML API documentation with nim doc":
  ## Renders every library module into htmldocs/ using nim doc.
  mkDir("htmldocs")
  for module in [
    "src/fastnim.nim",
    "src/fastnim/routing/router.nim",
    "src/fastnim/core/server.nim",
    "src/fastnim/context/http.nim",
    "src/fastnim/context/state.nim",
    "src/fastnim/jsonfields.nim",
    "src/fastnim/params/extract.nim",
    "src/fastnim/openapi/spec.nim",
    "src/fastnim/middleware/builtin.nim",
    "src/fastnim/static/files.nim",
    "src/fastnim/static/embed.nim",
    "src/fastnim/testing.nim",
    "src/fastnim/plugin.nim",
    "src/fastnim/plugins.nim",
    "src/fastnim/plugins/ratelimit.nim",
    "src/fastnim/plugins/inertia.nim",
    "src/fastnim/plugins/datastar.nim",
    "src/fastnim/plugins/auth.nim",
    "src/fastnim/plugins/auth/schemes.nim",
    "src/fastnim/plugins/auth/patterns.nim",
    "src/fastnim/plugins/auth/session.nim",
    "src/fastnim/plugins/openapi.nim",
    "src/fastnim/websocket.nim",
    "src/fastnim/logging.nim",
  ]:
    exec "nim doc --outdir:htmldocs --path:src " & module
