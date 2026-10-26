# expect: F(title) needs an IntegerField or FloatField
import fastnim/orm
model Article:
  title: CharField()
  views: IntegerField()
discard Article.objects.update(views = F(title) + 1)
