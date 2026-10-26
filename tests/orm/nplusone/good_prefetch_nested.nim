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
    for author in await Author.objects.prefetchRelated("articles.chapters").all():
      for article in await author.articles():
        for chapter in await article.chapters():
          discard chapter.title

waitFor run()
