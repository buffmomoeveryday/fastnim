# expect: each choice must be a literal
import fastnim/orm
model Item:
  level: IntegerField(choices: ["nope"])
