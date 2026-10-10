## Inertia.js + Svelte + DaisyUI example.
##
## Run with: nim c -r --path:src examples/inertia_svelte_daisyui.nim
## Then open http://127.0.0.1:8090 in a browser.
##
## No npm build step is needed. The Nim server renders the Inertia HTML shell
## (styled with the DaisyUI/Tailwind CDN) and serves a small ``/assets/app.js``
## client. That client boots ``createInertiaApp`` from the Svelte adapter
## loaded via an ``esm.sh`` import map, and compiles the page components with
## ``svelte/compiler`` directly in the browser.

import std/json

import chronos

import fastnim
import fastnim/plugins/inertia

const clientJs = """
import { createInertiaApp } from "@inertiajs/svelte";
import { mount } from "svelte";
import { compile } from "svelte/compiler";

const inertiaSvelteUrl =
  "https://esm.sh/@inertiajs/svelte@2?external=svelte";

// Svelte page sources compiled in the browser, so this example needs no
// build step. Each key must match the component name sent by the server.
const sources = {
  Dashboard: `
<script>
  import { Link } from "@inertiajs/svelte";
  let { message = "", stats = null, appName = "FastNim" } = $props();
  let count = $state(0);
</script>

<div class="navbar bg-base-100 shadow-sm px-4">
  <div class="flex-1">
    <span class="text-xl font-bold">{appName}</span>
  </div>
  <div class="flex-none flex gap-2">
    <Link href="/" class="btn btn-primary btn-sm">Dashboard</Link>
    <Link href="/users" class="btn btn-ghost btn-sm">Users</Link>
  </div>
</div>

<div class="max-w-4xl mx-auto p-6 flex flex-col gap-6">
  <div class="hero bg-base-200 rounded-box">
    <div class="hero-content text-center py-10">
      <div class="max-w-md">
        <h1 class="text-4xl font-bold">Dashboard</h1>
        <p class="py-4 opacity-70">{message}</p>
        <Link href="/users" class="btn btn-primary">View users</Link>
      </div>
    </div>
  </div>

  <div class="stats shadow w-full">
    <div class="stat">
      <div class="stat-title">Users</div>
      <div class="stat-value">{stats?.users ?? 0}</div>
      <div class="stat-desc">Registered accounts</div>
    </div>
    <div class="stat">
      <div class="stat-title">Projects</div>
      <div class="stat-value">{stats?.projects ?? 0}</div>
      <div class="stat-desc">Active workspaces</div>
    </div>
    <div class="stat">
      <div class="stat-title">Uptime</div>
      <div class="stat-value">{stats?.uptime ?? "--"}</div>
      <div class="stat-desc">Last 30 days</div>
    </div>
  </div>

  <div class="card bg-base-100 shadow">
    <div class="card-body items-center text-center">
      <h2 class="card-title">Svelte interactivity check</h2>
      <p class="opacity-70">Local state, no server round-trip:</p>
      <div class="card-actions items-center gap-3">
        <button class="btn btn-secondary" onclick={() => count -= 1}>-1</button>
        <span class="text-2xl font-mono w-12">{count}</span>
        <button class="btn btn-secondary" onclick={() => count += 1}>+1</button>
      </div>
    </div>
  </div>
</div>
`,
  Users: `
<script>
  import { Link } from "@inertiajs/svelte";
  let { users = [], appName = "FastNim" } = $props();
</script>

<div class="navbar bg-base-100 shadow-sm px-4">
  <div class="flex-1">
    <span class="text-xl font-bold">{appName}</span>
  </div>
  <div class="flex-none flex gap-2">
    <Link href="/" class="btn btn-ghost btn-sm">Dashboard</Link>
    <Link href="/users" class="btn btn-primary btn-sm">Users</Link>
  </div>
</div>

<div class="max-w-4xl mx-auto p-6 flex flex-col gap-4">
  <div class="flex items-center justify-between">
    <h1 class="text-3xl font-bold">Users ({users.length})</h1>
    <Link href="/" class="btn btn-ghost btn-sm">Back to dashboard</Link>
  </div>

  <div class="overflow-x-auto rounded-box border border-base-content/10">
    <table class="table">
      <thead>
        <tr><th>Name</th><th>Email</th><th>Role</th><th>Status</th></tr>
      </thead>
      <tbody>
        {#each users as user (user.id)}
          <tr class="hover">
            <td>
              <div class="flex items-center gap-3">
                <div class="avatar avatar-placeholder">
                  <div class="bg-neutral text-neutral-content w-9 rounded-full">
                    <span class="text-xs">{user.name.slice(0, 1)}</span>
                  </div>
                </div>
                <span class="font-bold">{user.name}</span>
              </div>
            </td>
            <td>{user.email}</td>
            <td>{user.role}</td>
            <td>
              {#if user.active}
                <span class="badge badge-success">active</span>
              {:else}
                <span class="badge badge-ghost">invited</span>
              {/if}
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
  <p class="text-sm opacity-60">Rendered by Svelte from Inertia page props.</p>
</div>
`,
};

const compiled = {};

async function resolvePage(name) {
  if (compiled[name]) return compiled[name];
  const source = sources[name];
  if (!source) throw new Error("Unknown Inertia page: " + name);
  // Compile the Svelte source to a client component.
  const { js } = compile(source, { generate: "client", filename: name + ".svelte" });
  // Blob modules cannot resolve bare specifiers, so point the adapter
  // import at the CDN URL (the import map covers everything else).
  const code = js.code.split('from "@inertiajs/svelte"').join(
    `from "${inertiaSvelteUrl}"`,
  );
  const url = URL.createObjectURL(new Blob([code], { type: "text/javascript" }));
  const mod = await import(url);
  URL.revokeObjectURL(url);
  compiled[name] = mod.default;
  return mod.default;
}

createInertiaApp({
  resolve: (name) => resolvePage(name),
  setup({ el, App, props }) {
    mount(App, { target: el, props });
  },
  progress: { color: "#570df8" },
});
"""

proc rootTemplate(pageJson: string): string =
  """<!doctype html>
<html lang="en" data-theme="light">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>FastNim Inertia + Svelte</title>
    <link href="https://cdn.jsdelivr.net/npm/daisyui@5" rel="stylesheet" type="text/css">
    <script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4"></script>
    <script type="importmap">
      {
        "imports": {
          "svelte": "https://esm.sh/svelte@5",
          "svelte/": "https://esm.sh/svelte@5/",
          "@inertiajs/core": "https://esm.sh/@inertiajs/core@2?external=svelte",
          "@inertiajs/svelte": "https://esm.sh/@inertiajs/svelte@2?external=svelte"
        }
      }
    </script>
    <script type="module" src="/assets/app.js"></script>
  </head>
  <body>
    <script data-page="app" type="application/json">""" & pageJson &
    """</script>
    <div id="app"></div>
  </body>
</html>"""

proc dashboardProps(): JsonNode =
  %*{
    "message": "Hello from FastNim over Inertia.js",
    "stats": {"users": 5, "projects": 12, "uptime": "99.9%"},
  }

proc usersProps(): JsonNode =
  %*{
    "users": [
      {"id": 1, "name": "Ada Lovelace", "email": "ada@example.com",
       "role": "Admin", "active": true},
      {"id": 2, "name": "Linus Torvalds", "email": "linus@example.com",
       "role": "Maintainer", "active": true},
      {"id": 3, "name": "Grace Hopper", "email": "grace@example.com",
       "role": "Reviewer", "active": false},
      {"id": 4, "name": "Edsger Dijkstra", "email": "edsger@example.com",
       "role": "Contributor", "active": true},
      {"id": 5, "name": "Barbara Liskov", "email": "barbara@example.com",
       "role": "Contributor", "active": false},
    ]
  }

let app = initFastNim()
app.install:
  inertiaPlugin(
    initInertiaOptions(
      version = "1",
      rootTemplate = rootTemplate,
      sharedProps = %*{"appName": "FastNim + Svelte"},
    )
  )

app.get("/assets/app.js"):
  var res = initResponse(clientJs, 200)
  res.setHeader("content-type", "text/javascript; charset=utf-8")
  res.setHeader("cache-control", "no-cache")
  res

app.get("/"):
  inertia("Dashboard", dashboardProps())

app.get("/users"):
  inertia("Users", usersProps())

let server = app.serve(port = 8090)
echo "Listening at http://127.0.0.1:8090"
waitFor server.join()
