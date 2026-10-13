## MQTT topic-pattern validation and matching.

import std/[strutils, tables]

proc namedSegment(segment: string): tuple[name: string, tail: bool] =
  if segment.len < 3 or segment[0] != '{' or segment[^1] != '}':
    return
  result.name = segment[1..^2]
  if result.name.endsWith("..."):
    result.name.setLen(result.name.len - 3)
    result.tail = true

proc validateMqttPattern*(pattern: string) =
  ## Validates a FastNim MQTT route pattern.
  if pattern.len == 0:
    raise newException(ValueError, "MQTT route pattern cannot be empty")
  let segments = pattern.split('/')
  for index, segment in segments:
    let named = namedSegment(segment)
    if ('{' in segment or '}' in segment) and named.name.len == 0:
      raise newException(ValueError, "malformed named MQTT topic parameter")
    if named.name.len > 0:
      if '+' in named.name or '#' in named.name or '{' in named.name:
        raise newException(ValueError, "invalid named MQTT topic parameter")
      if named.tail and index != segments.high:
        raise newException(ValueError, "tail MQTT parameter must be last")
    elif segment == "#":
      if index != segments.high:
        raise newException(ValueError, "MQTT # wildcard must be last")
    elif ('#' in segment or '+' in segment) and segment != "+":
      raise newException(ValueError, "MQTT wildcards must occupy a whole segment")

proc validateMqttTopicFilter*(filter: string) =
  ## Validates a protocol-level MQTT subscription filter.
  if filter.len == 0:
    raise newException(ValueError, "MQTT topic filter cannot be empty")
  let segments = filter.split('/')
  for index, segment in segments:
    if segment == "#":
      if index != segments.high:
        raise newException(ValueError, "MQTT # wildcard must be last")
    elif ('#' in segment or '+' in segment) and segment != "+":
      raise newException(ValueError, "MQTT wildcards must occupy a whole level")

proc matchMqttTopic*(
    pattern, topic: string, params: var Table[string, string]
): bool =
  ## Matches one topic and fills named parameters when successful.
  let patternSegments = pattern.split('/')
  let topicSegments = topic.split('/')
  var topicIndex = 0
  for patternIndex, segment in patternSegments:
    let named = namedSegment(segment)
    if segment == "#" or named.tail:
      if named.tail:
        params[named.name] =
          if topicIndex < topicSegments.len:
            topicSegments[topicIndex..^1].join("/")
          else:
            ""
      return true
    if topicIndex >= topicSegments.len:
      return false
    if named.name.len > 0:
      params[named.name] = topicSegments[topicIndex]
    elif segment != "+" and segment != topicSegments[topicIndex]:
      return false
    inc topicIndex
    if patternIndex == patternSegments.high:
      return topicIndex == topicSegments.len
  topicIndex == topicSegments.len

proc matchMqttTopicFilter*(filter, topic: string): bool =
  ## Reports whether an MQTT subscription filter matches a topic name.
  ##
  ## A leading wildcard does not match the reserved ``$`` topic namespace.
  if topic.len > 0 and topic[0] == '$' and filter.len > 0 and
      filter[0] in {'+', '#'}:
    return false
  var params = initTable[string, string]()
  matchMqttTopic(filter, topic, params)
