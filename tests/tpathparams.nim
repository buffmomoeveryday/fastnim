import std/[assertions, json]

import fastnim

type IdResult = object
  id: int

block typedPathLocals:
  let router = initRouter(prefix = "/orders")
  router.patch("/{id:int}/status"):
    %*{"id": id, "raw": request.pathParam("id")}
  router.get("/{page:positiveInt}/{enabled:bool}/{format:string}/{tags:csv}"):
    %*{
      "page": page,
      "enabled": enabled,
      "format": format,
      "tags": tags,
    }

  let app = initFastNim(logs = false)
  app.addRouter(router)

  let patched = app.handleSync(initRequest(HttpMethod.Patch, "/orders/42/status"))
  doAssert patched.status == 200
  doAssert patched.json() == %*{"id": 42, "raw": "42"}

  let converted = app.handleSync(
    initRequest(HttpMethod.Get, "/orders/3/yes/json/red,green,blue")
  )
  doAssert converted.status == 200
  doAssert converted.json() == %*{
    "page": 3,
    "enabled": true,
    "format": "json",
    "tags": ["red", "green", "blue"],
  }

block invalidTypedPathsDoNotInvokeHandlers:
  var calls = 0
  let app = initFastNim(logs = false)
  app.get("/items/{id:int}"):
    inc calls
    %*{"id": id}
  app.get("/pages/{page:positiveInt}"):
    inc calls
    %*{"page": page}
  app.get("/flags/{enabled:bool}"):
    inc calls
    %*{"enabled": enabled}

  doAssert app.handleSync(initRequest(HttpMethod.Get, "/items/nope")).status == 404
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/pages/0")).status == 404
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/pages/-1")).status == 404
  doAssert app.handleSync(initRequest(HttpMethod.Get, "/flags/maybe")).status == 404
  doAssert calls == 0

block legacyStringPathParameters:
  let app = initFastNim(logs = false)
  app.get("/users/{id}"):
    %*{"id": request.pathParam("id")}
  let response = app.handleSync(initRequest(HttpMethod.Get, "/users/ada"))
  doAssert response.status == 200
  doAssert response.json() == %*{"id": "ada"}

block typedResponseRouteUsesPathLocal:
  let app = initFastNim(logs = false)
  app.get("/typed/{id:int}", responses = @[(200, IdResult)]):
    ok IdResult(id: id)
  let response = app.handleSync(initRequest(HttpMethod.Get, "/typed/17"))
  doAssert response.status == 200
  doAssert response.json() == %*{"id": 17}

block constantTypedPathUsesPathLocal:
  const ItemPath = "/constant/{id:int}"
  let app = initFastNim(logs = false)
  app.get(ItemPath):
    %*{"id": id}
  let response = app.handleSync(initRequest(HttpMethod.Get, "/constant/9"))
  doAssert response.json() == %*{"id": 9}

block invalidPathDeclarations:
  let app = initFastNim(logs = false)
  let handler: SyncRouteHandler = proc(request: Request): Response = text("never")

  doAssertRaises ValueError:
    app.addRoute(HttpMethod.Get, "/items/{id:float}", handler)
  doAssertRaises ValueError:
    app.addRoute(HttpMethod.Get, "/items/{id:int}/{id:string}", handler)
  doAssertRaises ValueError:
    app.addRoute(HttpMethod.Get, "/items/prefix-{id:int}", handler)

block typedPathOpenApi:
  let app = initFastNim(logs = false)
  app.get("/items/{id:int}"):
    %*{"id": id}
  app.get("/pages/{page:positiveInt}"):
    %*{"page": page}
  app.get("/flags/{enabled:bool}"):
    %*{"enabled": enabled}
  app.get("/tags/{values:csv}"):
    %*{"values": values}

  let document = app.openApiDocument()
  doAssert "/items/{id}" in document["paths"]
  doAssert "/items/{id:int}" notin document["paths"]
  let intSchema = document["paths"]["/items/{id}"]["get"]["parameters"][0]["schema"]
  doAssert intSchema["type"].getStr() == "integer"
  let positiveSchema =
    document["paths"]["/pages/{page}"]["get"]["parameters"][0]["schema"]
  doAssert positiveSchema["minimum"].getInt() == 1
  let boolSchema =
    document["paths"]["/flags/{enabled}"]["get"]["parameters"][0]["schema"]
  doAssert boolSchema["type"].getStr() == "boolean"
  let csvSchema =
    document["paths"]["/tags/{values}"]["get"]["parameters"][0]["schema"]
  doAssert csvSchema["type"].getStr() == "array"
  doAssert csvSchema["items"]["type"].getStr() == "string"
