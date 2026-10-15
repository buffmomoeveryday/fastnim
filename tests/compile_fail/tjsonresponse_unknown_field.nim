import fastnim

type Message = object
  status: string

discard Message(status: "ok").ignore(Message.missing)
