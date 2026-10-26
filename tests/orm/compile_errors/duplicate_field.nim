# expect: field `name` is declared twice
import fastnim/orm

model User:
  name: CharField()
  name: TextField()
