# expect: clashes with field User.books
import fastnim/orm

model User:
  books:
    CharField()

model Novel:
  owner:
    ForeignKey(User, relatedName: "books")
