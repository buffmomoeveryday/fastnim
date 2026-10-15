## Run with: nim c -r --path:src examples/datastar.nim
##
## A fuller Datastar demo for FastNim. It covers:
##   * counter          - server-authoritative POST, fanned out to every tab
##   * todo list        - add / toggle / delete, removeElements, query params
##   * live search      - debounced GET, readSignals on a GET
##   * SSE ticker       - long-lived app.sse stream, loading indicator
##   * live feed        - real-time fan-out: one post updates every open tab
##   * executeScript    - run JS in the browser (console log)
##   * redirect         - server-driven navigation
##
## Open http://127.0.0.1:8000 (open it in two tabs to see the live feed).

import std/[json, strutils, xmltree]

import chronos/asyncsync
import fastnim
import fastnim/plugins/datastar

const Port = 8000

# --------------------------------------------------------------------------
# State (in-memory; chronos is single-threaded so no locking is needed)
# --------------------------------------------------------------------------
type Todo = object
  id: int
  text: string
  done: bool

var
  todos: seq[Todo] = @[
    Todo(id: 1, text: "Read the Datastar docs", done: true),
    Todo(id: 2, text: "Build something hypermedia-y", done: false),
  ]
  nextId = 3

# Server-authoritative counter: the client signal is only a display mirror.
# A client-only reset desyncs the display, and the next increment re-syncs
# it from the server value instead of restarting from the display value.
var serverCount = 0

var
  feedNotes: seq[tuple[id: int, text: string]] = @[]
  feedNextId = 1

# --------------------------------------------------------------------------
# Rendering helpers (always escape user text!)
# --------------------------------------------------------------------------
proc renderTodo(t: Todo): string =
  let id = $t.id
  result =
    """<li id="todo-""" & id & """" class="""" & (if t.done: "done" else: "") & """">""" &
    """<input type="checkbox" """ & (if t.done: "checked " else: "") &
    """data-on:change="@post('/todos/toggle?id=""" & id & """')">""" & """<span>""" &
    xmltree.escape(t.text) & """</span>""" &
    """<button data-on:click="@post('/todos/delete?id=""" & id & """')">x</button>""" &
    """</li>"""

proc renderTodos(): string =
  result = """<ul id="todos">"""
  for t in todos:
    result.add renderTodo(t)
  result.add "</ul>"

proc renderStats(): string =
  var open = 0
  for t in todos:
    if not t.done:
      inc open
  """<small id="stats">""" & $open & " open / " & $todos.len & " total</small>"

proc renderResults(matches: seq[Todo], q: string): string =
  result = """<ul id="results">"""
  if q.len == 0:
    result.add """<li class="muted">Type to search…</li>"""
  elif matches.len == 0:
    result.add """<li class="muted">No matches for "<b>""" & xmltree.escape(q) &
      """</b>"</li>"""
  else:
    for t in matches:
      result.add "<li>" & xmltree.escape(t.text) & "</li>"
  result.add "</ul>"

proc renderFeedItem(id: int, text: string): string =
  "<li id=\"note-" & $id & "\">" & xmltree.escape(text) & "</li>"

proc renderFeed(): string =
  result = """<ul id="feed">"""
  if feedNotes.len == 0:
    result.add """<li class="muted">No notes yet — post one, with a second tab open.</li>"""
  else:
    for n in feedNotes:
      result.add renderFeedItem(n.id, n.text)
  result.add "</ul>"

proc renderCount(): string =
  """<b id="count">""" & $serverCount & "</b>"

proc todoIdParam(request: Request): int =
  try:
    parseInt(request.queryParam("id"))
  except ValueError:
    -1

proc findTodo(id: int): int =
  for i, t in todos:
    if t.id == id:
      return i
  -1

# --------------------------------------------------------------------------
# App
# --------------------------------------------------------------------------

let app = initFastNim()

app.installPlugin:
  datastarPlugin()

# Live feed hub: one post fans out to every connected tab. The hub owns the
# current snapshot so newly connected tabs render immediately.
let feed = newLiveFeed()
feed.setSnapshot(renderFeed())

# Counter fan-out hub: every increment reaches every open tab, just like notes.
let countFeed = newLiveFeed()
countFeed.setSnapshot(renderCount())

const Css = """
<style>
  body { font-family: system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
  section { border: 1px solid #ddd; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
  h2 { margin-top: 0; font-size: 1.1rem; }
  li.done span { text-decoration: line-through; color: #888; }
  li { list-style: none; display: flex; gap: .5rem; align-items: center; padding: .15rem 0; }
  li span { flex: 1; }
  .muted { color: #888; }
  button[disabled] { opacity: .5; }
</style>
"""

app.get("/"):
  html(
    """<html><head><title>FastNim + Datastar</title>""" & Css & """</head><body>""" &
    # All client-side signals declared once, on the body.
    """<div data-signals='{"count": 0, "newTodo": "", "q": "", "ticked": false, "note": "", "feedLive": false}'></div>""" &
      """<h1>FastNim + Datastar</h1>""" &

    # ---- Counter ---------------------------------------------------------
    """<section><h2>Counter</h2>""" & """<div data-init="@get('/count/stream')"></div>""" &
      """<div>Server count: <b id="count">0</b> | Client signal: <b data-text="$count"></b></div>""" &
      """<button data-on:click="@post('/increment')">Increment</button> """ &
      """<button data-on:click="$count = 0">Reset (client only)</button>""" &
      """</section>""" &

    # ---- Todos -----------------------------------------------------------
    """<section><h2>Todos</h2>""" &
      """<input type="text" placeholder="New todo" data-bind:new-todo """ &
      """data-on:keydown="evt.key === 'Enter' && @post('/todos/add')"> """ &
      """<button data-on:click="@post('/todos/add')">Add</button> """ & renderStats() &
      renderTodos() & """</section>""" &

    # ---- Live search -----------------------------------------------------
    """<section><h2>Live search</h2>""" &
      """<input type="search" placeholder="Search todos" data-bind:q """ &
      """data-on:input__debounce.250ms="@get('/search')">""" & renderResults(@[], "") &
      """</section>""" &

    # ---- SSE ticker ------------------------------------------------------
    """<section><h2>SSE ticker</h2>""" &
      """<div>Tick: <b id="tick">0</b> <span data-show="$ticked">(finished)</span></div>""" &
      """<button data-on:click="@get('/ticker')" data-indicator:ticking """ &
      """data-attr:disabled="$ticking">Start ticker</button> """ &
      """<span data-show="$ticking" class="muted">streaming…</span>""" &
      """</section>""" &

    # ---- Live feed (real-time across tabs) ---------------------------------
    """<section><h2>Live feed</h2>""" &
      """<p class="muted">Real-time fan-out: open this page in a second tab, post here, and watch both update with no refresh.</p>""" &
      """<div data-init="@get('/notes/stream')"></div>""" &
      """<div>Status: <span data-show="$feedLive" class="muted">live</span><span data-show="!$feedLive" class="muted">connecting…</span></div>""" &
      renderFeed() &
      """<input type="text" placeholder="Post a note to every tab" data-bind:note """ &
      """data-on:keydown="evt.key === 'Enter' && @post('/notes/add')"> """ &
      """<button data-on:click="@post('/notes/add')">Post</button>""" & """</section>""" &

      # ---- Misc server-driven actions -------------------------------------
      """<section><h2>Server actions</h2>""" &
      """<button data-on:click="@post('/log')">Run script in browser</button> """ &
      """<button data-on:click="@post('/go-about')">Redirect to /about</button>""" &
      """</section>""" & """</body></html>"""
  )

app.get("/about"):
  html(
    """<html><head><title>About</title></head><body><h1>About</h1><a href="/">Back</a></body></html>"""
  )

# ---- Counter (server is the source of truth, fanned out to every tab) -----------
app.post("/increment"):
  inc serverCount
  let countHtml = renderCount()
  let countEvent = patchElements(countHtml)
  let countSignals = patchSignals(%*{"count": serverCount})
  countFeed.setSnapshot(countHtml)

  countFeed.broadcast(countEvent)
  countFeed.broadcast(countSignals)

  datastarStream([countEvent, countSignals])

app.sse("/count/stream"):
  var queue: AsyncQueue[DatastarEvent]
  {.gcsafe.}:
    queue = countFeed.subscribe()
  try:
    var firstHtml = ""
    var current = 0
    {.gcsafe.}:
      firstHtml = countFeed.snapshot()
      current = serverCount
    if firstHtml.len > 0:
      await send(patchElements(firstHtml))
    await send(patchSignals(%*{"count": current}))
    while true:
      {.gcsafe.}:
        await countFeed.relay(queue, send)
  except CatchableError:
    discard # client disconnected; cleanup below
  finally:
    {.gcsafe.}:
      countFeed.unsubscribe(queue)

# ---- Todos -------------------------------------------------------------------
app.post("/todos/add"):
  let text = readSignals(request).getOrDefault("newTodo").getStr("").strip()
  if text.len > 0:
    todos.add Todo(id: nextId, text: text)
    inc nextId

  datastarStream(
    [
      renderTodos().patchElements(),
      renderStats().patchElements(),
      patchSignals(%*{"newTodo": ""}),
        # clears the bound input (call syntax: %* can't prefix a dot-call)
    ]
  )

app.post("/todos/toggle"):
  let idx = findTodo(todoIdParam(request))
  if idx >= 0:
    todos[idx].done = not todos[idx].done
    datastarStream(
      [
        patchElements renderTodo(todos[idx]),
        patchElements renderStats() # renders stats
        ,
      ]
    )
  else:
    datastarStream([removeElements("#todo-" & request.queryParam("id"))])

app.post("/todos/delete"):
  let id = todoIdParam(request)
  let idx = findTodo(id)
  if idx >= 0:
    todos.delete(idx)
  datastarStream([removeElements("#todo-" & $id), patchElements(renderStats())])

# ---- Live search (GET: signals arrive as ?datastar=<json>) --------------------
app.get("/search"):
  let q = request.readSignals().getOrDefault("q").getStr("").strip()
  var matches: seq[Todo] = @[]
  if q.len > 0:
    for t in todos:
      if q.toLowerAscii() in t.text.toLowerAscii():
        matches.add t
  datastarStream([patchElements(renderResults(matches, q))])

# ---- SSE ticker --------------------------------------------------------------
app.sse("/ticker"):
  await patchSignals(%*{"ticked": false}).send()
  for i in 1 .. 10:
    await patchElements("""<b id="tick">""" & $i & "</b>").send()
    await sleepAsync 1.seconds
  await patchSignals(%*{"ticked": true}).send()

# ---- Live feed: one post fans out to every connected tab -----------------------
app.sse("/notes/stream"):
  var queue: AsyncQueue[DatastarEvent]
  {.gcsafe.}:
    queue = feed.subscribe()
  try:
    var firstHtml = ""
    {.gcsafe.}:
      firstHtml = feed.snapshot()

    if firstHtml.len > 0:
      await send(patchElements(firstHtml))

    await send(patchSignals(%*{"feedLive": true}))
    while true:
      {.gcsafe.}:
        await feed.relay(queue, send)
  except CatchableError:
    discard # client disconnected; cleanup below
  finally:
    {.gcsafe.}:
      feed.unsubscribe(queue)

app.post("/notes/add"):
  let note = readSignals(request).getOrDefault("note").getStr("").strip()
  if note.len > 0:
    feedNotes.add((id: feedNextId, text: note))
    inc feedNextId
  let html = renderFeed()
  let event = patchElements(html)
  feed.setSnapshot(html)
  feed.broadcast(event) # every connected tab, synchronously
  datastarStream([event, patchSignals(%*{"note": ""})])

# ---- Script execution + redirect ----------------------------------------------
app.post("/log"):
  datastarStream([executeScript("console.log('Hello from the FastNim server!')")])

app.post("/go-about"):
  datastarStream([redirect("/about")])

proc feedHeartbeat() {.gcsafe, async.} =
  ## Keeps idle streams alive through proxies and bounds dead-client
  ## detection: the next relay after a heartbeat fails on dead connections,
  ## which unsubscribes them. Merging `{}` changes no signals.
  while true:
    await sleepAsync(25.seconds)
    {.gcsafe.}:
      feed.broadcast(patchSignals(newJObject()))
      countFeed.broadcast(patchSignals(newJObject()))

let server = app.serve(port = Port)
echo "Datastar demo: http://127.0.0.1:" & $Port
asyncSpawn feedHeartbeat()
waitFor server.join()
