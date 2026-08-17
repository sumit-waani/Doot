## Doot DSL Compiler
## Main entry point for the doot binary.
## Dispatches CLI commands: new, dev, help.

import std/os
import doot/cli

proc main() =
  let args = commandLineParams()
  let cliArgs = parseArgs(args)
  let exitCode = dispatch(cliArgs)
  quit(exitCode)

when isMainModule:
  main()
