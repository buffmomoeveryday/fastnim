import std/[os, osproc, strutils, unittest]

let root = currentSourcePath().parentDir.parentDir
let dir = currentSourcePath().parentDir / "htmx" / "compile_errors"
let cacheDir = getTempDir() / "fastnim_htmx_compile_fail"

suite "htmx version compile errors":
  for path in walkFiles(dir / "*.nim"):
    let expected = readFile(path).splitLines()[0].replace("# expect:", "").strip
    test path.extractFilename:
      let (output, code) = execCmdEx(
        quoteShell(getCurrentCompilerExe()) &
          " check --hints:off --nimcache:" & quoteShell(cacheDir) &
          " --path:" & quoteShell(root / "src") & " " & quoteShell(path)
      )
      check code != 0
      check expected in output
      if expected notin output:
        echo output
