# expect: only() and defer() cannot be combined with selectRelated
import fastnim/orm
model Author:
  name:
    CharField()
model Book:
  author:
    ForeignKey(Author)
  title:
    CharField()
discard Book.objects.only(title).expand(author)
