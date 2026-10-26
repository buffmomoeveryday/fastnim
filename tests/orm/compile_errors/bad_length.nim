# expect: minLength (9) is greater than maxLength (5)
import fastnim/orm

model User:
  name: CharField(maxLength: 5, minLength: 9)
