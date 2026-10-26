# expect: unsupported call
import fastnim/orm
model Article:
  views: IntegerField()
discard Article.objects.update(views = abs(F(views)))
