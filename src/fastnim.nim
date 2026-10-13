## A small, FastNim API-inspired routing layer for Chronos applications.
import std/jsonutils

import chronos
import
  fastnim/[
    context/http,
    context/state,
    core/limits,
    core/server,
    jsonfields,
    logging,
    middleware/dsl,
    middleware/builtin,
    openapi/spec,
    params/extract,
    params/multipart,
    params/uploadsink,
    params/validate,
    plugin,
    plugins,
    routing/router,
    static/embed,
    static/files,
    testing,
    websocket,
  ]

export
  http, state, limits, server, jsonfields, logging, dsl, builtin, spec, extract, multipart,
  uploadsink, validate, plugin, plugins, router, embed, files, testing, websocket,
  chronos, jsonutils

when isMainModule:
  import std/os
  import fastnim/cli
  quit cliMain(commandLineParams())
