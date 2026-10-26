# expect: `article.chapters()` inside a loop may run one query per row
import chronos, fastnim/orm

model Author:
  name:
    CharField()

model Article:
  author:
    ForeignKey(Author, onDelete: Cascade)
  title:
    CharField()

model Chapter:
  article:
    ForeignKey(Article, onDelete: Cascade, relatedName: "chapters")
  title:
    CharField()

proc run() {.async.} =
  checkNPlusOne:
    for article in await Article.objects.all():
      for chapter in await article.chapters():
        discard chapter.title

waitFor run()
