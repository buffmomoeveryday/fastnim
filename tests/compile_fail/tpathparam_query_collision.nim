import fastnim

type SearchQuery = object
  value: string

let app = initFastNim()
app.get(
  "/items/{queryParams:int}", queryParams = SearchQuery, responses = @[(200, void)]
):
  ok void
