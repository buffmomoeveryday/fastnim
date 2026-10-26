import chronos, fastnim/orm

model Author:
  name: CharField()

model Article:
  author: ForeignKey(Author, onDelete: Cascade)
  title: CharField()

proc run() {.async.} =
  checkNPlusOne:
    for article in await Article.objects.selectRelated("author").all():
      let a = await article.author()
      discard a

waitFor run()
