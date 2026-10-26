import std/[assertions, json, strutils, tables]

import fastnim
import fastnim/plugins/inertia

proc inertiaHeaders(version = ""): Headers =
  result = initTable[string, string]()
  result["x-inertia"] = "true"
  if version.len > 0:
    result["x-inertia-version"] = version

proc newInertiaApp(options = initInertiaOptions(version = "assets-v1")): Application =
  result = initFastNim(logs = false)
  result.installPlugin(inertiaPlugin(options))
  result.get("/users"):
    inertia("Users/Index", %*{"users": ["Ada", "Linus"], "page": 2})

block rendersInitialHtmlResponse:
  let response = newInertiaApp().handleSync(initRequest(HttpMethod.Get, "/users"))
  doAssert response.status == 200
  doAssert response.headers["content-type"] == "text/html; charset=utf-8"
  doAssert response.headers["vary"] == "X-Inertia"
  doAssert "<div id=\"app\"></div>" in response.body
  doAssert "<script data-page=\"app\" type=\"application/json\">" in response.body
  doAssert "\"component\":\"Users\\/Index\"" in response.body

block escapesEmbeddedScriptTerminators:
  let app = initFastNim(logs = false)
  app.installPlugin(inertiaPlugin())
  app.get("/unsafe"):
    inertia("Unsafe", %*{"value": "</script><script>alert(1)</script>"})
  let response = app.handleSync(initRequest(HttpMethod.Get, "/unsafe"))
  doAssert "</script><script>alert(1)</script>" notin response.body
  doAssert "<\\/script>" in response.body

block rendersInertiaJsonResponse:
  let response = newInertiaApp().handleSync(
      initRequest(HttpMethod.Get, "/users?sort=name", inertiaHeaders("assets-v1"))
    )
  let page = parseJson(response.body)
  doAssert response.status == 200
  doAssert response.headers["content-type"] == "application/json; charset=utf-8"
  doAssert response.headers["x-inertia"] == "true"
  doAssert response.headers["vary"] == "X-Inertia"
  doAssert page["component"].getStr() == "Users/Index"
  doAssert page["props"]["users"].len == 2
  doAssert page["props"]["errors"].kind == JObject
  doAssert page["url"].getStr() == "/users?sort=name"
  doAssert page["version"].getStr() == "assets-v1"

block mergesSharedPropsWithRoutePrecedence:
  let options = initInertiaOptions(sharedProps = %*{"auth": {"name": "Ada"}, "page": 1})
  let response = newInertiaApp(options).handleSync(
      initRequest(HttpMethod.Get, "/users", inertiaHeaders())
    )
  let props = parseJson(response.body)["props"]
  doAssert props["auth"]["name"].getStr() == "Ada"
  doAssert props["page"].getInt() == 2

block filtersPartialReloadProps:
  var headers = inertiaHeaders()
  headers["x-inertia-partial-component"] = "Users/Index"
  headers["x-inertia-partial-data"] = "users,page"
  headers["x-inertia-partial-except"] = "page"
  let response =
    newInertiaApp().handleSync(initRequest(HttpMethod.Get, "/users", headers))
  let props = parseJson(response.body)["props"]
  doAssert "users" in props
  doAssert "page" notin props
  doAssert "errors" in props

block ignoresPartialReloadForAnotherComponent:
  var headers = inertiaHeaders()
  headers["x-inertia-partial-component"] = "Dashboard"
  headers["x-inertia-partial-data"] = "page"
  let response =
    newInertiaApp().handleSync(initRequest(HttpMethod.Get, "/users", headers))
  let props = parseJson(response.body)["props"]
  doAssert "users" in props
  doAssert "page" in props

block rejectsStaleAssetVersion:
  let response = newInertiaApp().handleSync(
      initRequest(HttpMethod.Get, "/users?tag=nim&tag=web", inertiaHeaders("assets-v0"))
    )
  doAssert response.status == 409
  doAssert response.headers["x-inertia-location"] == "/users?tag=nim&tag=web"
  doAssert response.headers["x-inertia-version"] == "assets-v1"
  doAssert "x-inertia" notin response.headers

block convertsPostRedirectToSeeOther:
  let app = initFastNim(logs = false)
  app.installPlugin(inertiaPlugin())
  app.post("/users"):
    var response = initResponse(statusFound)
    response.setHeader("location", "/users")
    response
  let response =
    app.handleSync(initRequest(HttpMethod.Post, "/users", inertiaHeaders()))
  doAssert response.status == 303

block createsExternalLocationVisit:
  let response = inertiaLocation("https://example.com/docs")
  doAssert response.status == 409
  doAssert response.headers["x-inertia-location"] == "https://example.com/docs"

block validatesPublicInputs:
  doAssertRaises ValueError:
    discard inertia("", newJObject())
  doAssertRaises ValueError:
    discard inertia("Users/Index", %*[1, 2])
  doAssertRaises ValueError:
    discard initInertiaOptions(sharedProps = %*[1, 2])

block detectsInertiaRequests:
  doAssert initRequest(HttpMethod.Post, "/login", inertiaHeaders()).isInertiaRequest()
  doAssert not initRequest(HttpMethod.Post, "/login").isInertiaRequest()

block failedFormSubmissionReturnsInertiaPage:
  # Regression test: answering an Inertia form POST (e.g. a failed login)
  # with plain JSON makes the client show its "must receive a valid Inertia
  # response" error modal. Failures must re-render the form page with errors.
  let app = initFastNim(logs = false)
  app.installPlugin(inertiaPlugin())
  app.post("/login"):
    if request.isInertiaRequest():
      return inertia("Login", %*{"errors": {"username": "Invalid credentials"}})
    return json(statusUnauthorized, %*{"message": "invalid credentials"})
  let inertiaRes = app.handleSync(
    initRequest(HttpMethod.Post, "/login", inertiaHeaders(), body = "{}")
  )
  doAssert inertiaRes.headers.getOrDefault("x-inertia") == "true"
  let page = parseJson(inertiaRes.body)
  doAssert page["component"].getStr() == "Login"
  doAssert page["props"]["errors"]["username"].getStr() == "Invalid credentials"
  let apiRes = app.handleSync(initRequest(HttpMethod.Post, "/login", body = "{}"))
  doAssert "x-inertia" notin apiRes.headers
  doAssert apiRes.status == 401
  doAssert parseJson(apiRes.body)["message"].getStr() == "invalid credentials"
