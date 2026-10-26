import std/[json, tables]

import fastnim

let app = initFastNim(logs = false)
app.installPlugin:
  htmxPlugin(version = 4)

doAssert app.installedPlugins[0].version == "4"

block readsHtmx4RequestHeaders:
  let request = initRequest(
    HttpMethod.Get,
    "/authors?page=2",
    {
      "HX-Request": "true",
      "HX-Boosted": "true",
      "HX-Current-URL": "https://library.example/authors?page=2",
      "HX-History-Restore-Request": "true",
      "HX-Request-Type": "partial",
      "HX-Target": "div#author-list",
      "HX-Source": "button#save",
    }.toTable,
  )
  doAssert request.isHtmx
  doAssert request.htmxBoosted
  doAssert request.htmxHistoryRestoreRequest
  doAssert request.htmxCurrentUrlPath == "/authors?page=2"
  doAssert request.htmxRequestType == "partial"
  doAssert request.htmxTarget == "div#author-list"
  doAssert request.htmxTargetTag == "div"
  doAssert request.htmxTargetId == "author-list"
  doAssert request.htmxSource == "button#save"
  doAssert request.htmxSourceTag == "button"
  doAssert request.htmxSourceId == "save"

block setsHtmx4ResponseHeaders:
  var fragment = html "<li>Ada</li>"
  fragment.htmxTrigger("saved")
  fragment.htmxTrigger("counted", %*{"total": 1})
  doAssert fragment.headers["hx-trigger"] == """{"saved":null,"counted":{"total":1}}"""
  doAssert "hx-trigger-after-settle" notin fragment.headers
  doAssert "hx-trigger-after-swap" notin fragment.headers

  let polling = htmxStopPolling()
  doAssert polling.status == 286
