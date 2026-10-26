# expect: unknown field type `StringField`
import fastnim/orm
model User:
  name:
    StringField()
