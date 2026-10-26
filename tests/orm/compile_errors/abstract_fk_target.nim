# expect: ForeignKey cannot target abstract model Base
import fastnim/orm

model Base {.abstract.}:
  name: CharField()

model Book:
  owner: ForeignKey(Base)
