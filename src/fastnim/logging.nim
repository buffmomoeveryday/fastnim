## Per-application logging configuration for fastnim.

import std/[logging, syncio, terminal]

type
  LogHandler* = proc(level: Level, message: string) {.closure, gcsafe, raises: [].}
    ## Receives a fastnim log event. Handlers must be safe to call from a
    ## Chronos asynchronous server callback.

  ApplicationSettings* = object ## Settings that control application-level logging.
    logs*: bool ## Enables framework request and error logs.
    logHandler*: LogHandler ## Destination for log events, console by default.
    logLevel*: Level ## Minimum level recorded by the default handler.

proc nimLogHandler*(logger: Logger): LogHandler =
  ## Adapts a standard-library Nim ``Logger`` for use by an application.
  ##
  ## The logger is used directly; it is not registered as a global handler.
  result = proc(level: Level, message: string) {.gcsafe, raises: [].} =
    try:
      {.cast(gcsafe).}:
        logger.log(level, message)
    except:
      discard

proc logColor(level: Level): ForegroundColor =
  case level
  of lvlWarn: fgYellow
  of lvlError, lvlFatal: fgRed
  of lvlDebug: fgCyan
  else: fgGreen

proc colorConsoleLogHandler*(levelThreshold = lvlInfo): LogHandler =
  ## Creates a colorized console handler for application logs.
  result = proc(level: Level, message: string) {.gcsafe, raises: [].} =
    if level < levelThreshold:
      return
    try:
      {.cast(gcsafe).}:
        stdout.write(ansiForegroundColorCode(logColor(level), bright = true))
        stdout.write(LevelNames[level] & " " & message)
        stdout.write(ansiResetCode & "\n")
        stdout.flushFile()
    except:
      discard

proc initApplicationSettings*(
    logs = true, logHandler: LogHandler = nil, logLevel = lvlInfo
): ApplicationSettings =
  ## Creates application settings. Set ``logs`` to ``false`` to disable all
  ## fastnim logging, including a supplied handler.
  ApplicationSettings(logs: logs, logHandler: logHandler, logLevel: logLevel)
