## Public MQTT protocol and handler types.

import std/tables

import chronos

import fastnim/context/state

type
  MqttVersion* {.pure.} = enum ## MQTT protocol version negotiated by a connection.
    V31 = "3.1"
    V311 = "3.1.1"
    V5 = "5.0"

  MqttQoS* {.pure.} = enum ## MQTT publication quality of service.
    AtMostOnce = 0
    AtLeastOnce = 1
    ExactlyOnce = 2

  MqttReasonCode* {.pure.} = enum ## MQTT 5 reason codes exposed to handlers.
    Success = 0x00
    NoMatchingSubscribers = 0x10
    ImplementationSpecificError = 0x83
    NotAuthorized = 0x87
    TopicNameInvalid = 0x90
    PacketTooLarge = 0x95
    PayloadFormatInvalid = 0x99

  MqttDecisionKind* {.pure.} = enum ## Outcome of an MQTT route handler.
    Accepted
    Rejected

  MqttDecision* = object ## Handler outcome translated into protocol acknowledgement behavior.
    kind*: MqttDecisionKind ## Whether processing succeeded or was rejected.
    reason*: MqttReasonCode ## MQTT 5 reason used when the outcome is rejected.

  MqttConnection* = ref object ## Identity and negotiated settings of an MQTT client.
    clientId*: string ## Client identifier supplied by CONNECT.
    username*: string ## Optional username supplied by CONNECT.
    version*: MqttVersion ## Negotiated MQTT protocol version.
    cleanStart*: bool ## Clean-session or clean-start flag from CONNECT.

  MqttMessage* = object ## An incoming MQTT PUBLISH routed to an application handler.
    topic*: string ## Topic name exactly as received from the client.
    payload*: seq[byte] ## Unmodified application payload.
    qos*: MqttQoS ## Quality of service selected by the publisher.
    retain*: bool ## Whether the publication has the RETAIN flag.
    duplicate*: bool ## Whether the publication has the DUP flag.
    packetId*: uint16 ## Packet identifier for QoS 1 or 2; zero for QoS 0.
    topicParams*: Table[string, string] ## Named values captured by the route pattern.

  MqttHandler* = proc(
    message: MqttMessage, connection: MqttConnection, ctx: Context
  ): Future[MqttDecision] {.closure, async: (raises: [CatchableError]).}
    ## Handles an incoming publication. Falling through an ``app.mqtt`` block
    ## returns an accepted decision automatically.

proc mqttAccepted*(): MqttDecision {.inline, raises: [].} =
  ## Creates the automatic successful handler outcome.
  MqttDecision(kind: MqttDecisionKind.Accepted, reason: MqttReasonCode.Success)

proc mqttReject*(reason: MqttReasonCode): MqttDecision {.inline, raises: [].} =
  ## Creates an explicit rejected handler outcome.
  MqttDecision(kind: MqttDecisionKind.Rejected, reason: reason)

proc payloadString*(message: MqttMessage): string =
  ## Copies the binary payload into a string without changing its bytes.
  result = newString(message.payload.len)
  if message.payload.len > 0:
    copyMem(addr result[0], unsafeAddr message.payload[0], message.payload.len)

proc topicParam*(message: MqttMessage, name: string): string =
  ## Returns a required named topic parameter.
  ##
  ## Raises ``KeyError`` when the matched route did not define ``name``.
  message.topicParams[name]
