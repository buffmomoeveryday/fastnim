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

suite "jsonName compile-time validation":
  test "rejects an empty field name":
    checkCompileFailure("tjsonname_empty.nim", "jsonName cannot be empty")

  test "rejects duplicate effective field names":
    checkCompileFailure(
      "tjsonname_duplicate.nim", "duplicate JSON field name 'name'"
    )
