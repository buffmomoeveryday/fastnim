## Run with: nim c -r --path:src examples/datastar.nim
##
## Minimal Datastar counter. The plugin injects the Datastar CDN script tag
## into HTML responses, so handlers only declare signals and events.
## Open http://127.0.0.1:8000 and click the button: the browser POSTs its
## signals, the server reads them with ``readSignals`` and patches the DOM.

import chronos
import std/json

import fastnim
import fastnim/plugins/datastar

type CounterSignals = object
  count: int

let app = initFastNim()
app.install(datastarPlugin())

app.get("/"):
  html(
    """<html><head><title>Counter</title></head><body>""" &
    """<div data-signals='{"count": 0}'></div>""" &
    """<div id="count">0</div>""" &
    """<button data-on:click="@post('/increment')">Increment</button>""" &
    """</body></html>"""
  )

app.post("/increment"):
  let signals = readSignals(request)
  let count = signals.getOrDefault("count").getInt(0) + 1
  datastarStream(
    [
      patchElements("""<div id="count">""" & $count & "</div>"),
      patchSignals(%*{"count": count}),
    ]
  )

app.sse("/ticker"):
  await patchElements("""<div id="tick">live</div>""").send()
  await patchSignals(%*{"ticked": true}).send()

let server = app.serve(port = 8000)
echo "Datastar demo: http://127.0.0.1:8000"
waitFor server.join()
