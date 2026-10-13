## Run with: nim c -r --path:src examples/middleware.nim
import json

import fastnim

const AdminToken = "Bearer secret"

middleware requireAdmin:
  # before the request reaches the handler
  if request.path == "/admin" and request.header("authorization") != AdminToken:
    return json(statusUnauthorized, %*{"detail": "missing credentials"})

  await next(request)
  # after the request reaches the handler

middleware addResponseHeaders:
  # before the request reaches the handler
  var response = await next(request)
  # after the request reaches the handler
  response.setHeader("x-powered-by", "fastnim")
  response

let app = initFastNim()

app.middlewares:
  requireAdmin
  addResponseHeaders

app.get("/"):
  text "Public endpoint"

app.get("/json"):
  ok (%*{"ok": "done", "hello": 1})

app.get("/admin"):
  text "Admin endpoint"

let server = app.serve(port = 8010)
waitFor server.join()
