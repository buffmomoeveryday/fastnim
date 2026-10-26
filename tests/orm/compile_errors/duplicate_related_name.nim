# expect: clashes with relation User.books
import fastnim/orm

model User:
  name: CharField()

model Book:
  writer: ForeignKey(User)
  editor: ForeignKey(User)
