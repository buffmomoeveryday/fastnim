import std/assertions

import fastnim/middleware/builtin

block exposesBuiltInMiddleware:
  let middleware = responseTime()
  doAssert not middleware.isNil
