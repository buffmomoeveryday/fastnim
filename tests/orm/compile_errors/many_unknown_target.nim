# expect: ManyToManyField target `Missing` must be declared with `model` before Book
import fastnim/orm

model Book:
  authors:
    ManyToManyField(Missing)
