# expect: unknown ManyToManyField option `null`
import fastnim/orm

model Author:
  name:
    CharField()

model Book:
  authors:
    ManyToManyField(Author, null: true)
