## Inertia.js project scaffolding for ``fastnim init``.
##
## Generates a Nim server (FastNim + ``inertiaPlugin``) and a Vite client
## (Svelte or React, Tailwind v4 or plain CSS). The client is TypeScript;
## production builds use fixed ``app.js``/``app.css`` filenames so the
## server needs no manifest parsing.

import std/[os, strutils]

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
  CssOptions* = ["tailwind", "none"]
    ## CSS setups accepted by ``--css``.
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

proc nimbleFile(name: string): string =
  """# Package

version = "0.1.0"
author = "you"
description = """" & name & """ - FastNim + Inertia application"
license = "MIT"
srcDir = "src"

# Dependencies

requires "nim >= 2.2.12"
requires "chronos >= 4.0.0"
# Install fastnim from its repository until it is published on nimble.
requires "fastnim >= 0.1.0"
"""

proc devTemplateLines(vite, entry: string, react: bool): seq[string] =
  ## Nim source lines for the dev root template (Vite serves the assets).
  result = @[
    "proc devRootTemplate(pageJson: string): string =",
    "  \"<!doctype html><html><head>\" &",
    "    \"<meta charset='utf-8'>\" &",
    "    \"<meta name='viewport' content='width=device-width, initial-scale=1'>\" &",
  ]
  if react:
    result.add([
      "    \"<script type='module'>\" &",
      "    \"import RefreshRuntime from '" & vite & "/@react-refresh';\" &",
      "    \"RefreshRuntime.injectIntoGlobalHook(window);\" &",
      "    \"window.$RefreshReg$ = () => {};\" &",
      "    \"window.$RefreshSig$ = () => (type) => type;\" &",
      "    \"window.__vite_plugin_react_preamble_installed__ = true;\" &",
      "    \"</script>\" &",
    ])
  result.add(
    "    \"<script type='module' src='" & vite & "/" & entry & "'></script>\" &"
  )
  result.add([
    "    \"</head><body>\" &",
    "    \"<script data-page='app' type='application/json'>\" & pageJson & \"</script>\" &",
    "    \"<div id='app'></div>\" &",
    "    \"</body></html>\"",
  ])

proc serverMain(name: string, choices: InertiaChoices): string =
  let entry = if choices.frontend == feReact: "src/main.tsx" else: "src/main.ts"
  let framework =
    if choices.frontend == feReact: "React" else: "Svelte"
  """## """ & name & """ - FastNim + Inertia + """ & framework & """.

## Development (Vite dev server feeds client assets to the Nim server):
##   cd client && <install> && <dev>
##   INERTIA_DEV=1 nim c -r --path:src src/main.nim
##
## Production (serve the built bundle from the Nim server):
##   cd client && <install> && <build>
##   APP_VERSION=$(date +%s) nim c -r --path:src src/main.nim

import std/[json, os, times]

import chronos

import fastnim
import fastnim/plugins/inertia
import routes/pages

""" & devTemplateLines("http://localhost:5173", entry,
    choices.frontend == feReact).join("\n") & "\n" & """

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
api.install:
  inertiaPlugin(initInertiaOptions(
    version = assetVersion(),
    rootTemplate =
      if isDev: devRootTemplate
      else: prodRootTemplate,
    sharedProps = %*{"appName": """" & name & """"},
  ))
api.addRouter(pageRouter)
if not isDev:
  api.serveStatic("/assets", directory = "client" / "dist")

let server = api.serve(port = 8000)
echo "Listening at http://127.0.0.1:8000"
waitFor server.join()
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
    "message": "Hello from """ & name &
    """!", "stats": {"users": 2, "projects": 12}
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
    devDeps.add(",\n    \"tailwindcss\": \"^4.0.0\",\n    \"@tailwindcss/vite\": \"^4.0.0\"")
  var managerField = ""
  if choices.pkgManager == "pnpm":
    managerField = ",\n  \"packageManager\": \"pnpm@10.0.0\""
  elif choices.pkgManager == "npm":
    managerField = ",\n  \"packageManager\": \"npm@11.0.0\""
  """{
  "name": """" & name & """-client",
  "private": true,
  "version": "0.1.0",
  "type": "module"""" & managerField & """,
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "preview": "vite preview"
  },
  "dependencies": {
""" & deps & "\n" & """
  },
  "devDependencies": {
""" & devDeps & "\n" & """
  }
}
"""

proc viteConfig(choices: InertiaChoices): string =
  let entry = if choices.frontend == feReact: "src/main.tsx" else: "src/main.ts"
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
  server: { port: 5173, strictPort: true },
  build: {
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: """" & entry & """",
      output: {
        entryFileNames: "app.js",
        chunkFileNames: "chunk-[hash].js",
        assetFileNames: "app.css",
      },
    },
  },
  plugins: [""" & plugins & """],
});
"""

proc clientIndexHtml(name: string): string =
  """<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>""" & name & """</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>
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
    "skipLibCheck": true""" & jsx & """,
    "types": ["vite/client"]
  },
  "include": ["src"]
}
"""

proc clientEntry(choices: InertiaChoices): tuple[path, content: string] =
  if choices.frontend == feReact:
    result = (path: "src/main.tsx", content: """import "./app.css";
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
""")
  else:
    result = (path: "src/main.ts", content: """import "./app.css";
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
""")

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
      home: "<Link href=\"/\" class=\"rounded px-3 py-1 font-semibold\">Dashboard</Link>",
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
    result = (path: "src/pages/Dashboard.tsx", content: """import { useState } from "react";
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
""" & shellOpen & """    """ & links.home & """
    """ & links.users & """
  </nav>
""" & mainOpen & """    <h1>{appName} dashboard</h1>
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
""")
  else:
    result = (path: "src/pages/Dashboard.svelte", content: """<script lang="ts">
  import { Link } from "@inertiajs/svelte";

  let { message = "", stats = { users: 0, projects: 0 }, appName = "FastNim" } =
    $props();
  let count = $state(0);
</script>

""" & shellOpen & """  """ & links.home & """
  """ & links.users & """
</nav>
""" & mainOpen & """  <h1>{appName} dashboard</h1>
  <p>{message}</p>
  <p>{stats.users} users, {stats.projects} projects</p>
  <p>
    <button type="button" onclick={() => (count -= 1)}>-1</button>
    {count}
    <button type="button" onclick={() => (count += 1)}>+1</button>
  </p>
</main>
</div>
""")

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
    result = (path: "src/pages/Users.tsx", content: """import { Link } from "@inertiajs/react";

type User = { id: number; name: string; email: string };

export default function Users({ users = [] }: { users?: User[] }) {
  return (
""" & shellOpen & """    """ & links.home & """
    """ & links.users & """
  </nav>
""" & mainOpen & """    <h1>Users ({users.length})</h1>
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
""")
  else:
    result = (path: "src/pages/Users.svelte", content: """<script lang="ts">
  import { Link } from "@inertiajs/svelte";

  let { users = [] } = $props();
</script>

""" & shellOpen & """  """ & links.home & """
  """ & links.users & """
</nav>
""" & mainOpen & """  <h1>Users ({users.length})</h1>
  <ul>
    {#each users as user (user.id)}
      <li>{user.name} ({user.email})</li>
    {/each}
  </ul>
</main>
</div>
""")

proc projectReadme(
    name: string, choices: InertiaChoices,
    commands: tuple[install, dev, build: string],
): string =
  let framework =
    if choices.frontend == feReact: "React 19 + Vite" else: "Svelte 5 + Vite"
  let styling =
    if choices.css == cssTailwind: "Tailwind CSS v4" else: "plain CSS"
  """# """ & name & "\n" & """

FastNim + Inertia.js application (""" & framework & """, """ & styling & """).

## Prerequisites

- Nim >= 2.2.12 with fastnim installed
- Node.js with `""" & choices.pkgManager & """` on your PATH

## Development

```sh
cd client
""" & commands.install & """
""" & commands.dev & """      # Vite dev server on http://localhost:5173
```

In another terminal, from the project root:

```sh
INERTIA_DEV=1 nim c -r --path:src src/main.nim
```

Open http://127.0.0.1:8000. The Nim server renders the HTML shell and
serves Inertia JSON; Vite supplies the client bundle with hot reload.

## Production

```sh
cd client
""" & commands.install & """
""" & commands.build & """
cd ..
APP_VERSION=$(date +%s) nim c -r --path:src src/main.nim
```

The server serves `client/dist` at `/assets`. Bump `APP_VERSION` on every
deploy so Inertia clients pick up fresh assets.

## Pages

Server components in `src/routes/pages.nim` (`inertia("Dashboard", ...)`)
must match files in `client/src/pages/` (`Dashboard`, `Users`).
"""

proc scaffoldInertiajs*(dir, name: string, choices: InertiaChoices) =
  ## Writes an Inertia.js project into ``dir``.
  ##
  ## ``dir`` should be the empty project root; ``name`` is the project and
  ## Nimble package name. Raises ``ValueError`` for unknown package managers.
  let commands = pkgCommands(choices.pkgManager)
  let entry = clientEntry(choices)
  let dashboard = dashboardPage(choices)
  let users = usersPage(choices)
  writeScaffoldFile(dir / name & ".nimble", nimbleFile(name))
  writeScaffoldFile(dir / "config.nims", "switch(\"path\", \"src\")\n")
  writeScaffoldFile(dir / "src" / "main.nim", serverMain(name, choices))
  writeScaffoldFile(dir / "src" / "routes" / "pages.nim", serverPages(name))
  writeScaffoldFile(
    dir / "client" / "package.json", clientPackageJson(name, choices)
  )
  writeScaffoldFile(
    dir / "client" / "vite.config.ts", viteConfig(choices)
  )
  writeScaffoldFile(
    dir / "client" / "index.html", clientIndexHtml(name)
  )
  writeScaffoldFile(
    dir / "client" / "tsconfig.json", tsConfig(choices)
  )
  writeScaffoldFile(
    dir / "client" / entry.path, entry.content
  )
  writeScaffoldFile(
    dir / "client" / "src" / "app.css", clientCss(choices)
  )
  writeScaffoldFile(
    dir / "client" / dashboard.path, dashboard.content
  )
  writeScaffoldFile(
    dir / "client" / users.path, users.content
  )
  writeScaffoldFile(
    dir / "README.md", projectReadme(name, choices, commands)
  )
