import std/assertions

import fastnim

type LoginForm = object
  username: string
  attempts: int
  remember: bool

block decodesUrlEncodedFields:
  var form: LoginForm
  let request = initRequest(
    HttpMethod.Post,
    "/login",
    body = "username=Ada+Lovelace&attempts=2&remember=true",
  )
  doAssert parseFormBody(request, form)
  doAssert form.username == "Ada Lovelace"
  doAssert form.attempts == 2
  doAssert form.remember

block rejectsInvalidTypedFields:
  var form: LoginForm
  let request = initRequest(HttpMethod.Post, "/login", body = "attempts=two")
  doAssert not parseFormBody(request, form)

block bindsTypedFormsInPostRoutes:
  let app = initFastNim(logs = false)
  app.post("/login", form = LoginForm, responses = @[(200, LoginForm)]):
    respondOk(form)

  let response = app.handle(
    initRequest(
      HttpMethod.Post,
      "/login",
      body = "username=Ada&attempts=1&remember=false",
    )
  )
  doAssert response.status == 200
  doAssert response.body == "{\"username\":\"Ada\",\"attempts\":1,\"remember\":false}"
