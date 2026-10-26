## Fixtures under tests/nplusone/ are compiled with `-d:raiseNPlusOne`.
## `bad_*.nim` files must fail to compile with the message in their
## `# expect: <substring>` first line (the N+1 pattern they contain is
## real). `good_*.nim` files must compile cleanly despite the flag (they
## eager-load correctly, so `checkNPlusOne` finds nothing to report).

import std/[unittest, os, osproc, strutils]

let root = currentSourcePath().parentDir.parentDir
let dir = currentSourcePath().parentDir / "orm" / "nplusone"

suite "N+1 detection (-d:raiseNPlusOne)":
  for path in walkFiles(dir / "*.nim"):
    let name = path.extractFilename
    test name:
      let (output, code) = execCmdEx(
        "nim check --hints:off -d:raiseNPlusOne --path:" & quoteShell(root / "src") & " " &
          quoteShell(path)
      )
      if name.startsWith("bad_"):
        let expected = readFile(path).splitLines()[0].replace("# expect:", "").strip
        check code != 0
        check expected in output
        if expected notin output:
          echo output
      else:
        check code == 0
        if code != 0:
          echo output
