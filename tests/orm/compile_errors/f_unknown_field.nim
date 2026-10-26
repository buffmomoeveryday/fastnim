# expect: Article has no field `vews`
import fastnim/orm
model Article:
  views:
    IntegerField()
discard Article.objects.update(vews = F(views) + 1)
