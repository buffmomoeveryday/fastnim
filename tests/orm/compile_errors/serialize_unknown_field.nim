# expect: has no field `missing`
import fastnim/orm

model User:
  name:
    CharField()

proc main() =
  echo User(name: "A").omit(missing).serialize()
