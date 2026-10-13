import fastnim

type InvalidModel = object
  quantity {.email.}: int

discard validateModel(InvalidModel(quantity: 1))
