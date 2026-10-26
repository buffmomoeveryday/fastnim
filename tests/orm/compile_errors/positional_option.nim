# expect: field options must be named
import fastnim/orm
model User:
  name:
    CharField(50)
