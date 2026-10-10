## JSON API project scaffolding for ``fastnim init``.
##
## Generates a small versioned API: typed models, an exported users router
## with list/get/create/delete routes, an in-process test suite, and docs.

import std/os

proc writeApiFile(path, content: string) =
  createDir(path.parentDir())
  writeFile(path, content)

proc apiNimble(name: string): string =
  """# Package

version = "0.1.0"
author = "you"
description = """" & name & """ - FastNim JSON API"
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

  ApiError* = object
    ## Error payload returned with 4xx statuses.
    detail*: string
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
    notFound ApiError(detail: "user not found")
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
    notFound ApiError(detail: "user not found")
  else:
    {.gcsafe.}:
      store.del(ix)
    noContent void
"""

proc apiMain(name: string): string =
  """## """ & name & """ - FastNim JSON API.
##
## Run with: nim c -r --path:src src/main.nim
## Interactive docs at http://127.0.0.1:8000/docs once running.

import chronos

import fastnim
import routes/users

let api = initFastNim()
api.addRouter(userRouter, prefix = "/v1")

let server = api.serve(port = 8000)
echo "Listening at http://127.0.0.1:8000"
waitFor server.join()
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
    check response.json() == %*{"detail": "user not found"}

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

proc apiReadme(name: string): string =
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

proc scaffoldApi*(dir, name: string) =
  ## Writes a JSON API project into ``dir``.
  ##
  ## ``dir`` should be the empty project root; ``name`` is the project and
  ## Nimble package name.
  writeApiFile(dir / name & ".nimble", apiNimble(name))
  writeApiFile(dir / "config.nims", "switch(\"path\", \"src\")\n")
  writeApiFile(dir / "src" / "main.nim", apiMain(name))
  writeApiFile(dir / "src" / "models.nim", apiModels())
  writeApiFile(dir / "src" / "routes" / "users.nim", apiUsersRoutes())
  writeApiFile(dir / "tests" / "test_users.nim", apiTests())
  writeApiFile(dir / "README.md", apiReadme(name))
