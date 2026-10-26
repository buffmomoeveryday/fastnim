# expect: has no field `missing`
import fastnim/orm

model M:
  name: CharField()
  Meta:
    indexes:
      Index(fields: ["missing"])
