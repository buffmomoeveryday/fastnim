## A small, FastNim API-inspired routing layer for Chronos applications.
import chronos
import
  fastnim/[
    context/http,
    context/state,
    core/server,
    jsonfields,
    logging,
    middleware/dsl,
    middleware/builtin,
    openapi/spec,
    params/extract,
    params/multipart,
    params/uploadsink,
    plugin,
    plugins,
    routing/router,
    static/embed,
    static/files,
    testing,
    websocket,
  ]

export
  http, state, server, jsonfields, logging, dsl, builtin, spec, extract, multipart,
  uploadsink, plugin, plugins, router, embed, files, testing, websocket, chronos

when isMainModule:
  import std/os
  import fastnim/cli
  quit cliMain(commandLineParams())
