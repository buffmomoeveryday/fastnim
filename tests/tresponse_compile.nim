import std/[os, osproc, strutils, unittest]

let projectDir = currentSourcePath().parentDir.parentDir
let sourceDir = projectDir / "src"
let fixtureDir = projectDir / "tests" / "compile_fail"
let cacheDir = getTempDir() / "fastnim_response_compile_fail"

proc checkCompileFailure(fileName, expectedMessage: string) =
  let command =
    quoteShell(getCurrentCompilerExe()) & " check --hints:off --nimcache:" &
    quoteShell(cacheDir) & " --path:" & quoteShell(sourceDir) & " " &
    quoteShell(fixtureDir / fileName)
  let (output, exitCode) = execCmdEx(command)
  check exitCode != 0
  check expectedMessage in output

suite "typed response compile-time validation":
  test "names the declared type and the returned type":
    checkCompileFailure(
      "tresponse_mismatch.nim",
      "response model does not match the type declared for status 201\nexpected: Author(id: int, name: string)\nreceived: Draft(id: int, name: int)",
    )
