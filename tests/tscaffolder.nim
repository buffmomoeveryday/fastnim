import std/[json, os, strutils]

import fastnim/cli
import fastnim/scaffolder/api
import fastnim/scaffolder/inertiajs
import fastnim/scaffolder/karax_csr
import fastnim/scaffolder/karax_ssr

proc sandbox(name: string): string =
  result = getTempDir() / "fastnim_tscaffolder" / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc nimCheck(paths: openArray[string], file: string): string =
  ## Runs `nim check` on a generated file; returns "" on success.
  let repoSrc = currentSourcePath().parentDir().parentDir() / "src"
  var command = "nim check --hints:off --nimcache:" &
    quoteShell(paths[0] / ".nimcache") & " --path:" & quoteShell(repoSrc)
  for path in paths:
    command.add(" --path:" & quoteShell(path))
  let log = paths[0] / "nimcheck.log"
  let code =
    execShellCmd(command & " " & quoteShell(file) & " > " & quoteShell(log) & " 2>&1")
  if code == 0:
    ""
  else:
    readFile(log)

proc scaffoldCombo(
    box, name: string, frontend: InertiaFrontend, pkgManager: string, css: InertiaCss
): string =
  result = box / name
  scaffoldInertiajs(
    result, name, InertiaChoices(frontend: frontend, pkgManager: pkgManager, css: css)
  )

proc expectedFiles(box, name, entry: string): seq[string] =
  let root = box / name
  @[
    root / name & ".nimble",
    root / "config.nims",
    root / ".gitignore",
    root / "tools" / "dev.nim",
    root / "src" / "main.nim",
    root / "src" / "routes" / "pages.nim",
    root / "package.json",
    root / "vite.config.ts",
    root / "tsconfig.json",
    root / "client" / entry,
    root / "client" / "src" / "app.css",
    root / "README.md",
  ]

block pkgManagerCommands:
  doAssert pkgCommands("pnpm") ==
    (install: "pnpm install", dev: "pnpm dev", build: "pnpm build")
  doAssert pkgCommands("bun").install == "bun install"
  doAssert pkgCommands("npm").dev == "npm run dev"
  doAssert pkgCommands("deno").build == "deno task build"
  var raised = false
  try:
    discard pkgCommands("yarn")
  except ValueError:
    raised = true
  doAssert raised

block scaffoldSvelteTailwind:
  let box = sandbox("svelte-tw")
  let root = scaffoldCombo(box, "shop", feSvelte, "pnpm", cssTailwind)
  for path in expectedFiles(box, "shop", "src/main.ts"):
    doAssert fileExists(path), path
  doAssert fileExists(root / "client" / "src" / "pages" / "Dashboard.svelte")
  doAssert fileExists(root / "client" / "src" / "pages" / "Users.svelte")
  for stale in ["package.json", "vite.config.ts", "tsconfig.json", "index.html"]:
    doAssert not fileExists(root / "client" / stale), stale

  let manifest = parseJson(readFile(root / "package.json"))
  doAssert manifest["name"].getStr() == "shop"
  doAssert "svelte" in manifest["dependencies"]
  doAssert "@inertiajs/svelte" in manifest["dependencies"]
  doAssert "tailwindcss" in manifest["devDependencies"]
  doAssert "@tailwindcss/vite" in manifest["devDependencies"]
  doAssert manifest["packageManager"].getStr() == "pnpm@10.0.0"

  let main = readFile(root / "src" / "main.nim")
  doAssert "initFastNim" in main
  doAssert "inertiaPlugin" in main
  doAssert "INERTIA_DEV" in main
  doAssert "serveStatic" in main
  doAssert "http://localhost:5173/assets/client/src/main.ts" in main
  doAssert "http://localhost:5173/assets/@vite/client" in main
  doAssert "@react-refresh" notin main
  doAssert "nimble dev" in main

  let pages = readFile(root / "src" / "routes" / "pages.nim")
  doAssert "pageRouter" in pages
  doAssert "inertia(\"Dashboard\"" in pages
  doAssert "inertia(\"Users\"" in pages

  let nimble = readFile(root / "shop.nimble")
  doAssert "bin = @[\"main\"]" in nimble
  doAssert "before build:" in nimble
  doAssert "exec \"pnpm install\"" in nimble
  doAssert "exec \"pnpm build\"" in nimble
  doAssert "task dev," in nimble
  doAssert "tools/dev.nim" in nimble

  let runner = readFile(root / "tools" / "dev.nim")
  doAssert "InstallCommand = \"pnpm install\"" in runner
  doAssert "ViteCommand = \"pnpm dev\"" in runner
  doAssert "INERTIA_DEV" in runner
  doAssert nimCheck([root / "tools"], root / "tools" / "dev.nim") == ""

  let ignored = readFile(root / ".gitignore")
  doAssert "node_modules/" in ignored
  doAssert "client/dist/" in ignored

  let tsconfig = parseJson(readFile(root / "tsconfig.json"))
  doAssert tsconfig["include"][0].getStr() == "client/src"

  let vite = readFile(root / "vite.config.ts")
  doAssert "client/src/main.ts" in vite
  doAssert "outDir: \"client/dist\"" in vite
  doAssert "strictPort" in vite
  doAssert "origin: \"http://localhost:5173\"" in vite
  doAssert "@sveltejs/vite-plugin-svelte" in vite
  doAssert "tailwindcss" in vite

  let entry = readFile(root / "client" / "src" / "main.ts")
  doAssert "createInertiaApp" in entry
  doAssert "mount(App" in entry

  doAssert "@import \"tailwindcss\";" in readFile(root / "client" / "src" / "app.css")
  let dashboard = readFile(root / "client" / "src" / "pages" / "Dashboard.svelte")
  doAssert "$props()" in dashboard
  doAssert "@inertiajs/svelte" in dashboard
  doAssert "bg-slate-50" in dashboard

block scaffoldReactPlain:
  let box = sandbox("react-plain")
  let root = scaffoldCombo(box, "blog", feReact, "npm", cssNone)
  for path in expectedFiles(box, "blog", "src/main.tsx"):
    doAssert fileExists(path), path
  doAssert fileExists(root / "client" / "src" / "pages" / "Dashboard.tsx")
  doAssert fileExists(root / "client" / "src" / "pages" / "Users.tsx")

  let manifest = parseJson(readFile(root / "package.json"))
  doAssert "react" in manifest["dependencies"]
  doAssert "react-dom" in manifest["dependencies"]
  doAssert "@inertiajs/react" in manifest["dependencies"]
  doAssert "tailwindcss" notin manifest["devDependencies"]
  doAssert manifest["packageManager"].getStr() == "npm@11.0.0"

  let main = readFile(root / "src" / "main.nim")
  doAssert "http://localhost:5173/assets/client/src/main.tsx" in main
  doAssert "http://localhost:5173/assets/@vite/client" in main
  doAssert "http://localhost:5173/assets/@react-refresh" in main

  let nimble = readFile(root / "blog.nimble")
  doAssert "exec \"npm install\"" in nimble
  doAssert "exec \"npm run build\"" in nimble
  doAssert "ViteCommand = \"npm run dev\"" in readFile(root / "tools" / "dev.nim")

  let vite = readFile(root / "vite.config.ts")
  doAssert "client/src/main.tsx" in vite
  doAssert "@vitejs/plugin-react" in vite
  doAssert "tailwindcss" notin vite

  let tsconfig = parseJson(readFile(root / "tsconfig.json"))
  doAssert tsconfig["compilerOptions"]["jsx"].getStr() == "react-jsx"

  let entry = readFile(root / "client" / "src" / "main.tsx")
  doAssert "createRoot" in entry
  doAssert "@inertiajs/react" in entry

  let css = readFile(root / "client" / "src" / "app.css")
  doAssert "tailwindcss" notin css
  doAssert "system-ui" in css

block scaffoldBunAndDenoManagers:
  let box = sandbox("managers")
  let bunRoot = scaffoldCombo(box, "bunapp", feSvelte, "bun", cssNone)
  let bunManifest = parseJson(readFile(bunRoot / "package.json"))
  doAssert "packageManager" notin bunManifest
  doAssert "bun run dev" in readFile(bunRoot / "README.md")

  let denoRoot = scaffoldCombo(box, "denoapp", feReact, "deno", cssNone)
  let denoManifest = parseJson(readFile(denoRoot / "package.json"))
  doAssert "packageManager" notin denoManifest
  doAssert "deno task dev" in readFile(denoRoot / "README.md")

block rejectsUnknownPkgManager:
  let box = sandbox("badmgr")
  var raised = false
  try:
    discard scaffoldCombo(box, "nope", feSvelte, "yarn", cssNone)
  except ValueError:
    raised = true
  doAssert raised

block generatedServerCompiles:
  let repoSrc = currentSourcePath().parentDir().parentDir() / "src"
  for (box, name) in [("svelte-tw", "shop"), ("react-plain", "blog")]:
    let genSrc = getTempDir() / "fastnim_tscaffolder" / box / name / "src"
    let log = genSrc / "nimcheck.log"
    let code = execShellCmd(
      "nim check --hints:off --nimcache:" & quoteShell(genSrc / ".nimcache") &
        " --path:" & quoteShell(repoSrc) & " --path:" &
        quoteShell(genSrc) & " " & quoteShell(genSrc / "main.nim") & " > " &
        quoteShell(log) & " 2>&1"
    )
    doAssert code == 0, readFile(log)

block cliInitScaffoldsProject:
  let box = sandbox("cli")
  let code = cliMain(
    @[
      "init",
      "demo",
      "--template:inertiajs",
      "--frontend:react",
      "--css:none",
      "--pkgmanager:npm",
      "--dir:" & box,
    ],
    interactive = false,
  )
  doAssert code == 0
  doAssert fileExists(box / "demo" / "src" / "main.nim")
  doAssert fileExists(box / "demo" / "client" / "src" / "main.tsx")
  let manifest = parseJson(readFile(box / "demo" / "package.json"))
  doAssert "@inertiajs/react" in manifest["dependencies"]

block cliUsesSensibleDefaults:
  let box = sandbox("cli-defaults")
  let code = cliMain(
    @["init", "plain", "--template=inertiajs", "--dir=" & box], interactive = false
  )
  doAssert code == 0
  let manifest = parseJson(readFile(box / "plain" / "package.json"))
  doAssert "@inertiajs/svelte" in manifest["dependencies"]
  doAssert "tailwindcss" in manifest["devDependencies"]
  doAssert manifest["packageManager"].getStr() == "pnpm@10.0.0"

block cliAcceptsSpaceSeparatedValues:
  let box = sandbox("cli-space")
  let code = cliMain(
    @["init", "spaced", "--template", "inertiajs", "--frontend", "svelte", "--dir", box],
    interactive = false,
  )
  doAssert code == 0
  doAssert fileExists(box / "spaced" / "src" / "main.nim")

block cliReportsVersion:
  doAssert FastNimVersion.len > 0
  doAssert cliVersion() == "fastnim " & FastNimVersion
  doAssert cliMain(@["--version"], interactive = false) == 0
  doAssert cliMain(@["-v"], interactive = false) == 0

block cliRejectsBadInput:
  let box = sandbox("cli-bad")
  doAssert cliMain(
    @["init", "x", "--template:nope", "--dir=" & box], interactive = false
  ) == 2
  doAssert cliMain(
    @["init", "x", "--template:inertiajs", "--frontend:vue", "--dir=" & box],
    interactive = false,
  ) == 2
  doAssert cliMain(
    @["init", "x", "--template:inertiajs", "--pkgmanager:yarn", "--dir=" & box],
    interactive = false,
  ) == 2
  doAssert cliMain(
    @["init", "x", "--template:inertiajs", "--css:bootstrap", "--dir=" & box],
    interactive = false,
  ) == 2
  doAssert cliMain(
    @["init", "a/b", "--template:inertiajs", "--dir=" & box], interactive = false
  ) == 2
  doAssert cliMain(@["bogus"], interactive = false) == 2
  doAssert cliMain(@["migrate"], interactive = false) == 1
  doAssert cliMain(@["--help"], interactive = false) == 0
  doAssert cliMain(@[], interactive = false) == 0

block cliRefusesNonEmptyDir:
  let box = sandbox("cli-force")
  createDir(box / "myapp")
  writeFile(box / "myapp" / "taken.txt", "occupied")
  doAssert cliMain(
    @["init", "--template:inertiajs", "--dir=" & box], interactive = false
  ) == 1
  doAssert cliMain(
    @["init", "--template:inertiajs", "--dir=" & box, "--force"], interactive = false
  ) == 0
  doAssert fileExists(box / "myapp" / "src" / "main.nim")

block scaffoldApiProject:
  let box = sandbox("api")
  let root = box / "shop"
  scaffoldApi(root, "shop")
  for path in [
    root / "shop.nimble",
    root / "config.nims",
    root / "src" / "shop.nim",
    root / "src" / "settings.nim",
    root / "src" / "manage.nim",
    root / "src" / "migrations" / "all.nim",
    root / "src" / "models" / "author.nim",
    root / "src" / "models" / "index.nim",
    root / "src" / "routers" / "authors.nim",
    root / "src" / "services" / "authors_service.nim",
    root / "tests" / "test_app.nim",
    root / "README.md",
  ]:
    doAssert fileExists(path), path

  let routes = readFile(root / "src" / "routers" / "authors.nim")
  doAssert "let authorRouter*" in routes
  doAssert "responses = @[(201, Author)]" in routes
  doAssert "createAuthor" in routes
  doAssert "requires \"fastnim" in readFile(root / "shop.nimble")
  let nimbleFile = readFile(root / "shop.nimble")
  doAssert "task bootstrap," in nimbleFile
  doAssert "Generate and apply migrations" in nimbleFile
  doAssert "task makemigrations," in nimbleFile
  doAssert "exec \"fastnim makemigrations\"" in nimbleFile
  doAssert "task migrate," in nimbleFile
  doAssert "exec \"fastnim migrate\"" in nimbleFile
  doAssert "databasePath" in readFile(root / "src" / "settings.nim")
  doAssert "runCli" in readFile(root / "src" / "manage.nim")
  doAssert "nimble bootstrap" in readFile(root / "README.md")
  doAssert "nimble migrate" in readFile(root / "README.md")
  doAssert ".migrate(" notin readFile(root / "src" / "shop.nim")

  let src = root / "src"
  doAssert nimCheck([src], src / "shop.nim") == ""
  doAssert nimCheck([src], src / "manage.nim") == ""
  doAssert nimCheck([src], root / "tests" / "test_app.nim") == ""

block scaffoldKaraxSsrProject:
  let box = sandbox("ssr")
  let root = box / "pages"
  scaffoldKaraxSsr(root, "pages")
  for path in [
    root / "pages.nimble",
    root / "src" / "pages.nim",
    root / "src" / "settings.nim",
    root / "src" / "manage.nim",
    root / "src" / "routers" / "pages.nim",
    root / "src" / "templates" / "base.nim",
    root / "src" / "templates" / "authors.nim",
    root / "tests" / "test_app.nim",
    root / "README.md",
  ]:
    doAssert fileExists(path), path

  let pages = readFile(root / "src" / "routers" / "pages.nim")
  doAssert "request.isHtmx" in pages
  doAssert "html layout" in pages
  doAssert "hx-post" in readFile(root / "src" / "templates" / "authors.nim")
  doAssert "htmx.org@2" in readFile(root / "src" / "templates" / "base.nim")
  doAssert "htmxPlugin" in readFile(root / "src" / "pages.nim")
  doAssert ".migrate(" notin readFile(root / "src" / "pages.nim")

  let src = root / "src"
  doAssert nimCheck([src], src / "pages.nim") == ""
  doAssert nimCheck([src], src / "manage.nim") == ""
  doAssert nimCheck([src], root / "tests" / "test_app.nim") == ""

block scaffoldKaraxCsrProject:
  let box = sandbox("csr")
  let root = box / "app"
  scaffoldKaraxCsr(root, "app")
  for path in [
    root / "app.nimble",
    root / "src" / "main.nim",
    root / "src" / "routes" / "api.nim",
    root / "client" / "app.nim",
    root / "public" / "index.html",
    root / "tests" / "test_api.nim",
    root / "README.md",
  ]:
    doAssert fileExists(path), path

  doAssert "serveStatic" in readFile(root / "src" / "main.nim")
  doAssert "setRenderer render" in readFile(root / "client" / "app.nim")
  doAssert "task client" in readFile(root / "app.nimble")

  let src = root / "src"
  doAssert nimCheck([src], src / "main.nim") == ""
  doAssert nimCheck([src], root / "tests" / "test_api.nim") == ""

  let jsLog = root / "client" / "app.js.log"
  let jsCode = execShellCmd(
    "nim js --hints:off --nimcache:" & quoteShell(root / ".nimcache-js") & " -o:" &
      quoteShell(root / "public" / "assets" / "app.js") & " " &
      quoteShell(root / "client" / "app.nim") & " > " & quoteShell(jsLog) & " 2>&1"
  )
  doAssert jsCode == 0, readFile(jsLog)

block cliScaffoldsEveryTemplate:
  let box = sandbox("cli-all")
  doAssert cliMain(@["init", "shop", "--dir=" & box], interactive = false) == 0
  doAssert fileExists(box / "shop" / "src" / "routers" / "authors.nim")
  doAssert cliMain(
    @["init", "ssr", "--template:ssr", "--dir=" & box], interactive = false
  ) == 0
  doAssert fileExists(box / "ssr" / "src" / "routers" / "pages.nim")
  doAssert cliMain(
    @["init", "csr", "--template:karax_csr", "--dir=" & box], interactive = false
  ) == 0
  doAssert fileExists(box / "csr" / "client" / "app.nim")
  doAssert cliMain(
    @["init", "old", "--template:api", "--frontend:svelte", "--dir=" & box],
    interactive = false,
  ) == 0
  doAssert fileExists(box / "old" / "src" / "old.nim")

block cliScaffoldsAuthForEveryTemplate:
  let box = sandbox("cli-auth")
  for (name, templateName, scheme) in [
    ("apiapp", "api", "AuthScheme.Jwt"),
    ("ssrapp", "ssr", "AuthScheme.Session"),
    ("csrapp", "karax_csr", "AuthScheme.Jwt"),
    ("inertiaapp", "inertiajs", "AuthScheme.Session"),
  ]:
    let code = cliMain(
      @["init", name, "--template:" & templateName, "--auth", "--dir=" & box],
      interactive = false,
    )
    doAssert code == 0
    let root = box / name
    let src = root / "src"
    doAssert fileExists(src / "auth.nim")
    let structured = templateName in ["api", "ssr"]
    doAssert fileExists(
      src / (if structured: "routers" else: "routes") / "auth.nim"
    )
    doAssert scheme in readFile(src / "auth.nim")
    let mainFile = src / (if structured: name & ".nim" else: "main.nim")
    doAssert "authentication()" in readFile(mainFile)
    doAssert nimCheck([src], mainFile) == ""

  doAssert fileExists(box / "inertiaapp" / "client" / "src" / "pages" / "Login.svelte")
  doAssert "JWT_SECRET" in readFile(box / "apiapp" / "README.md")
  doAssert "localstorage" in readFile(box / "csrapp" / "client" / "app.nim")

  let csrRoot = box / "csrapp"
  let jsLog = csrRoot / "client" / "auth_app.js.log"
  let jsCode = execShellCmd(
    "nim js --hints:off --nimcache:" & quoteShell(csrRoot / ".nimcache-js") & " -o:" &
      quoteShell(csrRoot / "public" / "assets" / "app.js") & " " &
      quoteShell(csrRoot / "client" / "app.nim") & " > " & quoteShell(jsLog) & " 2>&1"
  )
  doAssert jsCode == 0, readFile(jsLog)

block scaffoldInertiaAuthHandlesFailedLogins:
  # Failed Inertia logins must re-render the Login page with errors; plain
  # JSON responses trigger the client's "must receive a valid Inertia
  # response" error modal.
  let box = sandbox("inertia-auth")
  for (name, frontend) in [("svelteapp", feSvelte), ("reactapp", feReact)]:
    let root = box / name
    scaffoldInertiajs(
      root,
      name,
      InertiaChoices(frontend: frontend, pkgManager: "pnpm", css: cssTailwind),
      auth = true,
    )
    let routes = readFile(root / "src" / "routes" / "auth.nim")
    doAssert "isInertiaRequest" in routes
    doAssert "inertia(\"Login\", %*{\"errors\"" in routes
    doAssert "json(statusUnauthorized" in routes
  let svelteLogin =
    readFile(box / "svelteapp" / "client" / "src" / "pages" / "Login.svelte")
  doAssert "errors" in svelteLogin
  doAssert "Invalid credentials" notin svelteLogin
  let reactLogin = readFile(box / "reactapp" / "client" / "src" / "pages" / "Login.tsx")
  doAssert "errors" in reactLogin
  doAssert "Invalid credentials" notin reactLogin

block authFlagIsOptIn:
  let box = sandbox("auth-opt-in")
  doAssert cliMain(@["init", "plain", "--dir=" & box], interactive = false) == 0
  doAssert not fileExists(box / "plain" / "src" / "auth.nim")
