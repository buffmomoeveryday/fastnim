# expect: lookup `icontains` needs a CharField or TextField
import fastnim/orm
model User:
  age: IntegerField()
discard User.objects.filter(age.icontains = "1")
