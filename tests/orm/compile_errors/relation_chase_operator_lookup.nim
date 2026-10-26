# expect: comparison operators do not take a `.lookup` suffix
import fastnim/orm

model Author:
  name: CharField()

model Article:
  author: ForeignKey(Author, onDelete: Cascade)
  title: CharField()

discard Article.objects.filter(title.icontains > "Ada")
