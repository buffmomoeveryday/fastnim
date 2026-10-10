## Run with: nim c -r --path:src examples/middleware.nim

import chronos

import fastnim

const AdminToken = "Bearer secret"

proc addResponseHeaders(request: Request, next: NextHandler): Response =
  var response = next(request)
  response.setHeader("x-powered-by", "fastnim")
  response

proc requireAdmin(request: Request, next: NextHandler): Response =
  if request.path == "/admin" and request.header("authorization") != AdminToken:
    return text("Unauthorized", 401)
  next(request)

let app = initFastNim()

app.use(requireAdmin)

app.get("/"):
  text("Public endpoint")

app.get("/admin"):
  text("Admin endpoint")

let server = app.serve(port = 8010)
waitFor server.join()
