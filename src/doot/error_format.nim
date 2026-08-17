## Error formatting for dev mode output.
## Formats parse errors with file, line, column, code snippet, and suggestion.
## Uses ANSI terminal colors when stdout is a terminal.

import std/[strutils, terminal]

type
  FormattedError* = object
    file*: string
    line*: int
    col*: int
    message*: string
    suggestion*: string
    sourceLine*: string

proc useColors*(): bool =
  ## Returns true if stdout supports color output.
  try:
    result = isatty(stdout)
  except:
    result = false

proc red*(s: string): string =
  ## Wrap string in red ANSI color codes.
  if useColors():
    result = "\e[31m" & s & "\e[0m"
  else:
    result = s

proc yellow*(s: string): string =
  ## Wrap string in yellow ANSI color codes.
  if useColors():
    result = "\e[33m" & s & "\e[0m"
  else:
    result = s

proc bold*(s: string): string =
  ## Wrap string in bold ANSI codes.
  if useColors():
    result = "\e[1m" & s & "\e[0m"
  else:
    result = s

proc cyan*(s: string): string =
  ## Wrap string in cyan ANSI color codes.
  if useColors():
    result = "\e[36m" & s & "\e[0m"
  else:
    result = s

proc green*(s: string): string =
  ## Wrap string in green ANSI color codes.
  if useColors():
    result = "\e[32m" & s & "\e[0m"
  else:
    result = s

proc formatParseError*(file: string, line: int, col: int, message: string,
                       suggestion: string = "", sourceLine: string = ""): string =
  ## Format a parse error for terminal display.
  ## Shows file, line, column, the source line with caret, and optional suggestion.
  result = ""
  result &= red("Error") & " in " & bold(file) & ", line " & $line & ":\n"
  result &= "\n"
  if sourceLine.len > 0:
    result &= "  " & sourceLine & "\n"
    # Add caret pointing to error column
    let caretPos = max(0, col - 1)
    result &= "  " & repeat(' ', caretPos) & red("^") & "\n"
  result &= "  " & message & "\n"
  if suggestion.len > 0:
    result &= "  " & yellow("Did you mean: ") & green(suggestion) & "?\n"

proc formatError*(err: FormattedError): string =
  ## Format a FormattedError object for terminal display.
  result = formatParseError(err.file, err.line, err.col, err.message,
                           err.suggestion, err.sourceLine)

proc formatCompileError*(message: string): string =
  ## Format a compilation error for terminal display.
  result = ""
  result &= red("Compile Error") & ":\n"
  result &= "\n"
  for line in message.splitLines():
    result &= "  " & line & "\n"

proc formatRuntimeError*(message: string, stackTrace: string = ""): string =
  ## Format a runtime error for terminal display.
  result = ""
  result &= red("Runtime Error") & ":\n"
  result &= "\n"
  result &= "  " & message & "\n"
  if stackTrace.len > 0:
    result &= "\n"
    result &= yellow("Stack trace:") & "\n"
    for line in stackTrace.splitLines():
      result &= "  " & line & "\n"

proc formatDevBanner*(port: int): string =
  ## Format the dev server startup banner.
  result = ""
  result &= "\n"
  result &= green("  Doot dev server running") & "\n"
  result &= "\n"
  result &= "  Local: " & cyan("http://localhost:" & $port) & "\n"
  result &= "\n"
  result &= "  Watching for file changes...\n"
  result &= "\n"

proc formatRecompiling*(): string =
  ## Format the recompilation message.
  result = yellow("  Recompiling...") & "\n"

proc formatRecompileSuccess*(timeMs: float): string =
  ## Format a successful recompilation message.
  result = green("  Compiled successfully") & " (" & formatFloat(timeMs, ffDecimal, 0) & "ms)\n"

proc formatRecompileFailure*(): string =
  ## Format a failed recompilation header.
  result = red("  Compilation failed. Waiting for file changes...") & "\n"
