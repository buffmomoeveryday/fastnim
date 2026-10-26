import std/[os, osproc, strutils, unittest]

const
  repoRoot = currentSourcePath().parentDir().parentDir()
    ## Absolute path of the FastNim repository root.
  installScript = repoRoot / ".kilo" / "skills" / "fastnim" / "scripts" / "install.sh"
    ## Installer that copies the skill into a target project's ``.agents`` folder.

proc sandbox(name: string): string =
  ## Creates a fresh temporary directory for one test case.
  result = getTempDir() / "fastnim_tskillinstall" / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc runInstaller(target: string): tuple[code: int, output: string] =
  ## Runs the skill installer against ``target`` and returns its exit code and output.
  let (output, code) =
    execCmdEx("bash " & quoteShell(installScript) & " " & quoteShell(target))
  (code, output)

suite "skill installer":
  test "installs the skill and creates AGENTS.md in a fresh project":
    if findExe("bash") == "":
      skip()
    else:
      let target = sandbox("fresh")
      let (code, output) = runInstaller(target)
      check code == 0
      check "installed the FastNim skill" in output
      check fileExists(target / ".agents" / "skills" / "fastnim" / "SKILL.md")
      check fileExists(
        target / ".agents" / "skills" / "fastnim" / "references" / "routing.md"
      )
      check fileExists(target / "AGENTS.md")
      let agents = readFile(target / "AGENTS.md")
      check "skills/fastnim/SKILL.md" in agents
      check "Chronos" in agents

  test "does nothing when .agents already exists":
    if findExe("bash") == "":
      skip()
    else:
      let target = sandbox("existing-agents")
      createDir(target / ".agents")
      writeFile(target / ".agents" / "keep.txt", "untouched")
      writeFile(target / "AGENTS.md", "# Existing\n")
      let before = readFile(target / "AGENTS.md")
      let (code, output) = runInstaller(target)
      check code == 0
      check "nothing to do" in output
      check readFile(target / "AGENTS.md") == before
      check readFile(target / ".agents" / "keep.txt") == "untouched"
      check not dirExists(target / ".agents" / "skills")

  test "extends an existing AGENTS.md without dropping its content":
    if findExe("bash") == "":
      skip()
    else:
      let target = sandbox("existing-agents-md")
      writeFile(target / "AGENTS.md", "# Existing\n\nKeep me.\n")
      let (code, output) = runInstaller(target)
      check code == 0
      check fileExists(target / ".agents" / "skills" / "fastnim" / "SKILL.md")
      let agents = readFile(target / "AGENTS.md")
      check "Keep me." in agents
      check "skills/fastnim/SKILL.md" in agents

  test "is a no-op on a second run":
    if findExe("bash") == "":
      skip()
    else:
      let target = sandbox("idempotent")
      discard runInstaller(target)
      let before = readFile(target / "AGENTS.md")
      let (code, output) = runInstaller(target)
      check code == 0
      check "nothing to do" in output
      check readFile(target / "AGENTS.md") == before
