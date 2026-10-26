# expect: already used by A
import fastnim/orm

model A:
  name: CharField()
  Meta:
    indexes:
      Index(fields: ["name"], name: "shared_idx")

model B:
  name: CharField()
  Meta:
    indexes:
      Index(fields: ["name"], name: "shared_idx")
