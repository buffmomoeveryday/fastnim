import std/[assertions, json, strutils, tables, uri]

import chronos
import chronos/asyncsync
from chronos/apps/http/httpserver import HttpWriteError

import fastnim
import fastnim/plugins/datastar

type CounterSignals = object
  count: int

block patchElementsMinimalOmitsDefaults:
  let wire = formatSseEvent(patchElements("""<div id="feed"><span>1</span></div>"""))
  doAssert wire ==
    "event: datastar-patch-elements\ndata: elements <div id=\"feed\"><span>1</span></div>\n\n"

block patchElementsDefaultsOmitRetryNamespaceAndMode:
  let wire = formatSseEvent(
    patchElements(
      """<div id="a">x</div>""", retryMs = 1000, namespace = DatastarNamespace.Html
    )
  )
  doAssert "retry:" notin wire
  doAssert "mode " notin wire
  doAssert "namespace " notin wire

block patchElementsFullOptions:
  let wire = formatSseEvent(
    patchElements(
      "<div>\n  <span>1</span>\n</div>",
      selector = "#feed",
      mode = DatastarPatchMode.Inner,
      namespace = DatastarNamespace.Svg,
      useViewTransition = true,
      viewTransitionSelector = "#main",
      eventId = "123",
      retryMs = 2000,
    )
  )
  doAssert wire ==
    "id: 123\nevent: datastar-patch-elements\nretry: 2000\n" &
    "data: selector #feed\ndata: mode inner\ndata: namespace svg\n" &
    "data: useViewTransition true\ndata: viewTransitionSelector #main\n" &
    "data: elements <div>\ndata: elements   <span>1</span>\ndata: elements </div>\n\n"

block removeElementsUsesRemoveMode:
  let wire = formatSseEvent(removeElements("#feed, #other"))
  doAssert wire ==
    "event: datastar-patch-elements\ndata: selector #feed, #other\n" &
    "data: mode remove\n\n"
  doAssertRaises ValueError:
    discard removeElements("")

block patchSignalsMinimalAndMissing:
  let wire = formatSseEvent(patchSignals(%*{"output": "hi", "show": true}))
  doAssert wire ==
    "event: datastar-patch-signals\n" &
    "data: signals {\"output\":\"hi\",\"show\":true}\n\n"

block patchSignalsOnlyIfMissingWithIds:
  let wire = formatSseEvent(
    patchSignals(%*{"count": 1}, onlyIfMissing = true, eventId = "7", retryMs = 2000)
  )
  doAssert wire ==
    "id: 7\nevent: datastar-patch-signals\nretry: 2000\n" &
    "data: onlyIfMissing true\ndata: signals {\"count\":1}\n\n"

block patchSignalsFromStringAndValidation:
  let wire = formatSseEvent(patchSignals("""{"a":1}"""))
  doAssert "data: signals {\"a\":1}" in wire
  doAssertRaises ValueError:
    discard patchSignals("[1, 2]")
  doAssertRaises ValueError:
    discard patchSignals("not json")
  doAssertRaises ValueError:
    discard patchSignals(%*[1, 2])

block removeSignalsSetsNull:
  let node = readSignals(
    block:
      var headers = initTable[string, string]()
      initRequest(HttpMethod.Post, "/x", headers, """{"a":1,"b":2}""")
  )
  doAssert node["a"].getInt() == 1
  let wire = formatSseEvent(removeSignals(["a", "b"]))
  let payload = parseJson(wire.split("data: signals ")[1].strip())
  doAssert payload["a"].kind == JNull
  doAssert payload["b"].kind == JNull
  doAssertRaises ValueError:
    discard removeSignals([])
  doAssertRaises ValueError:
    discard removeSignals([""])

block marshalPatchSignalsGeneric:
  let wire = formatSseEvent(marshalPatchSignals(CounterSignals(count: 3)))
  doAssert "data: signals {\"count\":3}" in wire

block executeScriptAppendsScriptToBody:
  let wire = formatSseEvent(executeScript("console.log('hi')"))
  doAssert "event: datastar-patch-elements" in wire
  doAssert "data: selector body" in wire
  doAssert "data: mode append" in wire
  doAssert "data-effect=\"el.remove()\"" in wire
  doAssert "console.log('hi')" in wire
  doAssertRaises ValueError:
    discard executeScript("")

block redirectEncodesUrl:
  let wire = formatSseEvent(redirect("/new-page?q=a&b=c"))
  doAssert "window.location.href" in wire
  doAssert "/new-page?q=a&b=c" in wire
  doAssertRaises ValueError:
    discard redirect("")

block readSignalsFromGetQuery:
  let raw = encodeUrl("""{"count":41}""")
  let node = readSignals(initRequest(HttpMethod.Get, "/c?datastar=" & raw))
  doAssert node["count"].getInt() == 41

block readSignalsFromDeleteQuery:
  let raw = encodeUrl("""{"count":7}""")
  let node = readSignals(initRequest(HttpMethod.Delete, "/c?datastar=" & raw))
  doAssert node["count"].getInt() == 7

block readSignalsFromPostBody:
  var headers = initTable[string, string]()
  let node = readSignals(
    initRequest(HttpMethod.Post, "/c", headers, """{"count":9}""")
  )
  doAssert node["count"].getInt() == 9

block readSignalsAbsentIsEmptyObject:
  doAssert readSignals(initRequest(HttpMethod.Get, "/c")).len == 0
  var headers = initTable[string, string]()
  doAssert readSignals(initRequest(HttpMethod.Post, "/c", headers, "")).len == 0

block readSignalsInvalidRaises:
  doAssertRaises ValueError:
    discard readSignals(initRequest(HttpMethod.Get, "/c?datastar=" & encodeUrl("nope")))
  var headers = initTable[string, string]()
  doAssertRaises ValueError:
    discard readSignals(initRequest(HttpMethod.Post, "/c", headers, "nope"))
  doAssertRaises ValueError:
    discard readSignals(
      initRequest(HttpMethod.Get, "/c?datastar=" & encodeUrl("[1,2]"))
    )

block parseSignalsTyped:
  let raw = encodeUrl("""{"count":5}""")
  var value: CounterSignals
  doAssert parseSignals(initRequest(HttpMethod.Get, "/c?datastar=" & raw), value)
  doAssert value.count == 5
  var missing: CounterSignals
  doAssert not parseSignals(initRequest(HttpMethod.Get, "/c"), missing)
  var bad: CounterSignals
  doAssert not parseSignals(
    initRequest(HttpMethod.Get, "/c?datastar=" & encodeUrl("nope")), bad
  )

block datastarStreamResponse:
  let response = datastarStream(
    [patchElements("""<div id="a">1</div>"""), patchSignals(%*{"n": 1})]
  )
  doAssert response.status == 200
  doAssert response.headers["content-type"] == "text/event-stream; charset=utf-8"
  doAssert response.headers["cache-control"] == "no-cache"
  doAssert "datastar-patch-elements" in response.body
  doAssert "datastar-patch-signals" in response.body

block pluginInjectsCdnIntoHtml:
  let app = initFastNim(logs = false)
  app.install(datastarPlugin())
  app.get("/"):
    html("<html><head></head><body><div>hi</div></body></html>")
  let response = app.handle(initRequest(HttpMethod.Get, "/"))
  doAssert DatastarCdnUrl in response.body
  doAssert "<script type=\"module\"" in response.body
  doAssert response.body.count(DatastarCdnUrl) == 1

block pluginSkipsNonHtmlAndExistingTag:
  let app = initFastNim(logs = false)
  app.install(datastarPlugin())
  app.get("/data"):
    json(%*{"a": 1})
  app.get("/manual"):
    html("<html><head>" & datastarScriptTag() & "</head><body></body></html>")
  let jsonResponse = app.handle(initRequest(HttpMethod.Get, "/data"))
  doAssert DatastarCdnUrl notin jsonResponse.body
  let manual = app.handle(initRequest(HttpMethod.Get, "/manual"))
  doAssert manual.body.count(DatastarCdnUrl) == 1

block pluginInstallTrackedOnce:
  let app = initFastNim(logs = false)
  app.install(datastarPlugin())
  doAssert app.installedPlugins.len == 1
  doAssert app.installedPlugins[0].name == "datastar"
  doAssertRaises ValueError:
    app.install(datastarPlugin())

block fluentSendInSseRoute:
  let app = initFastNim(logs = false)
  app.sse("/ticker"):
    await patchElements("""<div id="t">1</div>""").send()
    await send(patchSignals(%*{"n": 1}))
    await patchElements("""<div id="t">2</div>""").sendTo(send)
  doAssert app.isSseRoute(initRequest(HttpMethod.Get, "/ticker"))
  var got: seq[string] = @[]
  let sender: SseSend = proc(
      event: ServerSentEvent
  ): Future[void] {.async: (raises: [CancelledError, HttpWriteError]).} =
    {.cast(gcsafe).}:
      got.add(formatSseEvent(event))
  waitFor app.handleSse(initRequest(HttpMethod.Get, "/ticker"), sender)
  doAssert got.len == 3
  doAssert "datastar-patch-elements" in got[0]
  doAssert "datastar-patch-signals" in got[1]
  doAssert "datastar-patch-elements" in got[2]

block liveFeedFansOutToSubscribers:
  let feed = newLiveFeed()
  doAssert feed.subscriberCount() == 0
  let first = feed.subscribe()
  let second = feed.subscribe()
  doAssert feed.subscriberCount() == 2
  feed.broadcast(patchElements("""<div id="a">1</div>"""))
  doAssert first.len == 1
  doAssert second.len == 1
  doAssert formatSseEvent(first.getNoWait().sse) ==
    formatSseEvent(patchElements("""<div id="a">1</div>"""))
  doAssert formatSseEvent(second.getNoWait().sse) ==
    formatSseEvent(patchElements("""<div id="a">1</div>"""))
  doAssert first.len == 0
  doAssert second.len == 0

block liveFeedUnsubscribeStopsDelivery:
  let feed = newLiveFeed()
  let first = feed.subscribe()
  let second = feed.subscribe()
  feed.unsubscribe(first)
  doAssert feed.subscriberCount() == 1
  feed.unsubscribe(first) # unknown queues are ignored
  doAssert feed.subscriberCount() == 1
  feed.broadcast(patchSignals(%*{"n": 2}))
  doAssert first.len == 0
  doAssert second.len == 1
  feed.unsubscribe(second)
  doAssert feed.subscriberCount() == 0
  feed.broadcast(patchSignals(%*{"n": 3})) # no subscribers: no-op, no raise
  doAssert second.len == 1

block liveFeedSnapshotRoundTrip:
  let feed = newLiveFeed()
  doAssert feed.snapshot() == ""
  feed.setSnapshot("""<ul id="feed"><li>hi</li></ul>""")
  doAssert feed.snapshot() == """<ul id="feed"><li>hi</li></ul>"""
  feed.setSnapshot("""<ul id="feed"></ul>""")
  doAssert feed.snapshot() == """<ul id="feed"></ul>"""

block liveFeedRelaysThroughSseRoute:
  let feed = newLiveFeed()
  let app = initFastNim(logs = false)
  app.sse("/notes/stream"):
    var queue: AsyncQueue[DatastarEvent]
    {.gcsafe.}:
      queue = feed.subscribe()
    try:
      await send(patchElements("""<ul id="feed"></ul>"""))
      {.gcsafe.}:
        await feed.relay(queue, send)
        await feed.relay(queue, send)
    except CatchableError:
      discard # client disconnected
    finally:
      {.gcsafe.}:
        feed.unsubscribe(queue)
  var got: seq[string] = @[]
  let sender: SseSend = proc(
      event: ServerSentEvent
  ): Future[void] {.async: (raises: [CancelledError, HttpWriteError]).} =
    {.cast(gcsafe).}:
      got.add(formatSseEvent(event))
  # Start the stream first so it subscribes, then broadcast into it.
  let pending = app.handleSse(initRequest(HttpMethod.Get, "/notes/stream"), sender)
  feed.broadcast(patchElements("""<li id="note-1">hi</li>"""))
  feed.broadcast(patchSignals(%*{"note": ""}))
  waitFor pending
  doAssert got.len == 3
  doAssert "data: elements <ul id=\"feed\"></ul>" in got[0]
  doAssert "data: elements <li id=\"note-1\">hi</li>" in got[1]
  doAssert "data: signals {\"note\":\"\"}" in got[2]
  doAssert feed.subscriberCount() == 0
