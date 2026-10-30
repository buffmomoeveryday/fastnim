## A small, FastNim API-inspired routing layer for Chronos applications.
import std/jsonutils

import chronos
import
  fastnim/[
    context/http,
    context/state,
    core/bytes,
    core/limits,
    core/server,
    jsonfields,
    logging,
    middleware/dsl,
    middleware/builtin,
    openapi/spec,
    orm/uuids,
    params/extract,
    params/multipart,
    params/uploadsink,
    params/validate,
    plugin,
    plugins,
    routing/router,
    shortcuts,
    static/embed,
    static/files,
    testing,
    websocket,
  ]

export
  http, state, bytes, limits, server, jsonfields, logging, dsl, builtin, spec, uuids,
  extract, multipart, uploadsink, validate, plugin, plugins, router, shortcuts, embed,
  files, testing, websocket, chronos, jsonutils

when isMainModule:
  import std/os
  import fastnim/cli
  quit cliMain(commandLineParams())
