## Command-line interface for FastNim project scaffolding.
##
## Build the binary with ``nimble build`` (``bin = @["fastnim"]``) and run
## ``fastnim init myapp --template:inertiajs``. This module is intentionally
## not re-exported from ``fastnim`` so CLI dependencies stay out of
## library builds.

import std/[os, parseopt, strutils, terminal]

import ./scaffolder/api
import ./scaffolder/inertiajs
import ./scaffolder/karax_csr
import ./scaffolder/karax_ssr

const
  Templates* = ["api", "karax_ssr", "karax_csr", "inertiajs"]
    ## Project templates accepted by ``fastnim init``.
  Frontends* = ["svelte", "react"] ## Client frameworks accepted by ``--frontend``.
  DefaultTemplate = "api"

proc usage(): string =
  """Usage: fastnim init [name] [options]

Creates a new FastNim project.

Options:
  --template:NAME     api (default), karax_ssr, karax_csr, inertiajs
  --frontend:NAME     inertiajs only: svelte (default), react
  --pkgmanager:NAME   inertiajs only: pnpm (default), bun, npm, deno
  --css:NAME          inertiajs only: tailwind (default), none
  --dir:PATH          parent directory for the project (default: .)
  --force             scaffold into a non-empty directory
  -h, --help          show this help"""

proc promptChoice(label: string, options: openArray[string], defaultIx: int): string =
  ## Asks a numbered-menu question on a TTY. Empty input takes the default.
  echo label
  for i, opt in options:
    let marker = if i == defaultIx: " (default)" else: ""
    echo "  " & $(i + 1) & ") " & opt & marker
  while true:
    stdout.write("Select [1-" & $options.len & "]: ")
    let line =
      try:
        stdin.readLine().strip()
      except EOFError, IOError:
        return options[defaultIx]
    if line.len == 0:
      return options[defaultIx]
    try:
      let ix = parseInt(line) - 1
      if ix >= 0 and ix < options.len:
        return options[ix]
    except ValueError:
      discard
    echo "Please enter a number between 1 and " & $options.len & "."

proc promptYesNo(question: string): bool =
  ## Asks a yes/no question on a TTY, defaulting to no.
  stdout.write(question & " [y/N]: ")
  try:
    stdin.readLine().strip().toLowerAscii() in ["y", "yes"]
  except EOFError, IOError:
    false

proc validProjectName(name: string): bool =
  ## Rejects empty names and anything that escapes the target directory.
  name.len > 0 and '/' notin name and '\\' notin name and ' ' notin name and name != "." and
    name != ".." and not name.startsWith("-")

proc dirIsEmpty(dir: string): bool =
  for _ in walkDir(dir):
    return false
  true

proc runInertiaInit(
  target, name, frontend, pkgManager, css: string, force, interactive: bool
): int

proc runInit(
    name, dir, templateName, frontend, pkgManager, css: string, force, interactive: bool
): int =
  if templateName notin Templates:
    stderr.writeLine(
      "fastnim: error: unknown template '" & templateName & "'. Choose from: " &
        Templates.join(", ")
    )
    return 2
  if not validProjectName(name):
    stderr.writeLine("fastnim: error: invalid project name '" & name & "'.")
    return 2
  if templateName != "inertiajs" and (frontend.len + pkgManager.len + css.len > 0):
    stderr.writeLine(
      "fastnim: warning: --frontend/--pkgmanager/--css only apply to " &
        "--template:inertiajs; ignoring them."
    )
  let target = dir / name
  if dirExists(target) and not dirIsEmpty(target) and not force:
    stderr.writeLine(
      "fastnim: error: '" & target & "' is not empty. Use --force to overwrite."
    )
    return 1
  if templateName == "inertiajs":
    return runInertiaInit(target, name, frontend, pkgManager, css, force, interactive)
  try:
    createDir(target)
    case templateName
    of "api":
      scaffoldApi(target, name)
    of "karax_ssr":
      scaffoldKaraxSsr(target, name)
    of "karax_csr":
      scaffoldKaraxCsr(target, name)
    else:
      discard
  except OSError as exc:
    stderr.writeLine("fastnim: error: cannot scaffold project: " & exc.msg)
    return 1
  except ValueError as exc:
    stderr.writeLine("fastnim: error: " & exc.msg)
    return 1
  echo "Created '" & target & "' (" & templateName & ")."
  echo "See " & target / "README.md" & " for how to run it."
  0

proc runInertiaInit(
    target, name, frontend, pkgManager, css: string, force, interactive: bool
): int =
  ## Resolves Inertia choices, scaffolds, and prints next steps.
  var choices = InertiaChoices(pkgManager: pkgManager, css: cssTailwind)
  if frontend.len == 0:
    if interactive and terminal.isatty(stdin):
      choices.frontend =
        if promptChoice("Client framework:", Frontends, Frontends.find("svelte")) ==
            "react": feReact else: feSvelte
    else:
      choices.frontend = feSvelte
  elif frontend == "svelte":
    choices.frontend = feSvelte
  elif frontend == "react":
    choices.frontend = feReact
  else:
    stderr.writeLine(
      "fastnim: error: unknown frontend '" & frontend & "'. Choose from: " &
        Frontends.join(", ")
    )
    return 2
  if pkgManager.len == 0:
    if interactive and terminal.isatty(stdin):
      choices.pkgManager = promptChoice(
        "Package manager:", PkgManagers, PkgManagers.find(DefaultPkgManager)
      )
    else:
      choices.pkgManager = DefaultPkgManager
  elif pkgManager notin PkgManagers:
    stderr.writeLine(
      "fastnim: error: unknown package manager '" & pkgManager & "'. Choose from: " &
        PkgManagers.join(", ")
    )
    return 2
  else:
    choices.pkgManager = pkgManager
  if css.len == 0:
    if interactive and terminal.isatty(stdin):
      choices.css =
        if promptChoice("CSS setup:", CssOptions, CssOptions.find("tailwind")) == "none":
          cssNone
        else:
          cssTailwind
    else:
      choices.css = cssTailwind
  elif css == "tailwind":
    choices.css = cssTailwind
  elif css == "none":
    choices.css = cssNone
  else:
    stderr.writeLine(
      "fastnim: error: unknown css option '" & css & "'. Choose from: " &
        CssOptions.join(", ")
    )
    return 2

  try:
    createDir(target)
    scaffoldInertiajs(target, name, choices)
  except OSError as exc:
    stderr.writeLine("fastnim: error: cannot scaffold project: " & exc.msg)
    return 1
  except ValueError as exc:
    stderr.writeLine("fastnim: error: " & exc.msg)
    return 1

  let commands = pkgCommands(choices.pkgManager)
  echo "Created '" & target & "' (inertiajs + " & Frontends[choices.frontend.ord] & ")."
  echo "Next steps:"
  echo "  cd " & target / "client"
  echo "  " & commands.install
  echo "  " & commands.dev & "      # Vite dev server in one terminal"
  echo "  INERTIA_DEV=1 nim c -r --path:src src/main.nim   # Nim server in another"

  if interactive and terminal.isatty(stdin):
    if promptYesNo("Run '" & commands.install & "' now?"):
      let code = execShellCmd(
        "cd " & quoteShell(target / "client") & " && " &
          quoteShell(commands.install.split(' ')[0]) & " install"
      )
      if code != 0:
        echo "Install failed (exit " & $code & "). Run '" & commands.install &
          "' manually inside " & target / "client" & "."
  0

proc normalizeParams(params: seq[string]): seq[string] =
  ## Joins space-separated option values (``--dir PATH``) into the
  ## ``--dir:PATH`` form parseopt understands.
  const ValOpts = [
    "--template", "--frontend", "--pkgmanager", "--pkg-manager", "--package-manager",
    "--css", "--dir",
  ]
  var i = 0
  while i < params.len:
    let arg = params[i]
    if arg.toLowerAscii() in ValOpts and i + 1 < params.len and params[i + 1].len > 0 and
        not params[i + 1].startsWith("-"):
      result.add(arg & ":" & params[i + 1])
      i += 2
    else:
      result.add(arg)
      i += 1

proc cliMain*(params: seq[string], interactive = true): int =
  ## Runs the FastNim CLI. Returns the process exit code.
  ##
  ## Pass ``interactive = false`` (as tests do) to never prompt or install:
  ## missing choices silently fall back to defaults.
  var parser = initOptParser(normalizeParams(params))
  var positional: seq[string] = @[]
  var dir = "."
  var templateName = DefaultTemplate
  var frontend = ""
  var pkgManager = ""
  var css = ""
  var force = false
  for kind, key, val in parser.getopt():
    case kind
    of cmdArgument:
      positional.add(key)
    of cmdLongOption, cmdShortOption:
      case key.toLowerAscii()
      of "h", "help":
        echo usage()
        return 0
      of "template":
        templateName = val.toLowerAscii()
      of "frontend":
        frontend = val.toLowerAscii()
      of "pkgmanager", "pkg-manager", "package-manager":
        pkgManager = val.toLowerAscii()
      of "css":
        css = val.toLowerAscii()
      of "dir":
        dir = val
      of "force":
        force = true
      else:
        stderr.writeLine("fastnim: error: unknown option '--" & key & "'.")
        stderr.writeLine(usage())
        return 2
    of cmdEnd:
      discard

  if positional.len == 0:
    echo usage()
    return 0
  if positional[0] != "init":
    stderr.writeLine("fastnim: error: unknown command '" & positional[0] & "'.")
    stderr.writeLine(usage())
    return 2
  if positional.len > 2:
    stderr.writeLine("fastnim: error: too many arguments.")
    stderr.writeLine(usage())
    return 2
  let name =
    if positional.len == 2:
      positional[1]
    else:
      "myapp"
  if dir.len == 0:
    stderr.writeLine("fastnim: error: --dir needs a value.")
    stderr.writeLine(usage())
    return 2
  runInit(name, dir, templateName, frontend, pkgManager, css, force, interactive)
