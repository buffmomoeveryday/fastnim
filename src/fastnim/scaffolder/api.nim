## JSON API project scaffolding for ``fastnim init``.
##
## Generates a small versioned API: typed models, an exported users router
## with list/get/create/delete routes, an in-process test suite, and docs.

import std/os

import ./auth

proc writeApiFile(path, content: string) =
  createDir(path.parentDir())
  writeFile(path, content)

proc apiNimble(name: string): string =
  """# Package

version = "0.1.0"
author = "you"
description = """" & name &
    """ - FastNim JSON API"
license = "MIT"
srcDir = "src"

# Dependencies

requires "nim >= 2.2.12"
requires "chronos >= 4.0.0"
# Install fastnim from its repository until it is published on nimble.
requires "fastnim >= 0.1.0"
"""

proc apiModels(): string =
  """## Shared request/response models.

type
  CreateUser* = object
    ## Fields accepted when creating a user.
    name*: string
    email*: string

  User* = object
    ## A stored user.
    id*: int
    name*: string
    email*: string
"""

proc apiUsersRoutes(): string =
  """## Users API. Mounted by main.nim at /v1/users.
##
## The in-memory `store` below is demo state so the scaffold runs without a
## database. Swap it for a pool behind `ctx` (see `app.onLoad`) as the app grows.

import std/[json, strutils]

import fastnim
import ../models

let userRouter* = initRouter(prefix = "/users", tags = @["users"])

var store = @[User(id: 1, name: "Ada Lovelace", email: "ada@example.com")]

proc findUser(id: int): int =
  for i, user in store:
    if user.id == id:
      return i
  -1

userRouter.get("/", responses = @[(200, seq[User])]):
  ok store

userRouter.get("/{id}", responses = @[(200, User), (404, ApiError)]):
  let id =
    try:
      parseInt(request.pathParam("id"))
    except ValueError:
      -1
  let ix = findUser(id)
  if ix < 0:
    notFound initApiError("user_not_found", "user not found")
  else:
    ok store[ix]

userRouter.post("/", body = CreateUser, responses = @[(201, User)]):
  let user = User(id: store.len + 1, name: body.name, email: body.email)
  {.gcsafe.}:
    store.add(user)
  created user

userRouter.delete("/{id}", responses = @[(204, void), (404, ApiError)]):
  let id =
    try:
      parseInt(request.pathParam("id"))
    except ValueError:
      -1
  let ix = findUser(id)
  if ix < 0:
    notFound initApiError("user_not_found", "user not found")
  else:
    {.gcsafe.}:
      store.del(ix)
    noContent void
"""

proc apiMain(name: string, auth: bool): string =
  let authImports = if auth: "import auth\nimport routes/auth as auth_routes\n" else: ""
  let authSetup =
    if auth:
      "api.installPlugin(authentication())\napi.addRouter(auth_routes.authRouter, prefix = \"/v1\")\n"
    else:
      ""
  """## """ & name & """ - FastNim JSON API.
##
## Run with: nim c -r --path:src src/main.nim
## Interactive docs at http://127.0.0.1:8000/docs once running.

import chronos

import fastnim
""" & authImports & """
import routes/users

let api = initFastNim()
""" & authSetup & """
api.addRouter(userRouter, prefix = "/v1")

let server = api.serve(port = 8000)
echo "Listening at http://127.0.0.1:8000"
waitFor server.join()
"""

proc apiAuthRoutes(): string =
  """## Public endpoint that exchanges credentials for a bearer JWT.

import std/json

import fastnim
import ../auth

let authRouter* = initRouter(prefix = "/auth", tags = @["auth"])

authRouter.post(
  "/login", body = LoginInput, responses = @[(200, TokenOutput), (401, ApiError)]
):
  if not credentialsValid(body):
    unauthorized initApiError("invalid_credentials", "invalid credentials")
  else:
    ok issueToken(body.username)

authRouter.get("/me"):
  ok %*{"user": request.authSubject(), "scheme": request.authScheme()}
"""

proc apiTests(): string =
  """import std/[json, strutils, unittest]

import fastnim
import fastnim/testing
import routes/users

let api = initFastNim(logs = false)
api.addRouter(userRouter)

let client = initTestClient(api)

suite "users":
  test "lists users":
    let response = client.get("/users/")
    check response.status == 200
    check "Ada Lovelace" in response.body

  test "gets a missing user":
    let response = client.get("/users/999")
    check response.status == 404
    check response.json() == %*{
      "code": "user_not_found", "message": "user not found", "fields": {}
    }

  test "creates a user":
    let response = client.post(
      "/users/", "{\"name\":\"Grace\",\"email\":\"g@example.com\"}"
    )
    check response.status == 201
    check response.json() ==
      %*{"id": 2, "name": "Grace", "email": "g@example.com"}

  test "deletes a user":
    let deleted = client.delete("/users/1")
    check deleted.status == 204
    check client.get("/users/1").status == 404
"""

proc apiReadme(name: string, auth: bool): string =
  let authDocs =
    if auth:
      """
## Authentication

`/v1/*` uses HS256 bearer JWT authentication. The generated development
account is `ada` / `s3cret`; replace it and set `JWT_SECRET` before deploying.

```sh
TOKEN=$(curl -s -X POST http://127.0.0.1:8000/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"ada","password":"s3cret"}' | jq -r .token)
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8000/v1/users/
```
"""
    else:
      ""
  """# """ & name & "\n" & """

FastNim JSON API with versioned routes (`/v1/users`).

## Run

```sh
nim c -r --path:src src/main.nim
```

- API: http://127.0.0.1:8000/v1/users
- Docs: http://127.0.0.1:8000/docs

```sh
curl http://127.0.0.1:8000/v1/users/
curl -X POST http://127.0.0.1:8000/v1/users/ \
  -d '{"name":"Grace","email":"g@example.com"}'
```
""" & authDocs & """

## Test

```sh
nimble test
```

## Grow

- New domain? Copy `src/routes/users.nim` to `src/routes/items.nim`,
  export its router, and mount it in `src/main.nim`.
- New version? Mount the same routers under `prefix = "/v2"`.
- Real database? Replace the in-memory `store` with a pool opened in
  `api.onLoad` and exposed through `ctx`.
"""

proc scaffoldApi*(dir, name: string, auth = false) =
  ## Writes a JSON API project into ``dir``.
  ##
  ## ``dir`` should be the empty project root; ``name`` is the project and
  ## Nimble package name.
  writeApiFile(dir / name & ".nimble", apiNimble(name))
  writeApiFile(dir / "config.nims", "switch(\"path\", \"src\")\n")
  writeApiFile(dir / "src" / "main.nim", apiMain(name, auth))
  writeApiFile(dir / "src" / "models.nim", apiModels())
  writeApiFile(dir / "src" / "routes" / "users.nim", apiUsersRoutes())
  if auth:
    writeApiFile(dir / "src" / "auth.nim", jwtAuthSource(["/v1/*"], ["/v1/auth/login"]))
    writeApiFile(dir / "src" / "routes" / "auth.nim", apiAuthRoutes())
  writeApiFile(dir / "tests" / "test_users.nim", apiTests())
  writeApiFile(dir / "README.md", apiReadme(name, auth))
