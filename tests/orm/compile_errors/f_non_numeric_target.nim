# expect: F() can only assign an IntegerField or FloatField
import fastnim/orm
model Article:
  title:
    CharField()
  views:
    IntegerField()
discard Article.objects.update(title = F(views) + 1)
