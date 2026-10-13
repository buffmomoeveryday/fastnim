import std/[assertions, tables]

import chronos

import fastnim

var routedDeviceLength {.global.}: int
var routedPayloadByte {.global.}: byte
var integrationPayloadByte {.global.}: byte

proc packetBytes(values: openArray[int]): seq[byte] =
  for value in values:
    result.add(byte(value))

block decodesFragmentedPackets:
  var decoder = initMqttDecoder(maxPacketSize = 64)
  doAssert decoder.feed(packetBytes([0xC0])).len == 0
  let packets = decoder.feed(packetBytes([0x00, 0xE0, 0x00]))
  doAssert packets.len == 2
  doAssert packets[0].fixedHeader == 0xC0
  doAssert packets[0].body.len == 0
  doAssert packets[1].fixedHeader == 0xE0

block rejectsOversizedPackets:
  var decoder = initMqttDecoder(maxPacketSize = 1)
  doAssertRaises MqttProtocolError:
    discard decoder.feed(packetBytes([0x30, 0x02, 0x00, 0x00]))

block routesNamedParametersAndAcceptsFallthrough:
  let app = initFastNim(logs = false)
  app.install(mqttPlugin())
  routedDeviceLength = 0
  routedPayloadByte = 0
  app.mqtt("/devices/{deviceId}/telemetry"):
    routedDeviceLength = message.topicParam("deviceId").len
    routedPayloadByte = message.payload[0]

  let message = MqttMessage(
    topic: "/devices/sensor-7/telemetry",
    payload: packetBytes([0x6F, 0x6B]),
    qos: MqttQoS.AtMostOnce,
    topicParams: initTable[string, string](),
  )
  let connection = MqttConnection(
    clientId: "test", version: MqttVersion.V311, cleanStart: true
  )
  let decision = waitFor app.handleMqtt(message, connection)
  doAssert decision.kind == MqttDecisionKind.Accepted
  doAssert routedDeviceLength == 8
  doAssert routedPayloadByte == byte('o')

block supportsExplicitRejection:
  let app = initFastNim(logs = false)
  app.install(mqttPlugin())
  app.mqtt("/private"):
    return mqttReject(MqttReasonCode.NotAuthorized)

  let message = MqttMessage(
    topic: "/private", topicParams: initTable[string, string]()
  )
  let connection = MqttConnection(
    clientId: "anonymous", version: MqttVersion.V5, cleanStart: true
  )
  let decision = waitFor app.handleMqtt(message, connection)
  doAssert decision.kind == MqttDecisionKind.Rejected
  doAssert decision.reason == MqttReasonCode.NotAuthorized

proc mqttExchangeClient() {.async.} =
  let client = await connect(initTAddress("127.0.0.1", Port(18884)))
  try:
    let connectPacket = packetBytes([
      0x10, 0x10,
      0x00, 0x04, 0x4D, 0x51, 0x54, 0x54,
      0x04, 0x02, 0x00, 0x3C,
      0x00, 0x04, 0x74, 0x65, 0x73, 0x74,
    ])
    discard await client.write(connectPacket)
    doAssert (await client.read(4)) == packetBytes([0x20, 0x02, 0x00, 0x00])

    let publishPacket = packetBytes([
      0x32, 0x0C,
      0x00, 0x06, 0x2F, 0x72, 0x6F, 0x75, 0x74, 0x65,
      0x00, 0x01,
      0x6F, 0x6B,
    ])
    discard await client.write(publishPacket)
    doAssert (await client.read(4)) == packetBytes([0x40, 0x02, 0x00, 0x01])
    doAssert integrationPayloadByte == byte('o')

    discard await client.write(packetBytes([0xC0, 0x00]))
    doAssert (await client.read(2)) == packetBytes([0xD0, 0x00])
    discard await client.write(packetBytes([0xE0, 0x00]))
  finally:
    await client.closeWait()

proc mqttV5RejectionClient() {.async.} =
  let client = await connect(initTAddress("127.0.0.1", Port(18884)))
  try:
    let connectPacket = packetBytes([
      0x10, 0x11,
      0x00, 0x04, 0x4D, 0x51, 0x54, 0x54,
      0x05, 0x02, 0x00, 0x3C, 0x00,
      0x00, 0x04, 0x76, 0x66, 0x69, 0x76,
    ])
    discard await client.write(connectPacket)
    doAssert (await client.read(5)) ==
      packetBytes([0x20, 0x03, 0x00, 0x00, 0x00])

    let publishPacket = packetBytes([
      0x32, 0x0E,
      0x00, 0x08, 0x2F, 0x70, 0x72, 0x69, 0x76, 0x61, 0x74, 0x65,
      0x00, 0x07, 0x00,
      0x6E,
    ])
    discard await client.write(publishPacket)
    doAssert (await client.read(6)) ==
      packetBytes([0x40, 0x04, 0x00, 0x07, 0x87, 0x00])
  finally:
    await client.closeWait()

block exchangesMqttPacketsOverTcp:
  let app = initFastNim(logs = false)
  app.install(mqttPlugin(initMqttOptions(port = 18884)))
  integrationPayloadByte = 0
  app.mqtt("/route"):
    integrationPayloadByte = message.payload[0]
  app.mqtt("/private"):
    return mqttReject(MqttReasonCode.NotAuthorized)

  let server = app.serveMqtt()
  try:
    waitFor mqttExchangeClient()
    waitFor mqttV5RejectionClient()
  finally:
    app.stopMqtt(server)
    waitFor server.join()
