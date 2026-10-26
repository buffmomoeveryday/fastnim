# expect: Article has no foreign key `title`
import fastnim/orm

model Author:
  name: CharField()

model Article:
  author: ForeignKey(Author, onDelete: Cascade)
  title: CharField()

discard Article.objects.filter(title.icontains.extra = "Ada")
