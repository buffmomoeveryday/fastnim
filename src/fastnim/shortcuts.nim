## Django-style shortcut helpers for FastNim applications.
##
## Start here for small utilities that keep handlers and models readable.
## ``slugify`` mirrors ``django.utils.text.slugify``.

import std/[strutils, unicode]

proc foldLatinRune(r: Rune): string =
  ## Maps common Latin letters with diacritics to ASCII for ``allowUnicode = false``.
  case r.int32
  of 0x00C0 .. 0x00C5, 0x00E0 .. 0x00E5: "a"
  of 0x00C6, 0x00E6: "ae"
  of 0x00C7, 0x00E7: "c"
  of 0x00C8 .. 0x00CB, 0x00E8 .. 0x00EB: "e"
  of 0x00CC .. 0x00CF, 0x00EC .. 0x00EF: "i"
  of 0x00D0, 0x00F0: "d"
  of 0x00D1, 0x00F1: "n"
  of 0x00D2 .. 0x00D6, 0x00D8, 0x00F2 .. 0x00F6, 0x00F8: "o"
  of 0x00D9 .. 0x00DC, 0x00F9 .. 0x00FC: "u"
  of 0x00DD, 0x00FD, 0x00FF: "y"
  of 0x00DF: "ss"
  of 0x0100 .. 0x0105: "a"
  of 0x0106 .. 0x010D: "c"
  of 0x010E .. 0x0111: "d"
  of 0x0112 .. 0x011B: "e"
  of 0x011C .. 0x0123: "g"
  of 0x0124 .. 0x0127: "h"
  of 0x0128 .. 0x0131: "i"
  of 0x0134 .. 0x0135: "j"
  of 0x0136 .. 0x0138: "k"
  of 0x0139 .. 0x0142: "l"
  of 0x0143 .. 0x014B: "n"
  of 0x014C .. 0x0151: "o"
  of 0x0152, 0x0153: "oe"
  of 0x0154 .. 0x0159: "r"
  of 0x015A .. 0x0161: "s"
  of 0x0162 .. 0x0167: "t"
  of 0x0168 .. 0x0173: "u"
  of 0x0174 .. 0x0175: "w"
  of 0x0176 .. 0x0178: "y"
  of 0x0179 .. 0x017E: "z"
  of 0x1E9E: "ss"
  else: ""

proc slugify*(value: string, allowUnicode = false): string =
  ## Converts ``value`` into a URL slug, matching Django's ``slugify``.
  ##
  ## - Lowercases the text.
  ## - When ``allowUnicode`` is false (default), folds common Latin diacritics to
  ##   ASCII and drops other non-ASCII characters.
  ## - When ``allowUnicode`` is true, keeps Unicode letters and digits.
  ## - Removes characters that are not alphanumerics, underscores, hyphens, or
  ##   whitespace.
  ## - Collapses runs of whitespace and hyphens into a single hyphen.
  ## - Strips leading and trailing hyphens and underscores.
  ##
  ## Example::
  ##
  ##   slugify(" Joel is a slug ") == "joel-is-a-slug"
  ##   slugify("Café Menu") == "cafe-menu"
  ##   slugify("你好 World", allowUnicode = true) == "你好-world"
  var cleaned = newStringOfCap(value.len)
  for raw in value.runes:
    let r = raw.toLower
    let code = r.int32
    if code <= 0x7F:
      let c = char(code)
      if c.isAlphaNumeric or c == '_' or c == '-' or c in Whitespace:
        cleaned.add(c)
    elif allowUnicode:
      if r.isAlpha:
        cleaned.add($r)
    else:
      cleaned.add(foldLatinRune(r))

  var collapsed = newStringOfCap(cleaned.len)
  var pendingHyphen = false
  for c in cleaned:
    if c == '-' or c in Whitespace:
      pendingHyphen = true
    else:
      if pendingHyphen and collapsed.len > 0:
        collapsed.add('-')
      pendingHyphen = false
      collapsed.add(c)

  result = collapsed.strip(chars = {'-', '_'})
