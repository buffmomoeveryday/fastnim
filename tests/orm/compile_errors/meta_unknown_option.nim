# expect: unknown Meta option
import fastnim/orm

model M:
  name:
    CharField()
  Meta:
    verboseName:
      "M"
