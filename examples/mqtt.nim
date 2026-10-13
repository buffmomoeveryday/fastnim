## Run with: nim c -r --path:src examples/mqtt.nim

import fastnim

let app = initFastNim()

app.install:
  mqttPlugin(initMqttOptions(address = "0.0.0.0", port = 1883))

app.mqtt("/devices/{deviceId}/telemetry"):
  let deviceId = message.topicParam("deviceId")
  echo "telemetry from ", deviceId, ": ", message.payloadString

app.mqtt("/private"):
  if connection.username.len == 0:
    return mqttReject(MqttReasonCode.NotAuthorized)

  echo message.payloadString

let server = app.serveMqtt()
echo "MQTT listening on 0.0.0.0:1883"
waitFor server.join()
