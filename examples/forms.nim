## Run with: nim c -r --path:src examples/forms.nim
import chronos
import fastnim

type
  LoginForm = object
    username: string
    password: string
    remember: bool

  LoginResult = object
    username: string
    remembered: bool

let app = initFastNim()

app.post("/login", form = LoginForm, responses = @[(200, LoginResult)]):
  respondOk(LoginResult(username: form.username, remembered: form.remember))

let server = app.serve(port = 8000)
echo "POST form fields to http://127.0.0.1:8000/login"
waitFor server.join()
