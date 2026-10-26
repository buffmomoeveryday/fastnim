# expect: Article has no relation `missing`
import fastnim/orm
model Author:
  name:
    CharField()
model Article:
  author:
    ForeignKey(Author)
  title:
    CharField()
discard Article.objects.expand(missing)
