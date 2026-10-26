import std/[os, osproc, strutils, unittest]

let projectDir = currentSourcePath().parentDir.parentDir
let sourceDir = projectDir / "src"
let fixtureDir = projectDir / "tests" / "compile_fail"

proc checkCompileFailure(fileName, expectedMessage: string) =
  let command =
    quoteShell(getCurrentCompilerExe()) & " check --hints:off --path:" &
    quoteShell(sourceDir) & " " & quoteShell(fixtureDir / fileName)
  let (output, exitCode) = execCmdEx(command)
  check exitCode != 0
  check expectedMessage in output

suite "dependency compile-time validation":
  test "rejects a missing provider":
    checkCompileFailure(
      "tdependency_missing_provider.nim", "missing provider for dependency 'db'"
    )

  test "rejects an unknown route dependency":
    checkCompileFailure(
      "tdependency_unknown_lookup.nim", "dependency 'cache' is not declared"
    )

  test "rejects a provider with the wrong type":
    checkCompileFailure("tdependency_wrong_provider.nim", "expected 'int'")
