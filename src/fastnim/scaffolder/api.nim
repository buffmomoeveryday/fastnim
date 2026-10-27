## Structured JSON API project scaffolding for ``fastnim init --template:api``.

import std/os

import ./auth

proc writeApiFile(path, content: string) =
  createDir(path.parentDir())
  writeFile(path, content)

proc projectNimble(name: string): string =
  """# Package

version = "0.1.0"
author = "you"
description = """" & name &
    """ - FastNim application"
license = "MIT"
srcDir = "src"
bin = @["""" & name & """"]
binDir = "."

# Dependencies

requires "nim >= 2.2.12"
requires "chronos >= 4.0.0"
requires "fastnim >= 1.0.0"

# Database tasks

task bootstrap, "Generate and apply migrations for first-time setup":
  exec "fastnim makemigrations"
  exec "fastnim migrate"

task makemigrations, "Generate migrations from the current models":
  exec "fastnim makemigrations"

task migrate, "Apply pending database migrations":
  exec "fastnim migrate"
"""

proc settingsSource(name: string): string =
  """## Application settings shared by the server and management commands.

import std/[os, strutils]

const
  appName* = """" & name & """"
  migrationsDir* = "src/migrations"

let databasePath* = getEnv("DATABASE_PATH", "database.db")

proc appPort*(): uint16 =
  ## Returns the HTTP port configured through ``PORT``.
  uint16(getEnv("PORT", "8000").parseInt())
"""

proc manageSource(): string =
  """## Project management entrypoint used by the ``fastnim`` CLI.

import fastnim/orm
import settings
import models/index
import migrations/all

when isMainModule:
  quit runCli(
    defaultDbPath = databasePath,
    defaultMigrationsDir = migrationsDir,
  )
"""

proc modelSource(): string =
  """## Author database model.

import fastnim/orm

model Author:
  name:
    CharField(maxLength: 120, minLength: 1, unique: true)
"""

proc modelIndexSource(): string =
  """## Public model namespace. Import every model here so migrations see it.

import ./author

export author
"""

proc serviceSource(): string =
  """## Database operations for authors.

import fastnim/orm
import ../models/author

proc listAuthors*(): Future[seq[Author]] {.async.} =
  ## Returns all authors ordered by name.
  await Author.objects.orderBy("name").all()

proc createAuthor*(author: Author): Future[Author] {.async.} =
  ## Validates and stores an author supplied by the request body.
  await author.save()
  author
"""

proc routerSource(): string =
  """## Author JSON endpoints.

import fastnim
import fastnim/orm
import ../models/author
import ../services/authors_service

let authorRouter* = initRouter(prefix = "/authors", tags = @["authors"])

authorRouter.get("/", responses = @[(200, seq[Author])]):
  ok await listAuthors()

authorRouter.post("/", body = Author.ignore(id), responses = @[(201, Author)]):
  created await createAuthor(body)
"""

proc mainSource(name: string, auth: bool): string =
  let authImports = if auth: "import auth\nimport routers/auth as auth_routes\n" else: ""
  let authSetup =
    if auth:
      "app.installPlugin(authentication())\napp.addRouter(auth_routes.authRouter, prefix = \"/api\")\n"
    else:
      ""
  """## """ & name & """ application entrypoint.

import chronos
import fastnim
import fastnim/orm

import settings
""" & authImports & """import routers/authors

let app = initFastNim()
""" & authSetup & """app.addRouter(authorRouter, prefix = "/api")

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
  """## JWT login route.

import fastnim
import ../auth

let authRouter* = initRouter(prefix = "/auth", tags = @["auth"])

authRouter.post(
  "/login", body = LoginInput,
  responses = @[(200, TokenOutput), (401, ApiError)],
):
  if not credentialsValid(body):
    unauthorized initApiError("invalid_credentials", "invalid credentials")
  else:
    ok issueToken(body.username)
"""

proc testSource(name: string): string =
  """import std/unittest

import fastnim
import routers/authors

suite """" & name & """ routes":
  test "author router is mountable":
    let app = initFastNim(logs = false)
    app.addRouter(authorRouter, prefix = "/api")
    check app != nil
"""

proc readmeSource(name, templateName: string, auth: bool): string =
  let authDocs =
    if auth:
      """

## Authentication

The API starter uses bearer JWTs. Replace the demo credentials and set a
strong `JWT_SECRET` before deployment.
"""
    else:
      ""
  """# """ & name & """

FastNim """ & templateName & """ project with explicit database migrations.

```sh
nimble setup
nimble bootstrap
nimble run
```

`makemigrations` only writes migration modules. The server never applies them
automatically; run `nimble migrate` during deployment before starting it.

- Settings: `src/settings.nim`
- Models: `src/models/`
- Routers: `src/routers/`
- Services: `src/services/`
- Migrations: `src/migrations/`
""" & authDocs

proc scaffoldStructuredProject*(dir, name: string, auth = false, ssr = false) =
  ## Writes the common settings, ORM, management, and application structure.
  writeApiFile(dir / name & ".nimble", projectNimble(name))
  writeApiFile(dir / "config.nims", "switch(\"path\", \"src\")\n")
  writeApiFile(dir / ".gitignore", "database.db*\n/.fastnim/\n/" & name & "\n")
  writeApiFile(dir / "src" / "settings.nim", settingsSource(name))
  writeApiFile(dir / "src" / "manage.nim", manageSource())
  writeApiFile(
    dir / "src" / "migrations" / "all.nim", "## Compiled migrations.\n\ndiscard\n"
  )
  writeApiFile(dir / "src" / "models" / "author.nim", modelSource())
  writeApiFile(dir / "src" / "models" / "index.nim", modelIndexSource())
  createDir(dir / "src" / "services")
  createDir(dir / "src" / "routers")
  createDir(dir / "src" / "templates")
  if not ssr:
    writeApiFile(dir / "src" / "services" / "authors_service.nim", serviceSource())
    writeApiFile(dir / "src" / "routers" / "authors.nim", routerSource())
    writeApiFile(dir / "src" / name & ".nim", mainSource(name, auth))
  if auth:
    writeApiFile(
      dir / "src" / "auth.nim", jwtAuthSource(["/api/*"], ["/api/auth/login"])
    )
    writeApiFile(dir / "src" / "routers" / "auth.nim", authRoutesSource())
  if not ssr:
    writeApiFile(dir / "tests" / "test_app.nim", testSource(name))
  writeApiFile(
    dir / "README.md",
    readmeSource(name, if ssr: "SSR + HTMX" else: "JSON API", auth),
  )

proc scaffoldApi*(dir, name: string, auth = false) =
  ## Writes a structured JSON API project into ``dir``.
  scaffoldStructuredProject(dir, name, auth)
