import fastnim

block createsTextResponses:
  let response = text("hello")
  doAssert response.status == 200
  doAssert response.body == "hello"
