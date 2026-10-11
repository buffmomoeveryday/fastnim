## URL include/exclude patterns for the FastNim auth plugin.
##
## Patterns use the same segment rules as route paths: literal segments match
## themselves, ``{name}`` matches any single non-empty segment, and a ``*``
## segment matches the rest of the path (so ``/static/*`` covers a subtree).
## A lone ``*`` matches every path.

import std/strutils

proc splitPattern(pattern: string): seq[string] =
  for segment in pattern.split('/'):
    if segment.len > 0:
      result.add(segment)

proc matchPattern*(pattern, path: string): bool {.raises: [].} =
  ## Returns whether ``path`` matches ``pattern``.
  ##
  ## An empty pattern never matches; ``*`` matches everything. A ``*``
  ## segment matches the rest of the path, including nothing, so ``/static/*``
  ## also covers ``/static`` itself. Matching is case-sensitive, like routing.
  if pattern.len == 0:
    return false
  if pattern == "*":
    return true
  let patternParts = splitPattern(pattern)
  let pathParts = splitPattern(path)
  var index = 0
  for part in patternParts:
    if part == "*":
      return true
    if index >= pathParts.len:
      return false
    if part.len > 2 and part[0] == '{' and part[^1] == '}':
      if part[1 ..^ 2].len == 0:
        return false
    elif part != pathParts[index]:
      return false
    inc index
  index == pathParts.len

proc isProtected*(
    path: string,
    includePaths: openArray[string] = [],
    excludePaths: openArray[string] = [],
): bool {.raises: [].} =
  ## Returns whether ``path`` requires authentication.
  ##
  ## Exclusions always win: a path matching anything in ``excludePaths`` is
  ## public. An empty ``includePaths`` protects every path; otherwise a path
  ## must match at least one entry.
  for pattern in excludePaths:
    if matchPattern(pattern, path):
      return false
  if includePaths.len == 0:
    return true
  for pattern in includePaths:
    if matchPattern(pattern, path):
      return true
  false
