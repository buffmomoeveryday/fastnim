# expect: User has no field `nmae`
import fastnim/orm
model User:
  name: CharField()
discard User.objects.filter(nmae = "x")
