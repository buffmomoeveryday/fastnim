import std/[assertions, json]

import fastnim

type ApiError = object
  detail: string

let app = initFastNim(logs = false)

app.delete(
  "/users/{id}",
  responses = @[(204, void), (404, ApiError)],
  tags = @["users"],
  summary = "Delete a user",
  description = "Deletes a user by ID.",
  operationId = "deleteUser",
):
  if request.pathParam("id") == "1":
    noContent void
  else:
    notFound ApiError(detail: "User not found")

block deletesWithNoContent:
  let response = app.handleSync(initRequest(HttpMethod.Delete, "/users/1"))
  doAssert response.status == 204
  doAssert response.body.len == 0

block documentsNoContent:
  let operation = app.openApiDocument()["paths"]["/users/{id}"]["delete"]
  doAssert operation["tags"][0].getStr == "users"
  doAssert operation["responses"]["204"]["description"].getStr == "Response 204"
  doAssert not operation["responses"]["204"].hasKey("content")
