import std/[os, osproc, strutils, unittest]

let projectDir = currentSourcePath().parentDir.parentDir
let sourceDir = projectDir / "src"
let fixtureDir = projectDir / "tests" / "compile_fail"
let cacheDir = getTempDir() / "fastnim_grpc_compile_fail"

proc checkCompileFailure(fileName, expectedMessage: string) =
  let command =
    quoteShell(getCurrentCompilerExe()) &
      " check --hints:off --nimcache:" & quoteShell(cacheDir) & " --path:" &
      quoteShell(sourceDir) & " " & quoteShell(fixtureDir / fileName)
  let (output, exitCode) = execCmdEx(command)
  check exitCode != 0
  check expectedMessage in output

suite "gRPC protobuf compile-time validation":
  test "rejects a Nim request that differs from its protobuf message":
    checkCompileFailure(
      "tgrpc_schema_mismatch.nim",
      "has 2 fields, but protobuf message 'hello.HelloRequest' has 1",
    )
