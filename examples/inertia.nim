import std/json

import chronos

import fastnim
import fastnim/plugins/inertia

let app = initFastNim()
app.install:
  inertiaPlugin(initInertiaOptions(version = "1"))

app.get("/"):
  inertia("Home", %*{"message": "Hello from FastNim"})

let server = app.serve()
waitFor server.join()
