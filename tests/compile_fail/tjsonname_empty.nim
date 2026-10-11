import fastnim

type InvalidModel = object
  displayName {.jsonName: "".}: string

discard json(InvalidModel())
