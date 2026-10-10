## Application-scoped values and lifecycle hooks.

import std/tables

type
  ContextValue = ref object of RootObj

  ContextValueBox[T] = ref object of ContextValue
    value: T

  Context* = ref object ## Values shared by an application and its request handlers.
    values: Table[string, ContextValue]

  LifecycleHook* = proc(context: Context) {.nimcall.}
    ## Runs once when the application loads or unloads.

proc newContext*(): Context =
  ## Creates an empty application context.
  Context(values: initTable[string, ContextValue]())

proc setContext*[T](context: Context, name: string, value: sink T) =
  ## Stores a typed application dependency under ``name``.
  context.values[name] = ContextValueBox[T](value: value)

proc get*[T](context: Context, name: string): T =
  ## Returns a required dependency with its original type.
  ##
  ## Raises ``KeyError`` when ``name`` is missing and ``ValueError`` when the
  ## value was registered with a different type.
  if name notin context.values:
    raise newException(KeyError, "context value not found: " & name)
  let value = context.values[name]
  if not (value of ContextValueBox[T]):
    raise newException(ValueError, "context value has unexpected type: " & name)
  ContextValueBox[T](value).value

proc get*[T](context: Context, name: string, _: typedesc[T]): T {.inline.} =
  ## Returns a required dependency using ``context.get(name, Type)`` syntax.
  get[T](context, name)

proc has*(context: Context, name: string): bool {.inline.} =
  ## Returns whether a named dependency has been registered.
  name in context.values
