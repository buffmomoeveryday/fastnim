import std/[assertions, json, options]

import fastnim

type LoginForm = object
  username: string
  attempts: int
  remember: bool

type ProfileForm = object
  displayName {.jsonName: "display_name".}: string
  age: int
  note: Option[string]

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

block requiresNonOptionalFields:
  var form: LoginForm
  let request = initRequest(
    HttpMethod.Post,
    "/login",
    body = "username=Ada&attempts=2",
  )
  doAssert not parseFormBody(request, form)

block honorsRenamedAndOptionalFields:
  var form: ProfileForm
  let request = initRequest(
    HttpMethod.Post,
    "/profile",
    body = "display_name=Ada&age=36",
  )
  doAssert parseFormBody(request, form)
  doAssert form.displayName == "Ada"
  doAssert form.age == 36
  doAssert form.note.isNone()

block decodesPresentOptionalFields:
  var form: ProfileForm
  let request = initRequest(
    HttpMethod.Post,
    "/profile",
    body = "display_name=Ada&age=36&note=engineer",
  )
  doAssert parseFormBody(request, form)
  doAssert form.note == some("engineer")

block bindsTypedFormsInPostRoutes:
  let app = initFastNim(logs = false)
  app.post("/login", form = LoginForm, responses = @[(200, LoginForm)]):
    respondOk(form)

  let response = app.handleSync(
    initRequest(
      HttpMethod.Post,
      "/login",
      body = "username=Ada&attempts=1&remember=false",
    )
  )
  doAssert response.status == 200
  doAssert response.body == "{\"username\":\"Ada\",\"attempts\":1,\"remember\":false}"

block rejectsMissingRequiredFieldsInTypedRoutes:
  let app = initFastNim(logs = false)
  app.post("/profile", form = ProfileForm, responses = @[(200, ProfileForm)]):
    respondOk(form)

  let missing = app.handleSync(
    initRequest(HttpMethod.Post, "/profile", body = "display_name=Ada")
  )
  doAssert missing.status == 400

  let valid = app.handleSync(
    initRequest(
      HttpMethod.Post,
      "/profile",
      body = "display_name=Ada&age=36",
    )
  )
  doAssert valid.status == 200
  doAssert parseJson(valid.body) ==
    parseJson("""{"display_name":"Ada","age":36,"note":null}""")
