# expect: declares more than one primary key
import fastnim/orm
model User:
  a: UUIDField(primaryKey: true)
  b: IntegerField(primaryKey: true)
