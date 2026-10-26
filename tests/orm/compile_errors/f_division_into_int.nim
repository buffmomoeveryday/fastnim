# expect: division produces a float
import fastnim/orm
model Article:
  views:
    IntegerField()
discard Article.objects.update(views = F(views) / 2)
