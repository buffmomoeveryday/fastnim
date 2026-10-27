## SQLite ORM for FastNim applications, with Chronos async APIs.
##
## ```nim
## import fastnim/orm
##
## model User:
##   id: UUIDField(primaryKey: true)
##   name: CharField(maxLength: 50)
##
## proc main() {.async.} =
##   discard await openDatabase("app.sqlite3")
##   await User(name: "Ada").save()
##   echo (await User.objects.filter(name = "Ada").all()).len
## ```

import std/[options, times]
import chronos
import
  fastnim/orm/[uuids, values, fields, sqlite, queryset, dsl, migrations, cli, outcome]
import fastnim/shortcuts
import jsony except toJson
# Generic async procs (`all`, `save`, ...) are instantiated in user modules,
# where Chronos' `await` machinery has to be in scope. Only `Time` is taken
# from std/times because its duration helpers clash with Chronos'.
export options, chronos
export times.Time
export uuids, values, fields, sqlite, queryset, dsl, migrations, cli, outcome
export shortcuts
export jsony except toJson

when isMainModule:
  quit runCli()
