# expect: `article.author()` inside a loop may run one query per row
import chronos, fastnim/orm

model Author:
  name:
    CharField()

model Article:
  author:
    ForeignKey(Author, onDelete: Cascade)
  title:
    CharField()

proc run() {.async.} =
  checkNPlusOne:
    for article in await Article.objects.all():
      let a = await article.author()
      discard a

waitFor run()
