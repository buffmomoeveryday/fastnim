# expect: unsupported operator
import fastnim/orm
model Article:
  views: IntegerField()
discard Article.objects.update(views = F(views) and 1)
