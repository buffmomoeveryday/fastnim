# expect: has no field `missing`
import fastnim/orm

model User:
  name:
    CharField()

typeFrom(CreateUser, User.ignore(missing))
