import fastnim

type
  Author = ref object
    id: int
    name: string

  Draft = ref object
    id: int
    name: int

let app = initFastNim(logs = false)
app.post("/authors", body = Draft, responses = @[(201, Author)]):
  created Draft(id: body.id, name: body.name)
