# expect: uniqueTogether needs at least two fields
import fastnim/orm

model M:
  name: CharField()
  Meta:
    uniqueTogether: ["name"]
