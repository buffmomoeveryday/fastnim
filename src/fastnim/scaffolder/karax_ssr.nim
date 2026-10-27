## Server-rendered HTMX project scaffolding for ``fastnim init --template:ssr``.

import std/os

import ./[api, auth]

proc writeSsrFile(path, content: string) =
  createDir(path.parentDir())
  writeFile(path, content)

proc serviceSource(): string =
  """## Database operations used by the author pages.

import fastnim/orm
import ../models/author

proc listAuthors*(): Future[seq[Author]] {.async.} =
  ## Returns all authors ordered by name.
  await Author.objects.orderBy("name").all()

proc createAuthor*(name: string): Future[Author] {.async.} =
  ## Creates and returns an author.
  let author = Author(name: name)
  await author.save()
  author
"""

proc baseTemplateSource(): string =
  """## Shared HTML document layout.

proc layout*(title, content: string): string =
  ## Wraps page content and loads HTMX for progressively enhanced requests.
  "<!doctype html><html><head><meta charset='utf-8'>" &
    "<meta name='viewport' content='width=device-width,initial-scale=1'>" &
    "<title>" & title & "</title>" &
    "<script src='https://unpkg.com/htmx.org@2.0.4'></script>" &
    "</head><body><main>" & content & "</main></body></html>"
"""

proc authorsTemplateSource(): string =
  """## Author page and HTMX fragment renderers.

import std/xmltree
import ../models/author

proc authorItem*(author: Author): string =
  ## Renders one author list item.
  "<li id='author-" & $author.id & "'>" & xmltree.escape(author.name) & "</li>"

proc authorList*(authors: openArray[Author]): string =
  ## Renders the replaceable author list fragment.
  result = "<ul id='authors'>"
  for author in authors:
    result.add authorItem(author)
  result.add "</ul>"

proc authorsPage*(authors: openArray[Author]): string =
  ## Renders the page content; the form posts and swaps through HTMX.
  "<h1>Authors</h1>" & authorList(authors) &
    "<form hx-post='/authors' hx-target='#authors' hx-swap='beforeend'>" &
    "<label>Name <input name='name' required maxlength='120'></label>" &
    "<button type='submit'>Add author</button></form>"
"""

proc routerSource(): string =
  """## Server-rendered author routes with HTMX fragments.

import fastnim
import ../services/authors_service
import ../templates/[base, authors]

type AuthorForm = object
  name: string

let pageRouter* = initRouter()

pageRouter.get("/"):
  html layout("Authors", authorsPage(await listAuthors()))

pageRouter.post(
  "/authors", form = AuthorForm,
  responses = @[(200, string), (303, void)],
):
  let author = await createAuthor(form.name)
  if request.isHtmx:
    html authorItem(author)
  else:
    var response = initResponse(statusSeeOther)
    response.setHeader("location", "/")
    response
"""

proc mainSource(name: string, auth: bool): string =
  let authImports = if auth: "import auth\nimport routers/auth as auth_routes\n" else: ""
  let authSetup =
    if auth:
      "app.installPlugin(authentication())\napp.addRouter(auth_routes.authRouter)\n"
    else:
      ""
  """## """ & name & """ server-rendered application.

import chronos
import fastnim
import fastnim/orm

import settings
""" & authImports & """import routers/pages

let app = initFastNim()
app.installPlugin(htmxPlugin())
""" & authSetup & """app.addRouter(pageRouter)

proc openApp(ctx: Context) =
  let database = waitFor openDatabase(databasePath)
  ctx.setContext("database", database)

proc closeApp(ctx: Context) =
  waitFor ctx.get("database", Database).close()

app.onLoad openApp
app.onUnload closeApp

when isMainModule:
  let server = app.serve(port = appPort())
  echo "Listening at http://127.0.0.1:" & $appPort()
  waitFor server.join()
"""

proc authRoutesSource(): string =
  """## Session login and logout routes.

import fastnim
import ../auth

let authRouter* = initRouter()

authRouter.get("/login"):
  html "<h1>Sign in</h1><form method='post' action='/login'>" &
    "<input name='username'><input name='password' type='password'>" &
    "<button type='submit'>Sign in</button></form>"

authRouter.post(
  "/login", form = LoginInput,
  responses = @[(303, void), (401, string)],
):
  if not credentialsValid(form):
    html(statusUnauthorized, "<h1>Invalid credentials</h1>")
  else:
    var response = initResponse(statusSeeOther)
    response.setHeader("location", "/")
    discard await loginSession(sessionStore, response, form.username)
    response
"""

proc testSource(name: string): string =
  """import std/[strutils, unittest]

import models/author
import templates/[base, authors]

suite """" & name & """ templates":
  test "layout includes HTMX":
    check "htmx.org@2" in layout("Test", "<p>Body</p>")

  test "author names are escaped":
    check "&lt;Ada&gt;" in authorItem(Author(id: 1, name: "<Ada>"))
"""

proc scaffoldKaraxSsr*(dir, name: string, auth = false) =
  ## Writes a structured server-rendered HTMX project into ``dir``.
  scaffoldStructuredProject(dir, name, ssr = true)
  writeSsrFile(dir / "src" / "services" / "authors_service.nim", serviceSource())
  writeSsrFile(dir / "src" / "templates" / "base.nim", baseTemplateSource())
  writeSsrFile(dir / "src" / "templates" / "authors.nim", authorsTemplateSource())
  writeSsrFile(dir / "src" / "routers" / "pages.nim", routerSource())
  writeSsrFile(dir / "src" / name & ".nim", mainSource(name, auth))
  if auth:
    writeSsrFile(dir / "src" / "auth.nim", sessionAuthSource(["/login"]))
    writeSsrFile(dir / "src" / "routers" / "auth.nim", authRoutesSource())
    writeSsrFile(
      dir / "README.md",
      readFile(dir / "README.md") &
        "\n## Authentication\n\nThe SSR starter uses an HttpOnly server-side session. " &
        "Replace the generated demo account before deployment.\n",
    )
  writeSsrFile(dir / "tests" / "test_app.nim", testSource(name))
