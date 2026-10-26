# expect: choices are only valid on
import fastnim/orm
model Event:
  day:
    DateField(choices: ["2020-01-01"])
