# expect: reverse name `books` clashes with field Author.books
import fastnim/orm

model Author:
  books:
    CharField()

model Book:
  authors:
    ManyToManyField(Author, relatedName: "books")
