import std/[json, tables]

import fastnim
import fastnim/plugins/htmx

proc htmxRequest(headers: Table[string, string]): Request =
  initRequest(HttpMethod.Get, "/authors?page=2", headers)

block readsHtmxRequestHeaders:
  let plain = htmxRequest(initTable[string, string]())
  doAssert not plain.isHtmx
  doAssert not plain.htmxBoosted
  doAssert plain.htmxCurrentUrl.len == 0
  doAssert plain.htmxPrompt.len == 0

  let request = htmxRequest(
    {
      "HX-Request": "true",
      "HX-Boosted": "true",
      "HX-Current-URL": "https://library.example/authors?page=2",
      "HX-History-Restore-Request": "true",
      "HX-Prompt": "Ada",
      "HX-Target": "author-list",
      "HX-Trigger": "author-form",
      "HX-Trigger-Name": "save",
    }.toTable
  )
  doAssert request.isHtmx
  doAssert request.htmxBoosted
  doAssert request.htmxHistoryRestoreRequest
  doAssert request.htmxCurrentUrl == "https://library.example/authors?page=2"
  doAssert request.htmxCurrentUrlPath == "/authors?page=2"
  doAssert request.htmxPrompt == "Ada"
  doAssert request.htmxTarget == "author-list"
  doAssert request.htmxTrigger == "author-form"
  doAssert request.htmxTriggerName == "save"

block setsHtmxResponseHeaders:
  let redirect = htmxRedirect("/authors")
  doAssert redirect.status == 200
  doAssert redirect.headers["hx-redirect"] == "/authors"

  let refresh = htmxRefresh()
  doAssert refresh.headers["hx-refresh"] == "true"

  let location = htmxLocation(%*{"path": "/authors", "target": "#list"})
  doAssert parseJson(location.headers["hx-location"])["target"].getStr == "#list"

  let polling = htmxStopPolling()
  doAssert polling.status == 286

  var fragment = html "<li>Ada</li>"
  fragment.htmxPushUrl("/authors")
  fragment.htmxReplaceUrl("/authors/1")
  fragment.htmxReswap("outerHTML")
  fragment.htmxRetarget("#list")
  fragment.htmxReselect("li")
  fragment.htmxTrigger("saved")
  fragment.htmxTrigger("counted", %*{"total": 1}, HtmxTriggerTiming.Settle)
  doAssert fragment.headers["hx-push-url"] == "/authors"
  doAssert fragment.headers["hx-replace-url"] == "/authors/1"
  doAssert fragment.headers["hx-reswap"] == "outerHTML"
  doAssert fragment.headers["hx-retarget"] == "#list"
  doAssert fragment.headers["hx-reselect"] == "li"
  doAssert fragment.headers["hx-trigger"] == "saved"
  let settled = parseJson(fragment.headers["hx-trigger-after-settle"])
  doAssert settled["counted"]["total"].getInt == 1

  fragment.htmxTrigger("another")
  let events = parseJson(fragment.headers["hx-trigger"])
  doAssert events["saved"].kind == JNull
  doAssert events["another"].kind == JNull

block varyHeaderDistinguishesFragments:
  let app = initFastNim(logs = false)
  app.installPlugin:
    htmxPlugin(version = 2)
  doAssert app.installedPlugins[0].version == "2"
  app.get("/"):
    html "<p>Hello</p>"
  let response = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.headers["vary"] == "HX-Request"
  let again = app.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert again.headers["vary"] == "HX-Request"
