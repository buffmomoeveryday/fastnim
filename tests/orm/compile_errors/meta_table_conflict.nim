# expect: conflicts with
import fastnim/orm

model M {.table: "one".}:
  name: CharField()
  Meta:
    table: "two"
