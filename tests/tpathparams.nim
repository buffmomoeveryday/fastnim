import std/[json, unittest]

import fastnim

type IdResult = object
  id: int

suite "Typed path parameters":
  test "exposes converted locals in router handlers":
    let router = initRouter(prefix = "/orders")
    router.patch("/{id:int}/status"):
      %*{"id": id, "raw": request.pathParam("id")}
    router.get("/{page:positiveInt}/{enabled:bool}/{format:string}/{tags:csv}"):
      %*{"page": page, "enabled": enabled, "format": format, "tags": tags}

    let app = initFastNim(logs = false)
    app.addRouter(router)

    let patched = app.handleSync(initRequest(HttpMethod.Patch, "/orders/42/status"))
    check patched.status == 200
    check patched.json() == %*{"id": 42, "raw": "42"}

    let converted =
      app.handleSync(initRequest(HttpMethod.Get, "/orders/3/yes/json/red,green,blue"))
    check converted.status == 200
    check converted.json() ==
      %*{"page": 3, "enabled": true, "format": "json", "tags": ["red", "green", "blue"]}

  test "does not invoke handlers for invalid converted values":
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

    check app.handleSync(initRequest(HttpMethod.Get, "/items/nope")).status == 404
    check app.handleSync(initRequest(HttpMethod.Get, "/pages/0")).status == 404
    check app.handleSync(initRequest(HttpMethod.Get, "/pages/-1")).status == 404
    check app.handleSync(initRequest(HttpMethod.Get, "/flags/maybe")).status == 404
    check calls == 0

  test "preserves legacy string path parameters":
    let app = initFastNim(logs = false)
    app.get("/users/{id}"):
      %*{"id": request.pathParam("id")}
    let response = app.handleSync(initRequest(HttpMethod.Get, "/users/ada"))
    check response.status == 200
    check response.json() == %*{"id": "ada"}

  test "uses a path local in typed response routes":
    let app = initFastNim(logs = false)
    app.get("/typed/{id:int}", responses = @[(200, IdResult)]):
      ok IdResult(id: id)
    let response = app.handleSync(initRequest(HttpMethod.Get, "/typed/17"))
    check response.status == 200
    check response.json() == %*{"id": 17}

  test "uses a path local when the route path is constant":
    const ItemPath = "/constant/{id:int}"
    let app = initFastNim(logs = false)
    app.get(ItemPath):
      %*{"id": id}
    let response = app.handleSync(initRequest(HttpMethod.Get, "/constant/9"))
    check response.json() == %*{"id": 9}

  test "rejects invalid path declarations":
    let app = initFastNim(logs = false)
    let handler: SyncRouteHandler = proc(request: Request): Response =
      text("never")

    expect ValueError:
      app.addRoute(HttpMethod.Get, "/items/{id:float}", handler)
    expect ValueError:
      app.addRoute(HttpMethod.Get, "/items/{id:int}/{id:string}", handler)
    expect ValueError:
      app.addRoute(HttpMethod.Get, "/items/prefix-{id:int}", handler)

  test "documents converter-specific OpenAPI schemas":
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
    check "/items/{id}" in document["paths"]
    check "/items/{id:int}" notin document["paths"]
    let intSchema = document["paths"]["/items/{id}"]["get"]["parameters"][0]["schema"]
    check intSchema["type"].getStr() == "integer"
    let positiveSchema =
      document["paths"]["/pages/{page}"]["get"]["parameters"][0]["schema"]
    check positiveSchema["minimum"].getInt() == 1
    let boolSchema =
      document["paths"]["/flags/{enabled}"]["get"]["parameters"][0]["schema"]
    check boolSchema["type"].getStr() == "boolean"
    let csvSchema =
      document["paths"]["/tags/{values}"]["get"]["parameters"][0]["schema"]
    check csvSchema["type"].getStr() == "array"
    check csvSchema["items"]["type"].getStr() == "string"
