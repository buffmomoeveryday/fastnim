# expect: overrides inherited field `name` with type int
import fastnim/orm
model Base {.abstract.}:
  name: CharField()
model User = ref Base:
  name: IntegerField()
