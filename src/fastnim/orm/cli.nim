## Command line interface.
##
## `makemigrations` needs your models compiled in, and `migrate` applies the
## migrations compiled into this program. Import the models and, after the
## first `makemigrations`, the generated `migrations/all` module:
##
## ```nim
## import fastnim/orm
## import myapp/models
## import myapp/migrations/all
## when isMainModule: runCli()
## ```

import std/[parseopt, os, options, strutils]
import chronos
import ./[fields, sqlite, migrations]

const usage = """
Usage: fastorm <command> [options]

Commands:
  makemigrations   Write a Nim migration for model changes
  migrate          Apply pending migrations compiled into this program
  showmigrations   List compiled migrations and whether they are applied
  sqlmigrate NAME  Print the SQL of a compiled migration

Options:
  --db:PATH        SQLite database (default: db.sqlite3, or $FASTORM_DB)
  --dir:PATH       Migrations directory (default: migrations)
  --name:NAME      Name for the new migration (makemigrations)
  --empty          Write an empty migration to edit by hand (makemigrations)
"""

proc runCli*(args: seq[string] = commandLineParams()): int =
  ## Runs a fastorm command and returns the process exit code.
  var command, target, name: string
  var dbPath = getEnv("FASTORM_DB", "db.sqlite3")
  var dir = "migrations"
  var empty = false
  var p = initOptParser(args)
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if command.len == 0:
        command = key
      else:
        target = key
    of cmdLongOption, cmdShortOption:
      case key
      of "db":
        dbPath = val
      of "dir":
        dir = val
      of "name":
        name = val
      of "empty":
        empty = true
      of "help", "h":
        echo usage
        return 0
      else:
        stderr.writeLine "unknown option --" & key
        return 2
    of cmdEnd:
      discard
  try:
    case command
    of "makemigrations":
      if registeredModels().len == 0 and not empty:
        stderr.writeLine "no models are registered. Run makemigrations from a program " &
          "that imports your models and calls runCli()."
        return 1
      let path = makeMigrations(dir, name, empty)
      if path.isSome:
        echo "Created ", path.get
      else:
        echo "No changes detected"
    of "migrate":
      let db = waitFor openDatabase(dbPath, setDefault = false)
      let applied = waitFor db.migrate(dir)
      waitFor db.close()
      if applied.len == 0:
        echo "No migrations to apply"
      for m in applied:
        echo "Applied ", m
    of "showmigrations":
      let db = waitFor openDatabase(dbPath, setDefault = false)
      let statuses = waitFor db.showMigrations(dir)
      waitFor db.close()
      for s in statuses:
        echo (if s.applied: "[X] " else: "[ ] "), s.name
    of "sqlmigrate":
      if target.len == 0:
        stderr.writeLine "sqlmigrate needs a migration name"
        return 2
      for m in loadMigrations(dir):
        if m.name == target or m.name.startsWith(target & "_"):
          for sql in sqlFor(m):
            echo sql, ";"
          return 0
      stderr.writeLine "no migration named " & target
      return 1
    of "":
      echo usage
      return 2
    else:
      stderr.writeLine "unknown command " & command & "\n" & usage
      return 2
  except CatchableError as e:
    stderr.writeLine "error: " & e.msg
    return 1
  0
