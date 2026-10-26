# expect: choices cannot be empty
import fastnim/orm
model Item:
  level: IntegerField(choices: [])
