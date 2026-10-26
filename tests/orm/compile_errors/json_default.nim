# expect: JSONField default is not valid JSON
import fastnim/orm
model Doc:
  payload: JSONField(default: "{")
