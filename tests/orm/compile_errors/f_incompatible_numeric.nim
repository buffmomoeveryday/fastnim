# expect: cannot assign FloatField
import fastnim/orm
model Article:
  views:
    IntegerField()
  rating:
    FloatField()
discard Article.objects.update(views = F(rating))
