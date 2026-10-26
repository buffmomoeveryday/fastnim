# expect: unknown model `Nope`
import fastnim/orm

typeFrom(CreateUser, Nope.ignore(id))
