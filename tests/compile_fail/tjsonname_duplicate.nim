import fastnim

type InvalidModel = object
  displayName {.jsonName: "name".}: string
  name: string

discard json(InvalidModel())
