# expect: duplicate field `name`
import fastnim/orm
model User:
  name:
    CharField()
discard User.objects.only(name, name)
