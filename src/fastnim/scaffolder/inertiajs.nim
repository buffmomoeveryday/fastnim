## Inertia.js project scaffolding for ``fastnim init``.
##
## Generates a Nim server (FastNim + ``inertiaPlugin``) and a Vite client
## (Svelte or React, Tailwind v4 or plain CSS). The client is TypeScript;
## its tooling config and ``node_modules`` sit in the project root while
## sources live in ``client/src``. Production builds use fixed
## ``app.js``/``app.css`` filenames so the server needs no manifest parsing.

import std/[os, strutils]

import ./auth

type
  InertiaFrontend* = enum ## Client framework for the generated project.
    feSvelte
    feReact

  InertiaCss* = enum ## Styling setup for the generated client.
    cssTailwind
    cssNone

  InertiaChoices* = object ## Answers to the interactive init questions.
    frontend*: InertiaFrontend ## Svelte or React client.
    pkgManager*: string ## pnpm, bun, npm, or deno (validated by the CLI).
    css*: InertiaCss ## Tailwind v4 or plain CSS.

const
  PkgManagers* = ["pnpm", "bun", "npm", "deno"]
    ## Package managers accepted by ``--pkgmanager``.
  CssOptions* = ["tailwind", "none"] ## CSS setups accepted by ``--css``.
  DefaultPkgManager* = "pnpm"
    ## Used when ``--pkgmanager`` is omitted and stdin is not a TTY.

proc pkgCommands*(manager: string): tuple[install, dev, build: string] =
  ## Returns the install/dev/build commands for a package manager.
  case manager
  of "pnpm":
    (install: "pnpm install", dev: "pnpm dev", build: "pnpm build")
  of "bun":
    (install: "bun install", dev: "bun run dev", build: "bun run build")
  of "npm":
    (install: "npm install", dev: "npm run dev", build: "npm run build")
  of "deno":
    (install: "deno install", dev: "deno task dev", build: "deno task build")
  else:
    raise newException(ValueError, "unknown package manager: " & manager)

proc writeScaffoldFile(path, content: string) =
  createDir(path.parentDir())
  writeFile(path, content)

proc nimbleFile(name: string, commands: tuple[install, dev, build: string]): string =
  """# Package

version = "0.1.0"
author = "you"
description = """" & name &
    """ - FastNim + Inertia application"
license = "MIT"
srcDir = "src"
bin = @["main"]
binDir = "bin"

# Dependencies

requires "nim >= 2.2.12"
requires "chronos >= 4.0.0"
# Install fastnim from its repository until it is published on nimble.
requires "fastnim >= 0.1.0"

# Tasks

before build:
  # `nimble build` and `nimble run` bundle the client into client/dist first.
  if not dirExists("node_modules"):
    exec """" &
    commands.install & """"
  exec """" & commands.build & """"

task dev, "Run Vite and the Nim server, rebuilding the server on changes":
  exec "nim r --hints:off tools/dev.nim"
"""

const DevRunnerTemplate = """## Development runner for this project (`nimble dev`).
##
## Starts the Vite dev server, builds and runs the Nim server with
## INERTIA_DEV=1, and rebuilds/restarts the server whenever a `.nim` file
## under `src/` changes. Vite hot-reloads the client on its own.

import std/[os, osproc, strutils, tables, times]
when not defined(windows):
  from std/posix import Pid, SIGTERM, kill

const
  InstallCommand = "{{install}}"
  ViteCommand = "{{dev}}"
  ServerSource = "src" / "main.nim"
  PollInterval = 300 # milliseconds

let
  serverBinary = absolutePath("bin" / addFileExt("main_dev", ExeExt))
  stagedBinary = absolutePath("bin" / addFileExt("main_dev_next", ExeExt))

var
  vite: Process
  server: Process
  stopRequested = false

proc descendants(pid: int): seq[int] =
  when not defined(windows):
    let (output, code) = execCmdEx("pgrep -P " & $pid)
    if code == 0:
      for line in output.splitLines():
        if line.strip().len > 0:
          let child = parseInt(line.strip())
          result.add(child)
          result.add(descendants(child))

proc stop(process: var Process) =
  ## Stops ``process`` and everything it spawned: pnpm, for one, does not
  ## forward termination signals to Vite.
  if process != nil:
    if process.running:
      when defined(windows):
        discard execCmdEx("taskkill /T /F /PID " & $process.processID)
      else:
        for pid in descendants(process.processID):
          discard posix.kill(Pid(pid), SIGTERM)
        process.terminate()
      discard process.waitForExit()
    process.close()
    process = nil

proc requestStop() {.noconv.} =
  stopRequested = true

proc sourceTimes(): Table[string, Time] =
  for path in walkDirRec("src"):
    if path.endsWith(".nim"):
      try:
        result[path] = getLastModificationTime(path)
      except OSError:
        discard

proc buildServer(): bool =
  ## Compiles to a staging path so a running server binary is never overwritten.
  echo "[dev] building server..."
  var compiler = startProcess(
    "nim", args = ["c", "--hints:off", "-o:" & stagedBinary, ServerSource],
    options = {poUsePath, poParentStreams},
  )
  result = compiler.waitForExit() == 0
  compiler.close()

proc restartServer() =
  stop(server)
  moveFile(stagedBinary, serverBinary)
  server = startProcess(serverBinary, options = {poParentStreams})

when isMainModule:
  if not dirExists("node_modules") and execCmd(InstallCommand) != 0:
    quit("[dev] '" & InstallCommand & "' failed", 1)
  createDir("bin")
  putEnv("INERTIA_DEV", "1")
  setControlCHook(requestStop)
  vite = startProcess(ViteCommand, options = {poEvalCommand, poParentStreams})
  if buildServer() and not stopRequested:
    restartServer()
  var known = sourceTimes()
  var exitReported = false
  while not stopRequested:
    sleep(PollInterval)
    if not vite.running:
      echo "[dev] Vite exited; stopping."
      break
    if server != nil and not server.running and not exitReported:
      echo "[dev] server exited; waiting for changes..."
      exitReported = true
    let current = sourceTimes()
    if current != known:
      known = current
      if buildServer() and not stopRequested:
        restartServer()
        exitReported = false
      elif not stopRequested:
        echo "[dev] build failed; keeping the previous server running."
  stop(server)
  stop(vite)
"""

proc devRunner(commands: tuple[install, dev, build: string]): string =
  DevRunnerTemplate.multiReplace(
    ("{{install}}", commands.install), ("{{dev}}", commands.dev)
  )

const GitIgnore = """node_modules/
client/dist/
bin/
nimcache/
*.log
"""

proc devTemplateLines(vite, entry: string, react: bool): seq[string] =
  ## Nim source lines for the dev root template (Vite serves the assets).
  ## ``vite`` must include the Vite ``base`` path, since the dev server
  ## serves every module (including ``@vite/client``) under it.
  result = @[
    "proc devRootTemplate(pageJson: string): string =",
    "  \"<!doctype html><html><head>\" &", "    \"<meta charset='utf-8'>\" &",
    "    \"<meta name='viewport' content='width=device-width, initial-scale=1'>\" &",
  ]
  if react:
    result.add(
      [
        "    \"<script type='module'>\" &",
        "    \"import RefreshRuntime from '" & vite & "/@react-refresh';\" &",
        "    \"RefreshRuntime.injectIntoGlobalHook(window);\" &",
        "    \"window.$RefreshReg$ = () => {};\" &",
        "    \"window.$RefreshSig$ = () => (type) => type;\" &",
        "    \"window.__vite_plugin_react_preamble_installed__ = true;\" &",
        "    \"</script>\" &",
      ]
    )
  result.add(
    [
      "    \"<script type='module' src='" & vite & "/@vite/client'></script>\" &",
      "    \"<script type='module' src='" & vite & "/" & entry & "'></script>\" &",
    ]
  )
  result.add(
    [
      "    \"</head><body>\" &",
      "    \"<script data-page='app' type='application/json'>\" & pageJson & \"</script>\" &",
      "    \"<div id='app'></div>\" &", "    \"</body></html>\"",
    ]
  )

proc clientEntryPath(choices: InertiaChoices): string =
  ## Client entry module, relative to the project root (the Vite root).
  if choices.frontend == feReact: "client/src/main.tsx" else: "client/src/main.ts"

proc serverMain(name: string, choices: InertiaChoices, auth: bool): string =
  let entry = clientEntryPath(choices)
  let framework = if choices.frontend == feReact: "React" else: "Svelte"
  let authImports = if auth: "import auth\nimport routes/auth as auth_routes\n" else: ""
  let authSetup =
    if auth:
      "api.installPlugin(authentication())\napi.addRouter(auth_routes.authRouter)\n"
    else:
      ""
  """## """ & name & """ - FastNim + Inertia + """ & framework & """.

## Development (Vite dev server feeds client assets to the Nim server,
## which is rebuilt and restarted when files under src/ change):
##   nimble dev
##
## Production (bundle the client, then serve it from the Nim server):
##   APP_VERSION=$(date +%s) nimble run

import std/[json, os, times]

import chronos

import fastnim
import fastnim/plugins/inertia
""" &
    authImports & """
import routes/pages

""" &
    devTemplateLines("http://localhost:5173/assets", entry, choices.frontend == feReact)
    .join("\n") & "\n" & """

proc prodRootTemplate(pageJson: string): string =
  "<!doctype html><html><head>" &
    "<meta charset='utf-8'>" &
    "<meta name='viewport' content='width=device-width, initial-scale=1'>" &
    "<link rel='stylesheet' href='/assets/app.css'>" &
    "<script type='module' src='/assets/app.js'></script>" &
    "</head><body>" &
    "<script data-page='app' type='application/json'>" & pageJson & "</script>" &
    "<div id='app'></div>" &
    "</body></html>"

proc assetVersion(): string =
  ## Bumping the version makes Inertia clients reload on deploy.
  let override = getEnv("APP_VERSION", "")
  if override.len > 0:
    return override
  try:
    result = $getLastModificationTime("client" / "dist" / "app.js").toUnix()
  except OSError:
    result = "dev"

let isDev = getEnv("INERTIA_DEV", "") == "1"

let api = initFastNim()
api.installPlugin:
  inertiaPlugin(initInertiaOptions(
    version = assetVersion(),
    rootTemplate =
      if isDev: devRootTemplate
      else: prodRootTemplate,
    sharedProps = %*{"appName": """" &
    name & """"},
  ))
""" & authSetup & """
api.addRouter(pageRouter)
if not isDev:
  api.serveStatic("/assets", directory = "client" / "dist")

let server = api.serve(port = 8000)
echo "Listening at http://127.0.0.1:8000"
waitFor server.join()
"""

proc inertiaAuthRoutes(): string =
  """## Inertia login/logout routes backed by server-side sessions.

import std/json

import fastnim
import fastnim/plugins/inertia
import ../auth

let authRouter* = initRouter()

authRouter.get("/login"):
  inertia("Login")

authRouter.post("/login"):
  # Inertia form submissions must receive an Inertia page, a redirect, or an
  # Inertia location: re-render Login with errors instead of plain JSON.
  var input: LoginInput
  if not parseJsonBody(request, input):
    if request.isInertiaRequest():
      return inertia("Login", %*{"errors": {"form": "Invalid login request"}})
    return json(statusBadRequest, %*{"message": "invalid login request"})
  if not credentialsValid(input):
    if request.isInertiaRequest():
      return inertia("Login", %*{"errors": {"username": "Invalid credentials"}})
    return json(statusUnauthorized, %*{"message": "invalid credentials"})
  var response = inertiaLocation("/")
  discard await loginSession(sessionStore, response, input.username)
  response

authRouter.post("/logout"):
  var response = inertiaLocation("/login")
  await logoutSession(sessionStore, request, response)
  response
"""

proc serverPages(name: string): string =
  """## Inertia pages served by this application.
## Component names must match files in client/src/pages/.

import std/json

import fastnim
import fastnim/plugins/inertia

let pageRouter* = initRouter()

pageRouter.get("/"):
  inertia("Dashboard", %*{
    "message": "Hello from """ &
    name & """!", "stats": {"users": 2, "projects": 12}
  })

pageRouter.get("/users"):
  inertia("Users", %*{"users": [
    {"id": 1, "name": "Ada Lovelace", "email": "ada@example.com"},
    {"id": 2, "name": "Linus Torvalds", "email": "linus@example.com"},
  ]})
"""

proc clientPackageJson(name: string, choices: InertiaChoices): string =
  var deps = ""
  var devDeps = ""
  if choices.frontend == feReact:
    deps = """    "@inertiajs/react": "^2.2.0",
    "react": "^19.0.0",
    "react-dom": "^19.0.0""""
    devDeps = """    "@vitejs/plugin-react": "^5.0.0",
    "typescript": "^5.6.0",
    "vite": "^7.0.0""""
  else:
    deps = """    "@inertiajs/svelte": "^2.2.0",
    "svelte": "^5.0.0""""
    devDeps = """    "@sveltejs/vite-plugin-svelte": "^6.0.0",
    "svelte-check": "^4.0.0",
    "typescript": "^5.6.0",
    "vite": "^7.0.0""""
  if choices.css == cssTailwind:
    devDeps.add(
      ",\n    \"tailwindcss\": \"^4.0.0\",\n    \"@tailwindcss/vite\": \"^4.0.0\""
    )
  var managerField = ""
  if choices.pkgManager == "pnpm":
    managerField = ",\n  \"packageManager\": \"pnpm@10.0.0\""
  elif choices.pkgManager == "npm":
    managerField = ",\n  \"packageManager\": \"npm@11.0.0\""
  """{
  "name": """" & name & """",
  "private": true,
  "version": "0.1.0",
  "type": "module"""" &
    managerField & """,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
""" &
    deps & "\n" & """
  },
  "devDependencies": {
""" & devDeps & "\n" & """
  }
}
"""

proc viteConfig(choices: InertiaChoices): string =
  let entry = clientEntryPath(choices)
  var imports = "import { defineConfig } from \"vite\";\n"
  var plugins = ""
  if choices.frontend == feReact:
    imports.add("import react from \"@vitejs/plugin-react\";\n")
    plugins = "react()"
  else:
    imports.add("import { svelte } from \"@sveltejs/vite-plugin-svelte\";\n")
    plugins = "svelte()"
  if choices.css == cssTailwind:
    imports.add("import tailwindcss from \"@tailwindcss/vite\";\n")
    plugins.add(", tailwindcss()")
  imports & """
export default defineConfig({
  base: "/assets/",
  server: { port: 5173, strictPort: true, origin: "http://localhost:5173" },
  build: {
    outDir: "client/dist",
    emptyOutDir: true,
    rollupOptions: {
      input: """" &
    entry & """",
      output: {
        entryFileNames: "app.js",
        chunkFileNames: "chunk-[hash].js",
        assetFileNames: "app.css",
      },
    },
  },
  plugins: [""" &
    plugins & """],
});
"""

proc tsConfig(choices: InertiaChoices): string =
  var jsx = ""
  if choices.frontend == feReact:
    jsx = ",\n    \"jsx\": \"react-jsx\""
  """{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "skipLibCheck": true""" &
    jsx & """,
    "types": ["vite/client"]
  },
  "include": ["client/src"]
}
"""

proc clientEntry(choices: InertiaChoices): tuple[path, content: string] =
  if choices.frontend == feReact:
    result = (
      path: "src/main.tsx",
      content: """import "./app.css";
import { createRoot } from "react-dom/client";
import { createInertiaApp } from "@inertiajs/react";
import type { ComponentType } from "react";

createInertiaApp({
  resolve: (name) => {
    const pages = import.meta.glob("./pages/*.tsx", { eager: true }) as Record<
      string,
      { default: ComponentType }
    >;
    const page = pages["./pages/" + name + ".tsx"];
    if (!page) {
      throw new Error("Unknown page component: " + name);
    }
    return page;
  },
  setup({ el, App, props }) {
    createRoot(el).render(<App {...props} />);
  },
});
""",
    )
  else:
    result = (
      path: "src/main.ts",
      content: """import "./app.css";
import { createInertiaApp } from "@inertiajs/svelte";
import { mount } from "svelte";

createInertiaApp({
  resolve: (name) => {
    const pages = import.meta.glob("./pages/*.svelte", { eager: true }) as Record<
      string,
      { default: never }
    >;
    const page = pages["./pages/" + name + ".svelte"];
    if (!page) {
      throw new Error("Unknown page component: " + name);
    }
    return page;
  },
  setup({ el, App, props }) {
    mount(App, { target: el, props });
  },
});
""",
    )

proc clientCss(choices: InertiaChoices): string =
  if choices.css == cssTailwind:
    """@import "tailwindcss";
"""
  else:
    """/* Plain starter styles (no Tailwind). */
body {
  font-family: system-ui, sans-serif;
  margin: 0;
  color: #1a1a1a;
}

nav {
  display: flex;
  gap: 0.5rem;
  padding: 0.75rem 1.5rem;
  border-bottom: 1px solid #e2e2e2;
}

main {
  max-width: 56rem;
  margin: 0 auto;
  padding: 1.5rem;
}
"""

proc navLinks(tailwind: bool): tuple[home, users: string] =
  if tailwind:
    result = (
      home:
        "<Link href=\"/\" class=\"rounded px-3 py-1 font-semibold\">Dashboard</Link>",
      users: "<Link href=\"/users\" class=\"rounded px-3 py-1\">Users</Link>",
    )
  else:
    result = (
      home: "<Link href=\"/\">Dashboard</Link>",
      users: "<Link href=\"/users\">Users</Link>",
    )

proc dashboardPage(choices: InertiaChoices): tuple[path, content: string] =
  let tailwind = choices.css == cssTailwind
  let links = navLinks(tailwind)
  let shellOpen =
    if tailwind:
      "<div class=\"min-h-screen bg-slate-50 text-slate-900\">\n  <nav class=\"flex gap-2 border-b border-slate-200 bg-white px-6 py-3\">\n"
    else:
      "<div>\n  <nav>\n"
  let mainOpen =
    if tailwind:
      "  <main class=\"mx-auto flex max-w-4xl flex-col gap-6 p-6\">\n"
    else:
      "  <main>\n"
  if choices.frontend == feReact:
    result = (
      path: "src/pages/Dashboard.tsx",
      content:
        """import { useState } from "react";
import { Link } from "@inertiajs/react";

type Stats = { users: number; projects: number };

export default function Dashboard({
  message = "",
  stats = { users: 0, projects: 0 },
  appName = "FastNim",
}: {
  message?: string;
  stats?: Stats;
  appName?: string;
}) {
  const [count, setCount] = useState(0);
  return (
""" &
        shellOpen & """    """ & links.home & """
    """ & links.users & """
  </nav>
""" &
        mainOpen & """    <h1>{appName} dashboard</h1>
    <p>{message}</p>
    <p>
      {stats.users} users, {stats.projects} projects
    </p>
    <p>
      <button type="button" onClick={() => setCount(count - 1)}>-1</button>{" "}
      {count}{" "}
      <button type="button" onClick={() => setCount(count + 1)}>+1</button>
    </p>
  </main>
</div>
  );
}
""",
    )
  else:
    result = (
      path: "src/pages/Dashboard.svelte",
      content:
        """<script lang="ts">
  import { Link } from "@inertiajs/svelte";

  let { message = "", stats = { users: 0, projects: 0 }, appName = "FastNim" } =
    $props();
  let count = $state(0);
</script>

""" &
        shellOpen & """  """ & links.home & """
  """ & links.users & """
</nav>
""" &
        mainOpen & """  <h1>{appName} dashboard</h1>
  <p>{message}</p>
  <p>{stats.users} users, {stats.projects} projects</p>
  <p>
    <button type="button" onclick={() => (count -= 1)}>-1</button>
    {count}
    <button type="button" onclick={() => (count += 1)}>+1</button>
  </p>
</main>
</div>
""",
    )

proc usersPage(choices: InertiaChoices): tuple[path, content: string] =
  let tailwind = choices.css == cssTailwind
  let links = navLinks(tailwind)
  let shellOpen =
    if tailwind:
      "<div class=\"min-h-screen bg-slate-50 text-slate-900\">\n  <nav class=\"flex gap-2 border-b border-slate-200 bg-white px-6 py-3\">\n"
    else:
      "<div>\n  <nav>\n"
  let mainOpen =
    if tailwind:
      "  <main class=\"mx-auto flex max-w-4xl flex-col gap-4 p-6\">\n"
    else:
      "  <main>\n"
  if choices.frontend == feReact:
    result = (
      path: "src/pages/Users.tsx",
      content:
        """import { Link } from "@inertiajs/react";

type User = { id: number; name: string; email: string };

export default function Users({ users = [] }: { users?: User[] }) {
  return (
""" &
        shellOpen & """    """ & links.home & """
    """ & links.users & """
  </nav>
""" &
        mainOpen & """    <h1>Users ({users.length})</h1>
    <ul>
      {users.map((user) => (
        <li key={user.id}>
          {user.name} ({user.email})
        </li>
      ))}
    </ul>
  </main>
</div>
  );
}
""",
    )
  else:
    result = (
      path: "src/pages/Users.svelte",
      content:
        """<script lang="ts">
  import { Link } from "@inertiajs/svelte";

  let { users = [] } = $props();
</script>

""" &
        shellOpen & """  """ & links.home & """
  """ & links.users & """
</nav>
""" &
        mainOpen & """  <h1>Users ({users.length})</h1>
  <ul>
    {#each users as user (user.id)}
      <li>{user.name} ({user.email})</li>
    {/each}
  </ul>
</main>
</div>
""",
    )

proc loginPage(choices: InertiaChoices): tuple[path, content: string] =
  if choices.frontend == feReact:
    result = (
      path: "src/pages/Login.tsx",
      content: """import { Form } from "@inertiajs/react";

type LoginErrors = {
  form?: string;
  username?: string;
  password?: string;
};

export default function Login({ errors = {} }: { errors?: LoginErrors }) {
  return (
    <main className="mx-auto max-w-md p-6">
      <h1>Sign in</h1>
      {errors.form && <p role="alert">{errors.form}</p>}
      <Form action="/login" method="post">
        <label>Username <input name="username" defaultValue="ada" /></label>
        {errors.username && <p role="alert">{errors.username}</p>}
        <label>Password <input name="password" type="password" /></label>
        {errors.password && <p role="alert">{errors.password}</p>}
        <button type="submit">Sign in</button>
      </Form>
    </main>
  );
}
""",
    )
  else:
    result = (
      path: "src/pages/Login.svelte",
      content: """<script lang="ts">
  import { Form } from "@inertiajs/svelte";

  type LoginErrors = {
    form?: string;
    username?: string;
    password?: string;
  };

  let { errors = {} }: { errors?: LoginErrors } = $props();
</script>

<main class="mx-auto max-w-md p-6">
  <h1>Sign in</h1>
  {#if errors.form}
    <p role="alert">{errors.form}</p>
  {/if}
  <Form action="/login" method="post">
    <label>Username <input name="username" value="ada" /></label>
    {#if errors.username}
      <p role="alert">{errors.username}</p>
    {/if}
    <label>Password <input name="password" type="password" /></label>
    {#if errors.password}
      <p role="alert">{errors.password}</p>
    {/if}
    <button type="submit">Sign in</button>
  </Form>
</main>
""",
    )

proc projectReadme(
    name: string,
    choices: InertiaChoices,
    commands: tuple[install, dev, build: string],
    auth: bool,
): string =
  let framework =
    if choices.frontend == feReact: "React 19 + Vite" else: "Svelte 5 + Vite"
  let styling = if choices.css == cssTailwind: "Tailwind CSS v4" else: "plain CSS"
  let authDocs =
    if auth:
      """
## Authentication

Pages use an HttpOnly server-side session. Sign in at `/login` with the
generated development account `ada` / `s3cret`. Replace the demo user table
and in-memory session store before deploying.
"""
    else:
      ""
  """# """ & name & "\n" & """

FastNim + Inertia.js application (""" & framework &
    """, """ & styling & """).

## Prerequisites

- Nim >= 2.2.12 with fastnim installed
- Node.js with `""" &
    choices.pkgManager & """` on your PATH

## Layout

The client's `package.json`, `vite.config.ts`, `tsconfig.json`, and
`node_modules/` live in the project root next to the `.nimble` file; client
source lives in `client/src/` and the server in `src/`.

## Development

```sh
nimble dev
```

This installs client dependencies on first run (`""" &
    commands.install & """`), starts the Vite dev server
(`""" & commands.dev &
    """`) on http://localhost:5173, and builds and runs the Nim server with
`INERTIA_DEV=1`. Saving any `.nim` file under `src/` rebuilds and restarts
the server; Vite hot-reloads client changes.

Open http://127.0.0.1:8000. The Nim server renders the HTML shell and
serves Inertia JSON; Vite supplies the client bundle.

## Production

```sh
APP_VERSION=$(date +%s) nimble run
```

`nimble build` and `nimble run` first bundle the client (`""" &
    commands.build & """`) into
`client/dist`, then compile the server into `bin/`. The server serves
`client/dist` at `/assets`. Bump `APP_VERSION` on every deploy so Inertia
clients pick up fresh assets.

## Pages

Server components in `src/routes/pages.nim` (`inertia("Dashboard", ...)`)
must match files in `client/src/pages/` (`Dashboard`, `Users`).
""" &
    authDocs

proc scaffoldInertiajs*(dir, name: string, choices: InertiaChoices, auth = false) =
  ## Writes an Inertia.js project into ``dir``.
  ##
  ## ``dir`` should be the empty project root; ``name`` is the project and
  ## Nimble package name. Raises ``ValueError`` for unknown package managers.
  let commands = pkgCommands(choices.pkgManager)
  let entry = clientEntry(choices)
  let dashboard = dashboardPage(choices)
  let users = usersPage(choices)
  let login = loginPage(choices)
  writeScaffoldFile(dir / name & ".nimble", nimbleFile(name, commands))
  writeScaffoldFile(dir / "config.nims", "switch(\"path\", \"src\")\n")
  writeScaffoldFile(dir / ".gitignore", GitIgnore)
  writeScaffoldFile(dir / "tools" / "dev.nim", devRunner(commands))
  writeScaffoldFile(dir / "src" / "main.nim", serverMain(name, choices, auth))
  writeScaffoldFile(dir / "src" / "routes" / "pages.nim", serverPages(name))
  if auth:
    writeScaffoldFile(
      dir / "src" / "auth.nim", sessionAuthSource(["/login", "/assets/*"])
    )
    writeScaffoldFile(dir / "src" / "routes" / "auth.nim", inertiaAuthRoutes())
  writeScaffoldFile(dir / "package.json", clientPackageJson(name, choices))
  writeScaffoldFile(dir / "vite.config.ts", viteConfig(choices))
  writeScaffoldFile(dir / "tsconfig.json", tsConfig(choices))
  writeScaffoldFile(dir / "client" / entry.path, entry.content)
  writeScaffoldFile(dir / "client" / "src" / "app.css", clientCss(choices))
  writeScaffoldFile(dir / "client" / dashboard.path, dashboard.content)
  writeScaffoldFile(dir / "client" / users.path, users.content)
  if auth:
    writeScaffoldFile(dir / "client" / login.path, login.content)
  writeScaffoldFile(dir / "README.md", projectReadme(name, choices, commands, auth))
