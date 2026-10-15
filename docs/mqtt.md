# MQTT

FastNim includes an MQTT broker plugin backed by Chronos TCP transports. The
MQTT listener is separate from the HTTP server: install the plugin, register
publication routes, and start it with `serveMqtt`.

The current broker supports MQTT 3.1, 3.1.1, and 5.0 connections; QoS 0 and
QoS 1 publishing; subscriptions and unsubscriptions; retained messages;
`PINGREQ`; and clean disconnects. It listens on plain TCP.

## Start a broker

`mqttPlugin` is re-exported by `fastnim`, so the basic setup needs only the
main package and Chronos:

```nim
import chronos
import fastnim

let app = initFastNim()
app.installPlugin(mqttPlugin(initMqttOptions(
  address = "127.0.0.1",
  port = 1883,
  maxPacketSize = 1024 * 1024,
)))

app.mqtt("devices/{deviceId}/telemetry"):
  echo message.topicParam("deviceId"), ": ", message.payloadString()

let mqttServer = app.serveMqtt()
waitFor mqttServer.join()
```

`serveMqtt` loads the application and starts the listener configured by
`initMqttOptions`. Its optional `address` and `port` arguments override the
installed settings for that listener.

## Route publications

An `app.mqtt` block exposes three values:

- `message` is the incoming `MqttMessage`, including its topic, binary payload,
  QoS, retain and duplicate flags, packet identifier, and captured parameters;
- `connection` contains the client id, optional username, negotiated protocol
  version, and clean-start flag;
- `ctx` is the application's shared `Context`.

Falling through accepts the publication. Return `mqttReject` to reject it
explicitly. MQTT 5 clients receive the selected reason code in the PUBACK.

```nim
app.mqtt("private/{channel}"):
  if connection.username == "":
    return mqttReject(MqttReasonCode.NotAuthorized)

  let channel = message.topicParam("channel")
  echo channel, " received ", message.payload.len, " bytes"
```

For QoS 0, a rejection cannot be acknowledged on the wire because the
protocol does not send PUBACK. MQTT 3.x has no negative PUBACK equivalent, so
explicit rejection is most useful with MQTT 5 QoS 1 publishers.

## Topic patterns

Routes accept literal levels, MQTT wildcards, and named captures:

| Pattern | Meaning |
| --- | --- |
| `devices/+/status` | One arbitrary topic level |
| `devices/#` | Any remaining topic levels; `#` must be last |
| `devices/{deviceId}/status` | One level captured as `deviceId` |
| `devices/{path...}` | Remaining levels captured as `path` |

Retrieve a named capture with `message.topicParam("name")`. It raises
`KeyError` if the matched route does not define that name. Duplicate route
patterns and malformed wildcards raise `ValueError` during registration.

## Subscriptions and retained messages

Connected clients can use MQTT `SUBSCRIBE` and `UNSUBSCRIBE`. Live accepted
publications are forwarded to matching subscribers. The initial broker grants
QoS 0 for outgoing subscription delivery, even when a subscriber requests a
higher QoS.

A retained publication replaces the retained value for its exact topic. A
retained publication with an empty payload clears it. Newly accepted
subscriptions receive matching retained publications according to their MQTT
retain-handling options.

Broker state is in memory. Client sessions, subscriptions, retained messages,
and inflight acknowledgements are not persisted across process restarts.

## Shutdown

Keep the returned server handle when the application controls its own
lifecycle:

```nim
let mqttServer = app.serveMqtt()

proc shutdown() {.async.} =
  app.stopMqtt(mqttServer)
  await mqttServer.join()
```

Call `shutdown` from the application's shutdown path. `stopMqtt` closes the
listener. Existing client transports close independently as their connection
handlers finish.

## Current boundaries

- MQTT QoS 2 publishing is rejected as unsupported.
- The built-in listener is plain TCP; terminate TLS in a TCP proxy if needed.
- Publication authorization is an application decision made from `connection`
  metadata inside routes. The listener does not reject credentials during
  `CONNECT`.
- Broker and session state are process-local and non-persistent.

