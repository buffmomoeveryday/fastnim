import std/[os, osproc, strutils, unittest]

let projectDir = currentSourcePath().parentDir.parentDir
let sourceDir = projectDir / "src"
let fixtureDir = projectDir / "tests" / "compile_fail"
let cacheDir = getTempDir() / "fastnim_pathparams_compile_fail"

proc checkCompileFailure(fileName, expectedMessage: string) =
  let command =
    quoteShell(getCurrentCompilerExe()) & " check --hints:off --nimcache:" &
    quoteShell(cacheDir) & " --path:" & quoteShell(sourceDir) & " " &
    quoteShell(fixtureDir / fileName)
  let (output, exitCode) = execCmdEx(command)
  check exitCode != 0
  check expectedMessage in output

suite "typed path parameter compile-time validation":
  test "rejects the request identifier":
    checkCompileFailure(
      "tpathparam_request_collision.nim",
      "typed path parameter 'request' conflicts with framework-bound identifier 'request'",
    )

  test "rejects the context identifier with Nim-style matching":
    checkCompileFailure(
      "tpathparam_context_collision.nim",
      "typed path parameter 'c_tx' conflicts with framework-bound identifier 'ctx'",
    )

  test "rejects an active body alias":
    checkCompileFailure(
      "tpathparam_body_collision.nim",
      "typed path parameter 'body' conflicts with framework-bound identifier 'body'",
    )

  test "rejects an active query alias":
    checkCompileFailure(
      "tpathparam_query_collision.nim",
      "typed path parameter 'queryParams' conflicts with framework-bound identifier 'queryParams'",
    )

  test "rejects the SSE send identifier":
    checkCompileFailure(
      "tpathparam_send_collision.nim",
      "typed path parameter 'send' conflicts with framework-bound identifier 'send'",
    )

  test "rejects the WebSocket identifier":
    checkCompileFailure(
      "tpathparam_websocket_collision.nim",
      "typed path parameter 'websocket' conflicts with framework-bound identifier 'websocket'",
    )
