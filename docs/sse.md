# Server-Sent Events

Server-Sent Events (SSE) provide a one-way stream from the server to a browser
or HTTP client. FastNim SSE routes use Chronos throughout and emit the
`text/event-stream` wire format.

## Streaming endpoint

Register a long-lived GET endpoint with `app.sse`. The block receives the
normal `request` value and a generated async `send` operation.

```nim
import chronos
import fastnim

let app = initFastNim()

app.sse("/events"):
  await send(sseEvent("connected", event = "status", id = "1", retry = 3000))
  await send(sseEvent("fastnim is ready", event = "message", id = "2"))

let server = app.serve(port = 8000)
waitFor server.join()
```

Method syntax is also supported:

```nim
app.sse("/events"):
  await sseEvent("ready", event = "status").send()
```

Run [`examples/sse.nim`](../examples/sse.nim), then inspect the stream with:

```text
curl -N http://127.0.0.1:8000/events
```

## Event fields

Create events with `sseEvent(data, event, id, retry)`:

| Field | Purpose |
| --- | --- |
| `data` | Payload delivered to the client; every line becomes a `data:` line |
| `event` | Optional event name used by `addEventListener` |
| `id` | Optional browser reconnection cursor |
| `retry` | Optional reconnection delay in milliseconds; `-1` omits it |

Event names and ids cannot contain line breaks. `retry` must be non-negative
when present. `formatSseEvent` exposes the encoded wire representation for
testing and integrations.

JSON payloads are ordinary strings. Construct them explicitly when clients
expect JSON:

```nim
import std/json

app.sse("/ticker/{symbol}"):
  let payload = $(%*{
    "symbol": request.pathParam("symbol"),
    "price": 101.25,
  })
  await send(sseEvent(payload, event = "price", id = "1"))
```

## Browser client

Browsers reconnect an `EventSource` automatically. Named events use
`addEventListener`; unnamed events arrive through `onmessage`.

```javascript
const source = new EventSource("/events");

source.addEventListener("status", event => {
  console.log(event.lastEventId, event.data);
});

source.onmessage = event => {
  console.log(event.data);
};

source.onerror = () => {
  // EventSource reconnects using the server's retry value.
};
```

Use the `Last-Event-ID` request header to resume an application stream when
event history is available. FastNim transmits ids but does not retain or replay
events automatically.

## Finite SSE responses

For a finite list that does not require incremental writes, return
`eventStream` from a normal HTTP route:

```nim
app.get("/snapshot"):
  eventStream([
    sseEvent("one", id = "1"),
    sseEvent("two", id = "2"),
  ])
```

The response has status 200, `text/event-stream; charset=utf-8`, and
`cache-control: no-cache`. An overload accepts an `HttpStatus` first.

## Disconnects, limits, and heartbeats

An SSE `send` awaits the underlying transport. When the client disconnects or
a write times out, the handler exits through its write error. Keep per-client
cleanup in `finally` blocks and allow `CancelledError` to propagate.

Configure SSE connection capacity, write timeout, event size, and automatic
comment heartbeat interval through `RequestLimits`:

```nim
let limits = initRequestLimits(
  sse = initSseLimits(
    maxConnections = 256,
    idleTimeout = 30.seconds,
    maxEventSize = 256 * 1024,
    heartbeatInterval = 15.seconds,
  )
)

let app = initFastNim(limits = limits)
```

Use `InfiniteDuration` to disable the write deadline or heartbeat. SSE routes
bypass ordinary HTTP middleware and `handlerTimeout`; their dedicated limits
bound these long-lived streams instead.

