## Command-line interface for FastNim project scaffolding.
##
## Build the binary with ``nimble build`` (``bin = @["fastnim"]``) and run
## ``fastnim init myapp --template:inertiajs``. This module is intentionally
## not re-exported from ``fastnim`` so CLI dependencies stay out of
## library builds.

import std/[os, strutils, terminal]

import cligen

import ./scaffolder/api
import ./scaffolder/inertiajs
import ./scaffolder/karax_csr
import ./scaffolder/karax_ssr

const
  NimblePkgVersion {.strdefine.} = "0.1.0"
  FastNimVersion* = NimblePkgVersion
    ## FastNim package version reported by the command-line interface.
  Templates* = ["api", "karax_ssr", "karax_csr", "inertiajs"]
    ## Project templates accepted by ``fastnim init``.
  Frontends* = ["svelte", "react"] ## Client frameworks accepted by ``--frontend``.
  DefaultTemplate = "api"
  CliUsage = """Usage:
  $command init [name] [options]
  $command --version
$doc
Options:
$options"""

proc cliVersion*(): string =
  ## Returns the version line printed by ``fastnim --version``.
  "fastnim " & FastNimVersion

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
  target, name, frontend, pkgManager, css: string, auth, force, interactive: bool
): int

proc runInit(
    name, dir, templateName, frontend, pkgManager, css: string,
    auth, force, interactive: bool,
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
    return runInertiaInit(
      target, name, frontend, pkgManager, css, auth, force, interactive
    )
  try:
    createDir(target)
    case templateName
    of "api":
      scaffoldApi(target, name, auth)
    of "karax_ssr":
      scaffoldKaraxSsr(target, name, auth)
    of "karax_csr":
      scaffoldKaraxCsr(target, name, auth)
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
    target, name, frontend, pkgManager, css: string,
    auth, force, interactive: bool,
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
    scaffoldInertiajs(target, name, choices, auth)
  except OSError as exc:
    stderr.writeLine("fastnim: error: cannot scaffold project: " & exc.msg)
    return 1
  except ValueError as exc:
    stderr.writeLine("fastnim: error: " & exc.msg)
    return 1

  let commands = pkgCommands(choices.pkgManager)
  echo "Created '" & target & "' (inertiajs + " & Frontends[choices.frontend.ord] & ")."
  echo "Next steps:"
  echo "  cd " & target
  echo "  nimble dev   # Vite + Nim server, rebuilt on changes"
  echo "  nimble run   # production: bundle client, build and run server"

  if interactive and terminal.isatty(stdin):
    if promptYesNo("Run '" & commands.install & "' now?"):
      let code = execShellCmd(
        "cd " & quoteShell(target) & " && " &
          quoteShell(commands.install.split(' ')[0]) & " install"
      )
      if code != 0:
        echo "Install failed (exit " & $code & "). Run '" & commands.install &
          "' manually inside " & target & "."
  0

var cliInteractive {.threadvar.}: bool

proc fastNimCommand(
    args: seq[string], `template` = DefaultTemplate, frontend = "",
    pkgManager = "", packageManager = "", css = "", dir = ".",
    auth = false, force = false,
): int =
  ## Creates a new FastNim project.
  if args.len == 0:
    stderr.writeLine("fastnim: error: missing command.")
    return 2
  if args[0] != "init":
    stderr.writeLine("fastnim: error: unknown command '" & args[0] & "'.")
    return 2
  if args.len > 2:
    stderr.writeLine("fastnim: error: too many arguments.")
    return 2
  if pkgManager.len > 0 and packageManager.len > 0:
    stderr.writeLine(
      "fastnim: error: use only one of --pkg-manager and --package-manager."
    )
    return 2
  if dir.len == 0:
    stderr.writeLine("fastnim: error: --dir needs a value.")
    return 2

  let name = if args.len == 2: args[1] else: "myapp"
  let selectedPkgManager =
    if pkgManager.len > 0: pkgManager
    else: packageManager
  runInit(
    name, dir, `template`.toLowerAscii(), frontend.toLowerAscii(),
    selectedPkgManager.toLowerAscii(), css.toLowerAscii(), auth, force,
    cliInteractive,
  )

proc initCliConfig(): ClCfg =
  result = clCfg
  result.version = cliVersion()
  result.longPfxOk = false
  result.stopPfxOk = false

let CliConfig = initCliConfig()

dispatchGen(
  fastNimCommand,
  cmdName = "fastnim",
  usage = CliUsage,
  cf = CliConfig,
  dispatchName = "dispatchFastNim",
  help = {
    "args": "the init command followed by an optional project name",
    "template": "project template: api, karax_ssr, karax_csr, or inertiajs",
    "frontend": "Inertia client framework: svelte or react",
    "pkg-manager": "Inertia package manager: pnpm, bun, npm, or deno",
    "package-manager": "alias for --pkg-manager",
    "css": "Inertia CSS setup: tailwind or none",
    "dir": "parent directory for the project",
    "auth": "add session auth (Inertia/SSR) or JWT auth (API/CSR)",
    "force": "scaffold into a non-empty directory",
    "version": "show the FastNim version",
    "helpsyntax": "CLIGEN-NOHELP",
  },
  short = {
    "template": '\0',
    "frontend": '\0',
    "pkgManager": '\0',
    "packageManager": '\0',
    "css": '\0',
    "dir": '\0',
    "auth": '\0',
    "force": '\0',
    "version": 'v',
  },
)

proc cliMain*(params: seq[string], interactive = true): int =
  ## Runs the Cligen-backed FastNim CLI and returns the process exit code.
  ##
  ## Pass ``interactive = false`` (as tests do) to never prompt or install:
  ## missing choices silently fall back to defaults.
  cliInteractive = interactive
  let effectiveParams = if params.len == 0: @["--help"] else: params
  try:
    result = dispatchFastNim(effectiveParams)
  except HelpOnly, VersionOnly:
    result = 0
  except ParseError:
    result = 2
