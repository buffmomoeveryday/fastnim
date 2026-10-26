# expect: update cannot change the primary key
import fastnim/orm
model Article:
  views: IntegerField()
discard Article.objects.update(id = F(id) + 1)
