## Run with: nim c -r --path:src examples/ratelimit.nim
import chronos
import fastnim
import fastnim/plugins/ratelimit

let app = initFastNim()

app.install:
  rateLimitPlugin initRateLimitOptions(limit = 5, windowSeconds = 60)

app.get("/"):
  "This endpoint allows five requests per minute per x-forwarded-for value."

let server = app.serve(port = 8000)
echo "GET http://127.0.0.1:8000/ repeatedly to receive a 429 response."
waitFor server.join()
