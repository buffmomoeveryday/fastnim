## Each file in tests/compile_errors must fail to compile with the message
## given in its first line (`# expect: <substring>`).

import std/[unittest, os, osproc, strutils]

let root = currentSourcePath().parentDir.parentDir
let dir = currentSourcePath().parentDir / "orm" / "compile_errors"

suite "compile-time model errors":
  for path in walkFiles(dir / "*.nim"):
    let expected = readFile(path).splitLines()[0].replace("# expect:", "").strip
    test path.extractFilename:
      let (output, code) = execCmdEx(
        "nim check --hints:off --path:" & quoteShell(root / "src") & " " &
          quoteShell(path)
      )
      check code != 0
      check expected in output
      if expected notin output:
        echo output
