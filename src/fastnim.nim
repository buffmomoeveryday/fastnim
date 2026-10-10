## A small, FastNim API-inspired routing layer for Chronos applications.
import chronos
import
  fastnim/[
    context/http,
    context/state,
    core/server,
    logging,
    middleware/builtin,
    openapi/spec,
    params/extract,
    plugin,
    plugins,
    routing/router,
    static/embed,
    static/files,
    testing,
    websocket,
  ]

export
  http, state, server, logging, builtin, spec, extract, plugin, plugins, router, embed,
  files, testing, websocket, chronos

when isMainModule:
  import std/os
  import fastnim/cli
  quit cliMain(commandLineParams())
