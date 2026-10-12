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
  # brefore the request reaches the handler
  var response = await next(request)
  # after the request reaches the handler
  response.setHeader("x-powered-by", "fastnim")
  response

let app = initFastNim()

app.use requireAdmin
app.use addResponseHeaders

app.get("/"):
  text "Public endpoint"

app.get("/json"):
  ok %*{"ok": "done"}

app.get("/admin"):
  text "Admin endpoint"

let server = app.serve(port = 8010)
waitFor server.join()
