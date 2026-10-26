## Run with: nim c -r --path:src examples/htmx4.nim
##
## Open http://127.0.0.1:8092
## htmx 4. ``htmxPlugin(version = 4)`` selects HX-Source and HX-Request-Type.
## htmxPrompt, htmxTrigger, htmxTriggerName, and the after-swap trigger
## timings are compile errors in this file.

import std/[json, strutils, xmltree]

import fastnim

let app = initFastNim()

app.installPlugin:
  htmxPlugin(version = 4)

const Css = """
<style>
  body { font-family: system-ui, sans-serif; max-width: 42rem; margin: 2rem auto; padding: 0 1rem; }
  section { border: 1px solid #ddd; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
  h2 { margin-top: 0; font-size: 1.05rem; }
  code { font-size: .92em; }
  button, a { margin: .2rem .4rem .2rem 0; }
  #events { min-height: 1.2em; }
  #elsewhere { margin-top: .5rem; padding: .5rem; background: #f6f6f6; }
</style>
"""

proc yn(value: bool): string =
  if value: "true" else: "false"

proc field(name, value: string): string =
  let shown = if value.len == 0: "<em>empty</em>" else: xmltree.escape(value)
  "<li><code>" & name & "</code> " & shown & "</li>"

proc facts(request: Request): string =
  result = """<ul id="facts">"""
  result.add "<li><code>isHtmx</code> " & yn(request.isHtmx) & "</li>"
  result.add "<li><code>htmxBoosted</code> " & yn(request.htmxBoosted) & "</li>"
  result.add "<li><code>htmxHistoryRestoreRequest</code> " &
    yn(request.htmxHistoryRestoreRequest) & "</li>"
  result.add field("htmxCurrentUrl", request.htmxCurrentUrl)
  result.add field("htmxCurrentUrlPath", request.htmxCurrentUrlPath)
  result.add field("htmxRequestType", request.htmxRequestType)
  result.add field("htmxTarget", request.htmxTarget)
  result.add field("htmxTargetTag", request.htmxTargetTag)
  result.add field("htmxTargetId", request.htmxTargetId)
  result.add field("htmxSource", request.htmxSource)
  result.add field("htmxSourceTag", request.htmxSourceTag)
  result.add field("htmxSourceId", request.htmxSourceId)
  result.add "</ul>"

proc document(body: string): string =
  """<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>FastNim HTMX 4</title>
  <script src="https://unpkg.com/htmx.org@4.0.0"></script>
  <script>
    function note(text) {
      var el = document.querySelector("#events")
      el.textContent = el.textContent ? el.textContent + " · " + text : text
    }
  </script>
  """ & Css & """
</head>
<body hx-on="saved -> note('saved'); counted -> note('counted ' + event.detail.total)">
  <h1>FastNim HTMX 4</h1>
  <div id="main">""" & body & """</div>
</body>
</html>"""

proc isPartial(request: Request): bool =
  request.htmxRequestType == "partial"

proc page(request: Request, body: string): Response =
  if request.isPartial:
    html body
  else:
    html document(body)

proc queryCount(request: Request): int =
  try:
    parseInt(request.queryParam("n", "0"))
  except ValueError:
    0

proc home(request: Request): string =
  """
<section>
  <h2>Request helpers</h2>
  <button id="fact-button"
    hx-get="/facts" hx-target="#facts" hx-swap="outerHTML">
    Read HX-* headers
  </button>
  <a href="/boosted" hx-boost="true">Boosted page</a>
  """ & facts(request) & """
</section>
<section>
  <h2>html</h2>
  <p>This page is <code>html(body)</code>. <a href="/missing">Missing</a> is <code>html(statusNotFound, body)</code>.</p>
</section>
<section>
  <h2>Navigation</h2>
  <button hx-post="/redirect">htmxRedirect</button>
  <button hx-post="/refresh">htmxRefresh</button>
  <button hx-post="/location">htmxLocation</button>
  <button hx-post="/location-spec">htmxLocation JSON</button>
  <button hx-get="/push" hx-target="#nav-out">htmxPushUrl</button>
  <button hx-get="/replace" hx-target="#nav-out">htmxReplaceUrl</button>
  <div id="nav-out"></div>
</section>
<section>
  <h2>Swap</h2>
  <div id="swap-box">This box is replaced by outerHTML.</div>
  <button hx-get="/reswap" hx-target="#swap-box" hx-swap="innerHTML">htmxReswap</button>
  <button hx-get="/retarget" hx-target="#main" hx-swap="beforeend">htmxRetarget</button>
  <div id="elsewhere">elsewhere</div>
  <div id="select-box">This box keeps only the reselected node.</div>
  <button hx-get="/reselect" hx-target="#select-box">htmxReselect</button>
</section>
<section>
  <h2>Events</h2>
  <p id="events"></p>
  <button hx-post="/notify" hx-target="#notice">htmxTrigger</button>
  <div id="notice"></div>
</section>
<section>
  <h2>Polling</h2>
  <span id="poll" hx-get="/poll?n=0" hx-trigger="every 1s" hx-swap="outerHTML">waiting</span>
</section>
"""

app.get("/"):
  html document(home(request))

app.get("/facts"):
  page(request, facts(request))

app.get("/boosted"):
  html document("<p><code>htmxBoosted</code> is " & yn(request.htmxBoosted) & ".</p>" & facts(request))

app.get("/missing"):
  let body = "<h1>Not found</h1><p>Returned with <code>html(statusNotFound, body)</code>.</p>"
  if request.isPartial:
    html(statusNotFound, body)
  else:
    html(statusNotFound, document(body))

app.get("/landed"):
  page(request, "<p>HTMX navigated here.</p><p><a href=\"/\">Home</a></p>")

app.post("/redirect"):
  htmxRedirect("/landed")

app.post("/refresh"):
  htmxRefresh()

app.post("/location"):
  htmxLocation("/landed")

app.post("/location-spec"):
  htmxLocation(%*{"path": "/landed", "target": "#main"})

app.get("/push"):
  let body = "<p><code>htmxPushUrl</code> set the address bar to <code>/push</code>.</p>"
  if not request.isPartial:
    return html(document(body))
  var response = html(body)
  response.htmxPushUrl("/push")
  response

app.get("/replace"):
  let body = "<p><code>htmxReplaceUrl</code> replaced the history entry with <code>/replace</code>.</p>"
  if not request.isPartial:
    return html(document(body))
  var response = html(body)
  response.htmxReplaceUrl("/replace")
  response

app.get("/reswap"):
  let body = """<div id="swap-box">Replaced with <code>htmxReswap("outerHTML")</code>.</div>"""
  if not request.isPartial:
    return html(document(body))
  var response = html(body)
  response.htmxReswap("outerHTML")
  response

app.get("/retarget"):
  let body = "<p>This landed in <code>#elsewhere</code> via <code>htmxRetarget</code>.</p>"
  if not request.isPartial:
    return html(document(body))
  var response = html(body)
  response.htmxRetarget("#elsewhere")
  response

app.get("/reselect"):
  let body = """<div><p>ignored</p><p id="picked">Only this node was swapped, via <code>htmxReselect</code>.</p></div>"""
  if not request.isPartial:
    return html(document(body))
  var response = html(body)
  response.htmxReselect("#picked")
  response

app.post("/notify"):
  var response = html "<p>Saved.</p>"
  response.htmxTrigger("saved")
  response.htmxTrigger("counted", %*{"total": 1})
  response

app.get("/poll"):
  let n = queryCount(request)
  if n >= 3:
    return htmxStopPolling()
  let next = n + 1
  html(
    """<span id="poll" hx-get="/poll?n=""" & $next &
      """" hx-trigger="every 1s" hx-swap="outerHTML">tick """ & $n & "</span>"
  )

let server = app.serve(port = 8092)
echo "Open http://127.0.0.1:8092"
waitFor server.join()
