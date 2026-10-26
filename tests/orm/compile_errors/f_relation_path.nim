# expect: F() cannot reach through a relation
import fastnim/orm
model Author:
  views:
    IntegerField()
model Book:
  author:
    ForeignKey(Author)
  views:
    IntegerField()
discard Book.objects.update(views = F(author.views) + 1)
