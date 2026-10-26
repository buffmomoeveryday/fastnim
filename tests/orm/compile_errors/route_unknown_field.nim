# expect: has no field `missing`
import fastnim
import fastnim/orm

model Note:
  title:
    CharField()

let app = initFastNim(logs = false)
app.post("/notes", body = Note.ignore(missing), responses = @[(201, Note)]):
  discard body.title
