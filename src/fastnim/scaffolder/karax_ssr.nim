## Server-rendered Karax project scaffolding for ``fastnim init``.
##
## Generates a Nim server whose routes render Karax markup to HTML strings.
## Karax stays a dependency of the generated project, not of fastnim.

import std/os

import ./auth

proc writeSsrFile(path, content: string) =
  createDir(path.parentDir())
  writeFile(path, content)

proc ssrNimble(name: string): string =
  """# Package

version = "0.1.0"
author = "you"
description = """" & name &
    """ - FastNim + Karax SSR"
license = "MIT"
srcDir = "src"

# Dependencies

requires "nim >= 2.2.12"
requires "chronos >= 4.0.0"
requires "karax >= 1.5.0"
# Install fastnim from its repository until it is published on nimble.
requires "fastnim >= 0.1.0"
"""

proc ssrPages(name: string): string =
  """## Server-rendered Karax pages.
##
## Karax also exports `text`, so this module hides FastNim's to keep
## `buildHtml` unambiguous.

import fastnim except text
import karax/[karaxdsl, vdom]

let pageRouter* = initRouter()

proc layout(title, inner: string): string =
  let node = buildHtml(html):
    head:
      title:
        text title
    body:
      verbatim inner
  "<!doctype html>" & $node

pageRouter.get("/"):
  let content = buildHtml(tdiv):
    h1:
      text "Hello from """ &
    name & """"
    p:
      text "Rendered server-side with Karax."
    p:
      text "Try /users/Ada for a dynamic page."
  html layout("Home", $content)

pageRouter.get("/users/{name}"):
  let who = request.pathParam("name")
  let content = buildHtml(tdiv):
    h1:
      text "Hello, " & who
  html layout("User", $content)
"""

proc ssrMain(name: string, auth: bool): string =
  let authImports = if auth: "import auth\nimport routes/auth as auth_routes\n" else: ""
  let authSetup =
    if auth:
      "api.installPlugin(authentication())\napi.addRouter(auth_routes.authRouter)\n"
    else:
      ""
  """## """ & name & """ - FastNim + Karax SSR.
##
## Run with: nim c -r --path:src src/main.nim

import chronos

import fastnim
""" &
    authImports & """
import routes/pages

let api = initFastNim()
""" & authSetup & """
api.addRouter(pageRouter)

let server = api.serve(port = 8000)
echo "Listening at http://127.0.0.1:8000"
waitFor server.join()
"""

proc ssrAuthRoutes(): string =
  """## HTML login and logout routes for session authentication.

import fastnim
import ../auth

let authRouter* = initRouter()

proc redirectTo(path: string): Response =
  result = initResponse(statusSeeOther)
  result.setHeader("location", path)

authRouter.get("/login"):
  html "<!doctype html><html><body><h1>Sign in</h1>" &
    "<form method='post' action='/login'>" &
    "<label>Username <input name='username' value='ada'></label>" &
    "<label>Password <input name='password' type='password'></label>" &
    "<button type='submit'>Sign in</button></form></body></html>"

authRouter.post(
  "/login", form = LoginInput, responses = @[(303, void), (401, string)]
):
  if not credentialsValid(form):
    html(statusUnauthorized, "<h1>Invalid credentials</h1>")
  else:
    var response = redirectTo("/")
    discard await loginSession(sessionStore, response, form.username)
    response

authRouter.post("/logout", responses = @[(303, void)]):
  var response = redirectTo("/login")
  await logoutSession(sessionStore, request, response)
  response
"""

proc ssrTests(name: string): string =
  """import std/strutils

import fastnim
import routes/pages

block homePage:
  let api = initFastNim(logs = false)
  api.addRouter(pageRouter)

  let response = api.handleSync(initRequest(HttpMethod.Get, "/"))
  doAssert response.status == 200
  doAssert response.headers["content-type"] == "text/html; charset=utf-8"
  doAssert response.body.startsWith("<!doctype html>")
  doAssert "<h1>Hello from """ &
    name & """</h1>" in response.body

block userPage:
  let api = initFastNim(logs = false)
  api.addRouter(pageRouter)

  let response = api.handleSync(initRequest(HttpMethod.Get, "/users/Ada"))
  doAssert response.status == 200
  doAssert "<h1>Hello, Ada</h1>" in response.body
"""

proc ssrReadme(name: string, auth: bool): string =
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

FastNim server with server-rendered Karax pages.

## Run

```sh
nim c -r --path:src src/main.nim
```

Open http://127.0.0.1:8000 and http://127.0.0.1:8000/users/Ada.
""" &
    authDocs & """

## Test

```sh
nimble test
```

## Notes

- Pages are plain Karax `buildHtml` markup stringified with `$` and sent
  with the `html` helper. Rendering is static: Karax event handlers do not
  survive server-side rendering.
- `src/routes/pages.nim` uses `import fastnim except text` because Karax
  exports its own `text` routine for `buildHtml`.
- For interactive pages, scaffold with `--template:karax_csr` instead and
  compile the client with `nim js`.
"""

proc scaffoldKaraxSsr*(dir, name: string, auth = false) =
  ## Writes a Karax SSR project into ``dir``.
  ##
  ## ``dir`` should be the empty project root; ``name`` is the project and
  ## Nimble package name.
  writeSsrFile(dir / name & ".nimble", ssrNimble(name))
  writeSsrFile(dir / "config.nims", "switch(\"path\", \"src\")\n")
  writeSsrFile(dir / "src" / "main.nim", ssrMain(name, auth))
  writeSsrFile(dir / "src" / "routes" / "pages.nim", ssrPages(name))
  if auth:
    writeSsrFile(dir / "src" / "auth.nim", sessionAuthSource(["/login"]))
    writeSsrFile(dir / "src" / "routes" / "auth.nim", ssrAuthRoutes())
  writeSsrFile(dir / "tests" / "test_pages.nim", ssrTests(name))
  writeSsrFile(dir / "README.md", ssrReadme(name, auth))
