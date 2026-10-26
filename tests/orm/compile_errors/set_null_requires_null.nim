# expect: onDelete: SetNull) requires null: true
import fastnim/orm
model User:
  name: CharField()
model Book:
  owner: ForeignKey(User, onDelete: SetNull)
