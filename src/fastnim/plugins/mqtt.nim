## MQTT broker plugin and ``app.mqtt`` route DSL.
##
## The current transport supports MQTT 3.1, 3.1.1, and 5.0 CONNECT,
## QoS 0/1 PUBLISH, subscriptions, retained messages, PING, and DISCONNECT
## over plain TCP.

import std/[macros, tables]

import chronos

import ../context/state, ../plugin, ../routing/router
import ../mqtt/[broker, codec, topics, types]

export codec, types

const
  MqttPluginName = "mqtt"
  MqttRuntimeKey = "runtime"

type
  MqttOptions* = object ## Configuration for the FastNim MQTT TCP listener.
    address*: string ## Address on which the listener binds.
    port*: uint16 ## TCP port on which the listener binds.
    versions*: set[MqttVersion] ## Protocol versions accepted during CONNECT.
    maxPacketSize*: int ## Maximum variable-header and payload size in bytes.

  MqttServer* = ref object ## Handle for a running MQTT listener.
    stream: StreamServer

  MqttRoute = object
    pattern: string
    handler: MqttHandler

  MqttRuntime = ref object
    options: MqttOptions
    routes: seq[MqttRoute]
    broker: MqttBroker

  MqttConnectionState = ref object
    peer: MqttPeer

  MqttSubscriptionRequest = object
    filter: string
    noLocal: bool
    retainAsPublished: bool
    retainHandling: int

  PacketCursor = object
    data: seq[byte]
    position: int

proc initMqttOptions*(
    address = "127.0.0.1",
    port: uint16 = 1883,
    versions = {MqttVersion.V31, MqttVersion.V311, MqttVersion.V5},
    maxPacketSize = 1024 * 1024,
): MqttOptions =
  ## Creates validated MQTT listener settings.
  if address.len == 0:
    raise newException(ValueError, "MQTT listener address cannot be empty")
  if versions == {}:
    raise newException(ValueError, "at least one MQTT version must be enabled")
  if maxPacketSize <= 0:
    raise newException(ValueError, "MQTT maximum packet size must be positive")
  MqttOptions(
    address: address, port: port, versions: versions, maxPacketSize: maxPacketSize
  )

proc mqttPlugin*(options = initMqttOptions()): Plugin =
  ## Creates the MQTT plugin. Install it before registering MQTT routes.
  initPlugin(
    MqttPluginName,
    "0.1.0",
    proc(app: Application) =
      let runtime = MqttRuntime(options: options, routes: @[], broker: newMqttBroker())
      app.pluginContext(MqttPluginName).setContext(MqttRuntimeKey, runtime),
  )

proc mqttRuntime(app: Application): MqttRuntime =
  let pluginCtx = app.pluginContext(MqttPluginName)
  if not pluginCtx.has(MqttRuntimeKey):
    raise newException(
      ValueError,
      "MQTT plugin is not installed; call app.installPlugin(mqttPlugin()) first",
    )
  pluginCtx.get(MqttRuntimeKey, MqttRuntime)

proc addMqttRoute*(app: Application, pattern: string, handler: MqttHandler) =
  ## Registers a compiled MQTT publication handler.
  validateMqttPattern(pattern)
  if handler.isNil:
    raise newException(ValueError, "MQTT route handler cannot be nil")
  let runtime = app.mqttRuntime()
  for route in runtime.routes:
    if route.pattern == pattern:
      raise newException(ValueError, "duplicate MQTT route pattern: " & pattern)
  runtime.routes.add(MqttRoute(pattern: pattern, handler: handler))

proc replaceMqttNames(
    node, messageParam, connectionParam, contextParam: NimNode
): NimNode =
  if node.kind == nnkIdent:
    if eqIdent(node, "message"):
      return messageParam
    if eqIdent(node, "connection"):
      return connectionParam
    if eqIdent(node, "ctx"):
      return contextParam
    return node
  result = copyNimNode(node)
  for child in node:
    result.add(replaceMqttNames(child, messageParam, connectionParam, contextParam))

macro mqtt*(app: Application, pattern: typed, body: untyped): untyped =
  ## Registers an asynchronous MQTT PUBLISH route.
  ##
  ## ``message``, ``connection``, and ``ctx`` are available inside the block.
  ## Successful fallthrough is acknowledged automatically. Use
  ## ``return mqttReject(reason)`` for explicit rejection.
  let messageParam = genSym(nskParam, "message")
  let connectionParam = genSym(nskParam, "connection")
  let contextParam = genSym(nskParam, "ctx")
  let handler = genSym(nskLet, "mqttHandler")
  let handlerBody = replaceMqttNames(body, messageParam, connectionParam, contextParam)
  result = quote:
    let `handler`: MqttHandler = proc(
        `messageParam`: MqttMessage,
        `connectionParam`: MqttConnection,
        `contextParam`: Context,
    ): Future[MqttDecision] {.async: (raises: [CatchableError]).} =
      result = mqttAccepted()
      `handlerBody`
    addMqttRoute(`app`, `pattern`, `handler`)

proc handleMqtt*(
    app: Application, message: MqttMessage, connection: MqttConnection
): Future[MqttDecision] {.async: (raises: [CatchableError]).} =
  ## Routes an MQTT message. A message without a matching application route is accepted.
  let runtime = app.mqttRuntime()
  for route in runtime.routes:
    var params = initTable[string, string]()
    if matchMqttTopic(route.pattern, message.topic, params):
      var routed = message
      routed.topicParams = params
      return await route.handler(routed, connection, app.context)
  mqttAccepted()

proc require(cursor: PacketCursor, count: int) =
  if count < 0 or cursor.position + count > cursor.data.len:
    raise newException(MqttProtocolError, "truncated MQTT packet")

proc readByte(cursor: var PacketCursor): byte =
  cursor.require(1)
  result = cursor.data[cursor.position]
  inc cursor.position

proc readUint16(cursor: var PacketCursor): uint16 =
  cursor.require(2)
  result =
    (uint16(cursor.data[cursor.position]) shl 8) or
    uint16(cursor.data[cursor.position + 1])
  cursor.position += 2

proc readBytes(cursor: var PacketCursor, count: int): seq[byte] =
  cursor.require(count)
  result = newSeq[byte](count)
  if count > 0:
    copyMem(addr result[0], addr cursor.data[cursor.position], count)
  cursor.position += count

proc bytesToString(data: openArray[byte]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc readUtf8(cursor: var PacketCursor): string =
  let length = int(cursor.readUint16())
  result = bytesToString(cursor.readBytes(length))
  if '\0' in result:
    raise newException(MqttProtocolError, "MQTT UTF-8 value contains a null byte")

proc readBinary(cursor: var PacketCursor): seq[byte] =
  cursor.readBytes(int(cursor.readUint16()))

proc readVariableInteger(cursor: var PacketCursor): int =
  var multiplier = 1
  var count = 0
  while true:
    let current = int(cursor.readByte())
    result += (current and 0x7F) * multiplier
    inc count
    if (current and 0x80) == 0:
      return
    if count == 4:
      raise newException(MqttProtocolError, "malformed MQTT variable integer")
    multiplier *= 128

proc skipProperties(cursor: var PacketCursor) =
  let length = cursor.readVariableInteger()
  cursor.require(length)
  cursor.position += length

proc parseConnect(packet: MqttPacket, options: MqttOptions): MqttConnection =
  if packet.fixedHeader != 0x10:
    raise newException(MqttProtocolError, "the first MQTT packet must be CONNECT")
  var cursor = PacketCursor(data: packet.body)
  let protocolName = cursor.readUtf8()
  let protocolLevel = cursor.readByte()
  let version =
    if protocolName == "MQIsdp" and protocolLevel == 3:
      MqttVersion.V31
    elif protocolName == "MQTT" and protocolLevel == 4:
      MqttVersion.V311
    elif protocolName == "MQTT" and protocolLevel == 5:
      MqttVersion.V5
    else:
      raise newException(MqttProtocolError, "unsupported MQTT protocol version")
  if version notin options.versions:
    raise newException(MqttProtocolError, "MQTT protocol version is disabled")

  let flags = int(cursor.readByte())
  if (flags and 0x01) != 0 or ((flags and 0x40) != 0 and (flags and 0x80) == 0):
    raise newException(MqttProtocolError, "invalid MQTT CONNECT flags")
  discard cursor.readUint16()
  if version == MqttVersion.V5:
    cursor.skipProperties()

  let clientId = cursor.readUtf8()
  let willFlag = (flags and 0x04) != 0
  let willQos = (flags shr 3) and 0x03
  if (not willFlag and (willQos != 0 or (flags and 0x20) != 0)) or willQos == 3:
    raise newException(MqttProtocolError, "invalid MQTT Will flags")
  if willFlag:
    if version == MqttVersion.V5:
      cursor.skipProperties()
    discard cursor.readUtf8()
    discard cursor.readBinary()

  var username = ""
  if (flags and 0x80) != 0:
    username = cursor.readUtf8()
  if (flags and 0x40) != 0:
    discard cursor.readBinary()
  if cursor.position != cursor.data.len:
    raise newException(MqttProtocolError, "unexpected MQTT CONNECT payload bytes")

  MqttConnection(
    clientId: clientId,
    username: username,
    version: version,
    cleanStart: (flags and 0x02) != 0,
  )

proc connAck(version: MqttVersion): seq[byte] =
  if version == MqttVersion.V5:
    @[0x20'u8, 0x03, 0x00, 0x00, 0x00]
  else:
    @[0x20'u8, 0x02, 0x00, 0x00]

proc parsePublish(packet: MqttPacket, version: MqttVersion): MqttMessage =
  let qosValue = (int(packet.fixedHeader) shr 1) and 0x03
  if qosValue == 3 or qosValue == 2:
    raise newException(MqttProtocolError, "MQTT QoS 2 is not implemented yet")
  var cursor = PacketCursor(data: packet.body)
  let topic = cursor.readUtf8()
  if topic.len == 0 or '+' in topic or '#' in topic:
    raise newException(MqttProtocolError, "invalid MQTT PUBLISH topic")
  var packetId: uint16
  if qosValue > 0:
    packetId = cursor.readUint16()
    if packetId == 0:
      raise newException(MqttProtocolError, "MQTT packet identifier cannot be zero")
  if version == MqttVersion.V5:
    cursor.skipProperties()
  let payload = cursor.readBytes(cursor.data.len - cursor.position)
  MqttMessage(
    topic: topic,
    payload: payload,
    qos: MqttQoS(qosValue),
    retain: (packet.fixedHeader and 0x01) != 0,
    duplicate: (packet.fixedHeader and 0x08) != 0,
    packetId: packetId,
    topicParams: initTable[string, string](),
  )

proc publishAck(
    message: MqttMessage, connection: MqttConnection, decision: MqttDecision
): seq[byte] =
  if message.qos == MqttQoS.AtMostOnce:
    return @[]
  let highByte = byte(message.packetId shr 8)
  let lowByte = byte(message.packetId and 0xFF)
  if decision.kind == MqttDecisionKind.Accepted:
    return @[0x40'u8, 0x02, highByte, lowByte]
  if connection.version == MqttVersion.V5:
    return @[0x40'u8, 0x04, highByte, lowByte, byte(decision.reason), 0x00]
  @[]

proc requireTopicFilter(filter: string) =
  try:
    validateMqttTopicFilter(filter)
  except ValueError as exc:
    raise newException(MqttProtocolError, exc.msg)

proc parseSubscribe(
    packet: MqttPacket, version: MqttVersion
): tuple[packetId: uint16, subscriptions: seq[MqttSubscriptionRequest]] =
  if packet.fixedHeader != 0x82:
    raise newException(MqttProtocolError, "malformed MQTT SUBSCRIBE flags")
  var cursor = PacketCursor(data: packet.body)
  result.packetId = cursor.readUint16()
  if result.packetId == 0:
    raise newException(MqttProtocolError, "MQTT packet identifier cannot be zero")
  if version == MqttVersion.V5:
    cursor.skipProperties()
  while cursor.position < cursor.data.len:
    let filter = cursor.readUtf8()
    requireTopicFilter(filter)
    let options = int(cursor.readByte())
    let requestedQos = options and 0x03
    if requestedQos == 3:
      raise newException(MqttProtocolError, "invalid MQTT subscription QoS")
    if version == MqttVersion.V5:
      if (options and 0xC0) != 0 or ((options shr 4) and 0x03) == 3:
        raise newException(MqttProtocolError, "invalid MQTT subscription options")
    elif (options and 0xFC) != 0:
      raise newException(MqttProtocolError, "invalid MQTT subscription options")
    result.subscriptions.add(
      MqttSubscriptionRequest(
        filter: filter,
        noLocal: version == MqttVersion.V5 and (options and 0x04) != 0,
        retainAsPublished: version == MqttVersion.V5 and (options and 0x08) != 0,
        retainHandling:
          if version == MqttVersion.V5:
            (options shr 4) and 0x03
          else:
            0,
      )
    )
  if result.subscriptions.len == 0:
    raise newException(MqttProtocolError, "MQTT SUBSCRIBE payload cannot be empty")

proc addRemainingLength(packet: var seq[byte], length: int) =
  try:
    packet.add(encodeRemainingLength(length))
  except ValueError:
    raiseAssert "validated MQTT packet exceeded the protocol packet limit"

proc subscribeAck(packetId: uint16, count: int, version: MqttVersion): seq[byte] =
  var body = @[byte(packetId shr 8), byte(packetId and 0xFF)]
  if version == MqttVersion.V5:
    body.add(0'u8)
  for _ in 0 ..< count:
    body.add(0'u8)
  result = @[0x90'u8]
  result.addRemainingLength(body.len)
  result.add(body)

proc parseUnsubscribe(
    packet: MqttPacket, version: MqttVersion
): tuple[packetId: uint16, filters: seq[string]] =
  if packet.fixedHeader != 0xA2:
    raise newException(MqttProtocolError, "malformed MQTT UNSUBSCRIBE flags")
  var cursor = PacketCursor(data: packet.body)
  result.packetId = cursor.readUint16()
  if result.packetId == 0:
    raise newException(MqttProtocolError, "MQTT packet identifier cannot be zero")
  if version == MqttVersion.V5:
    cursor.skipProperties()
  while cursor.position < cursor.data.len:
    let filter = cursor.readUtf8()
    requireTopicFilter(filter)
    result.filters.add(filter)
  if result.filters.len == 0:
    raise newException(MqttProtocolError, "MQTT UNSUBSCRIBE payload cannot be empty")

proc unsubscribeAck(
    packetId: uint16, removed: openArray[bool], version: MqttVersion
): seq[byte] =
  var body = @[byte(packetId shr 8), byte(packetId and 0xFF)]
  if version == MqttVersion.V5:
    body.add(0'u8)
    for existed in removed:
      body.add(if existed: 0x00'u8 else: 0x11'u8)
  result = @[0xB0'u8]
  result.addRemainingLength(body.len)
  result.add(body)

proc processPacket(
    app: Application,
    packet: MqttPacket,
    state: MqttConnectionState,
    runtime: MqttRuntime,
): Future[bool] {.async: (raises: [CancelledError, TransportError, MqttProtocolError]).} =
  let packetType = int(packet.fixedHeader shr 4)
  if state.peer.connection.isNil:
    state.peer.connection = parseConnect(packet, runtime.options)
    runtime.broker.add(state.peer)
    await state.peer.writePacket(connAck(state.peer.connection.version))
    return true

  case packetType
  of 3:
    let message = parsePublish(packet, state.peer.connection.version)
    var decision: MqttDecision
    try:
      decision = await app.handleMqtt(message, state.peer.connection)
    except CatchableError as exc:
      app.logError("Unhandled MQTT handler error: " & exc.msg)
      decision = mqttReject(MqttReasonCode.ImplementationSpecificError)
    if decision.kind == MqttDecisionKind.Accepted:
      runtime.broker.updateRetained(message)
      await runtime.broker.publishToSubscribers(state.peer, message)
    let acknowledgment = publishAck(message, state.peer.connection, decision)
    if acknowledgment.len > 0:
      await state.peer.writePacket(acknowledgment)
    result =
      decision.kind == MqttDecisionKind.Accepted or (
        state.peer.connection.version == MqttVersion.V5 and
        message.qos != MqttQoS.AtMostOnce
      )
  of 8:
    let parsed = parseSubscribe(packet, state.peer.connection.version)
    var newlyAdded: seq[bool]
    for subscription in parsed.subscriptions:
      newlyAdded.add(
        state.peer.subscribe(
          subscription.filter, subscription.noLocal, subscription.retainAsPublished
        )
      )
    await state.peer.writePacket(
      subscribeAck(
        parsed.packetId, parsed.subscriptions.len, state.peer.connection.version
      )
    )
    for index, subscription in parsed.subscriptions:
      if subscription.retainHandling == 0 or
          (subscription.retainHandling == 1 and newlyAdded[index]):
        await runtime.broker.sendRetained(state.peer, subscription.filter)
    result = true
  of 10:
    let parsed = parseUnsubscribe(packet, state.peer.connection.version)
    var removed: seq[bool]
    for filter in parsed.filters:
      removed.add(state.peer.unsubscribe(filter))
    await state.peer.writePacket(
      unsubscribeAck(parsed.packetId, removed, state.peer.connection.version)
    )
    result = true
  of 12:
    if packet.fixedHeader != 0xC0 or packet.body.len != 0:
      raise newException(MqttProtocolError, "malformed MQTT PINGREQ")
    await state.peer.writePacket(@[0xD0'u8, 0x00])
    result = true
  of 14:
    if packet.fixedHeader != 0xE0:
      raise newException(MqttProtocolError, "malformed MQTT DISCONNECT")
    result = false
  else:
    raise newException(MqttProtocolError, "unsupported MQTT control packet")

proc serveMqtt*(app: Application, address = "", port: uint16 = 0): MqttServer =
  ## Starts the installed MQTT plugin's Chronos TCP listener.
  app.load()
  let runtime = app.mqttRuntime()
  let selectedAddress = if address.len == 0: runtime.options.address else: address
  let selectedPort = if port == 0: runtime.options.port else: port
  let callback: StreamCallback2 = proc(
      server: StreamServer, client: StreamTransport
  ) {.async: (raises: []).} =
    discard server
    let state = MqttConnectionState(peer: newMqttPeer(client))
    try:
      var decoder = initMqttDecoder(runtime.options.maxPacketSize)
      var reading = true
      while reading:
        var chunk = newSeq[byte](8192)
        let count = await client.readOnce(addr chunk[0], chunk.len)
        if count == 0:
          break
        chunk.setLen(count)
        for packet in decoder.feed(chunk):
          reading = await processPacket(app, packet, state, runtime)
          if not reading:
            break
    except CancelledError:
      discard
    except CatchableError as exc:
      app.logError("MQTT connection closed: " & exc.msg)
    finally:
      runtime.broker.remove(state.peer)
      await client.closeWait()

  let stream =
    createStreamServer(initTAddress(selectedAddress, Port(selectedPort)), callback)
  stream.start()
  MqttServer(stream: stream)

proc stopMqtt*(app: Application, server: MqttServer) =
  ## Stops and closes an MQTT listener. Existing connections close independently.
  discard app
  if not server.stream.closed():
    server.stream.stop()
    server.stream.close()

proc join*(server: MqttServer): Future[void] {.async: (raises: [CancelledError]).} =
  ## Waits until the MQTT listener is closed.
  await server.stream.join()
