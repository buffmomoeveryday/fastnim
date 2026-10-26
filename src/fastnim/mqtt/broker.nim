## Connected-client and subscription state for the MQTT broker.

import std/tables

import chronos

import ../mqtt/[codec, topics, types]

type
  MqttSubscription* = object ## One active protocol subscription.
    filter*: string ## MQTT topic filter supplied by SUBSCRIBE.
    noLocal*: bool ## Whether publications from the same connection are excluded.
    retainAsPublished*: bool ## Whether live delivery preserves the RETAIN flag.

  MqttPeer* = ref object ## Internal handle for one connected MQTT client.
    connection*: MqttConnection ## Public metadata negotiated during CONNECT.
    transport*: StreamTransport ## Chronos transport used for broker packets.
    subscriptions*: seq[MqttSubscription] ## Active non-persistent subscriptions.
    writeLock: AsyncLock

  MqttBroker* = ref object ## In-memory registry of connected MQTT clients.
    peers: seq[MqttPeer]
    retained: Table[string, MqttMessage]

proc newMqttBroker*(): MqttBroker =
  ## Creates an empty in-memory broker registry.
  MqttBroker(peers: @[], retained: initTable[string, MqttMessage]())

proc newMqttPeer*(transport: StreamTransport): MqttPeer =
  ## Creates connection state for an accepted transport.
  MqttPeer(transport: transport, subscriptions: @[], writeLock: newAsyncLock())

proc add*(broker: MqttBroker, peer: MqttPeer) =
  ## Adds a connected peer to the broker registry.
  broker.peers.add(peer)

proc remove*(broker: MqttBroker, peer: MqttPeer) =
  ## Removes a peer and all of its non-persistent subscriptions.
  for index, candidate in broker.peers:
    if candidate == peer:
      broker.peers.delete(index)
      return

proc subscribe*(
    peer: MqttPeer, filter: string, noLocal, retainAsPublished: bool
): bool =
  ## Adds or replaces a subscription and reports whether it was newly added.
  for subscription in peer.subscriptions.mitems:
    if subscription.filter == filter:
      subscription.noLocal = noLocal
      subscription.retainAsPublished = retainAsPublished
      return false
  peer.subscriptions.add(
    MqttSubscription(
      filter: filter, noLocal: noLocal, retainAsPublished: retainAsPublished
    )
  )
  true

proc unsubscribe*(peer: MqttPeer, filter: string): bool =
  ## Removes a subscription and reports whether it existed.
  for index, subscription in peer.subscriptions:
    if subscription.filter == filter:
      peer.subscriptions.delete(index)
      return true
  false

proc writePacket*(
    peer: MqttPeer, packet: seq[byte]
): Future[void] {.async: (raises: [CancelledError, TransportError]).} =
  ## Writes one complete packet without interleaving concurrent broker output.
  await peer.writeLock.acquire()
  try:
    discard await peer.transport.write(packet)
  finally:
    try:
      peer.writeLock.release()
    except AsyncLockError:
      raiseAssert "MQTT peer write lock was released unexpectedly"

proc addUint16(packet: var seq[byte], value: uint16) =
  packet.add(byte(value shr 8))
  packet.add(byte(value and 0xFF))

proc outgoingPublish(
    message: MqttMessage, version: MqttVersion, retain: bool
): seq[byte] =
  var body: seq[byte]
  body.addUint16(uint16(message.topic.len))
  for value in message.topic:
    body.add(byte(value))
  if version == MqttVersion.V5:
    body.add(0'u8)
  body.add(message.payload)
  result = @[if retain: 0x31'u8 else: 0x30'u8]
  try:
    result.add(encodeRemainingLength(body.len))
  except ValueError:
    raiseAssert "validated MQTT publication exceeded the protocol packet limit"
  result.add(body)

proc publishToSubscribers*(
    broker: MqttBroker, source: MqttPeer, message: MqttMessage
): Future[void] {.async: (raises: [CancelledError]).} =
  ## Delivers an accepted publication to every matching connected subscriber.
  ##
  ## This initial subscription implementation grants QoS 0, so outgoing
  ## publications do not create inflight acknowledgement state.
  var recipients: seq[MqttPeer]
  var retainFlags: seq[bool]
  for peer in broker.peers:
    var matched = false
    var retain = false
    for subscription in peer.subscriptions:
      if matchMqttTopicFilter(subscription.filter, message.topic) and
          (peer != source or not subscription.noLocal):
        matched = true
        retain = retain or (subscription.retainAsPublished and message.retain)
    if matched:
      recipients.add(peer)
      retainFlags.add(retain)

  for index, peer in recipients:
    if not peer.transport.closed():
      try:
        await peer.writePacket(
          outgoingPublish(message, peer.connection.version, retainFlags[index])
        )
      except TransportError:
        discard

proc updateRetained*(broker: MqttBroker, message: MqttMessage) =
  ## Stores or clears the retained publication for a topic.
  if not message.retain:
    return
  if message.payload.len == 0:
    broker.retained.del(message.topic)
  else:
    broker.retained[message.topic] = message

proc sendRetained*(
    broker: MqttBroker, peer: MqttPeer, filter: string
): Future[void] {.async: (raises: [CancelledError]).} =
  ## Replays retained publications matching a newly accepted subscription.
  var messages: seq[MqttMessage]
  for _, message in broker.retained:
    if matchMqttTopicFilter(filter, message.topic):
      messages.add(message)
  for message in messages:
    if not peer.transport.closed():
      try:
        await peer.writePacket(
          outgoingPublish(message, peer.connection.version, retain = true)
        )
      except TransportError:
        discard
