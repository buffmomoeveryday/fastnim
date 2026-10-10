## In-process test client for FastNim applications.
##
## ``TestClient`` drives an application through ``app.handle`` without
## binding a port, FastAPI ``TestClient`` style:
##
## ```nim
## import std/unittest
## import fastnim
## import fastnim/testing
##
## let client = initTestClient(api)
##
## suite "main":
##   test "reads root":
##     let response = client.get("/")
##     check response.status == 200
##     check response.json() == %*{"msg": "Hello World"}
## ```

import std/[json, tables]

import fastnim/context/http
import fastnim/routing/router

type TestClient* = ref object
  ## Drives an application in-process. Create one per test app with
  ## ``initTestClient``; requests never touch the network.
  app*: Application ## Application under test.

proc initTestClient*(app: Application): TestClient =
  ## Creates a client bound to ``app``.
  TestClient(app: app)

proc request*(
    client: TestClient,
    `method`: HttpMethod,
    target: string,
    headers: Headers = initTable[string, string](),
    body = "",
): Response =
  ## Sends one in-process request. ``target`` may include a query string.
  client.app.handle(initRequest(`method`, target, headers, body))

proc get*(
    client: TestClient, target: string, headers: Headers = initTable[string, string]()
): Response =
  ## Sends an in-process GET request.
  client.request(HttpMethod.Get, target, headers)

proc post*(
    client: TestClient,
    target: string,
    body = "",
    headers: Headers = initTable[string, string](),
): Response =
  ## Sends an in-process POST request with an optional raw ``body``.
  client.request(HttpMethod.Post, target, headers, body)

proc put*(
    client: TestClient,
    target: string,
    body = "",
    headers: Headers = initTable[string, string](),
): Response =
  ## Sends an in-process PUT request with an optional raw ``body``.
  client.request(HttpMethod.Put, target, headers, body)

proc patch*(
    client: TestClient,
    target: string,
    body = "",
    headers: Headers = initTable[string, string](),
): Response =
  ## Sends an in-process PATCH request with an optional raw ``body``.
  client.request(HttpMethod.Patch, target, headers, body)

proc delete*(
    client: TestClient, target: string, headers: Headers = initTable[string, string]()
): Response =
  ## Sends an in-process DELETE request.
  client.request(HttpMethod.Delete, target, headers)

proc query*(
    client: TestClient, target: string, headers: Headers = initTable[string, string]()
): Response =
  ## Sends an in-process QUERY request.
  client.request(HttpMethod.Query, target, headers)

proc json*(response: Response): JsonNode =
  ## Parses a test response body as JSON. Raises on invalid JSON.
  parseJson(response.body)
