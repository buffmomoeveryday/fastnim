import fastnim

block htmlHelper:
  let app = initFastNim(logs = false)
  app.get("/"):
    html "<h1>hi</h1>"

  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.status == 200
  doAssert response.body == "<h1>hi</h1>"
  doAssert response.headers["content-type"] == "text/html; charset=utf-8"

block htmlCustomStatus:
  let app = initFastNim(logs = false)
  app.get("/missing-page"):
    html(statusNotFound, "<h1>gone</h1>")

  let response = app.handleSync(initRequest(HttpMethod.Get, "/missing-page"))
  doAssert response.status == 404
  doAssert response.body == "<h1>gone</h1>"
  doAssert response.headers["content-type"] == "text/html; charset=utf-8"

block htmlDynamicContent:
  let app = initFastNim(logs = false)
  app.get("/users/{name}"):
    html "<h1>Hello, " & request.pathParam("name") & "</h1>"

  let response = app.handleSync(initRequest(HttpMethod.Get, "/users/Ada"))
  doAssert response.status == 200
  doAssert response.body == "<h1>Hello, Ada</h1>"
  doAssert response.headers["content-type"] == "text/html; charset=utf-8"
