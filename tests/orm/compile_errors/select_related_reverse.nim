# expect: is a reverse relation
import fastnim/orm

model User:
  name: CharField()

model Book:
  user: ForeignKey(User, relatedName: "books")

discard User.objects.selectRelated("books")
