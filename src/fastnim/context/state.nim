## Application-scoped values and lifecycle hooks.

import std/tables

type
  Context* = ref object ## Values shared by an application and its request handlers.
    db*: RootRef ## Shortcut for the dependency stored under ``"db"``.
    values: Table[string, RootRef]

  LifecycleHook* = proc(context: Context) {.nimcall.}
    ## Runs once when the application loads or unloads.

proc newContext*(): Context =
  ## Creates an empty application context.
  Context(values: initTable[string, RootRef]())

proc setContext*[T: RootRef](context: Context, name: string, value: T) =
  ## Stores a reference-typed dependency under ``name``.
  context.values[name] = value

  if name == "db":
    context.db = value

proc get*[T: RootRef](context: Context, name: string): T =
  ## Returns a required reference-typed dependency.
  if name notin context.values:
    raise newException(KeyError, "context value not found: " & name)
  cast[T](context.values[name])

proc has*(context: Context, name: string): bool {.inline.} =
  ## Returns whether a named dependency has been registered.
  name in context.values
