# expect: unknown base model `Missing`
import fastnim/orm
model User = ref Missing:
  name: CharField()
