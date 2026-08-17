## CLI argument parser and command dispatcher.
## Parses command-line arguments and dispatches to the appropriate handler.

import std/os
import db_connector/db_sqlite
import scaffold, dev_server, error_format
import dootd_types, dootd_state, dootd_password, dootd_systemd

type
  CliCommand* = enum
    cmdNew
    cmdDev
    cmdHelp
    cmdProd
    cmdUnknown

  CliArgs* = object
    command*: CliCommand
    args*: seq[string]
    flags*: seq[string]

proc parseArgs*(args: seq[string]): CliArgs =
  ## Parse command-line arguments into a structured CliArgs object.
  ## args should be the parameters after the program name (commandLineParams()).
  result = CliArgs(command: cmdHelp, args: @[], flags: @[])

  if args.len == 0:
    result.command = cmdHelp
    return

  let first = args[0]

  case first
  of "new":
    result.command = cmdNew
    if args.len > 1:
      result.args = args[1..^1]
  of "dev":
    result.command = cmdDev
    if args.len > 1:
      result.args = args[1..^1]
  of "help", "--help", "-h":
    result.command = cmdHelp
    if args.len > 1:
      result.args = args[1..^1]
  of "--prod":
    result.command = cmdProd
    if args.len > 1:
      result.flags = args[1..^1]
  else:
    result.command = cmdUnknown
    result.args = args

proc showHelp*(): string =
  ## Generate the help output string.
  result = """Doot - DSL for web applications

Usage:
  doot <command> [options]

Commands:
  new <name>    Create a new Doot project
  dev           Start development server with file watching
  help          Show this help message

Production:
  --prod        Start in production daemon mode

Run 'doot help <command>' for details on a specific command."""

proc showNewHelp*(): string =
  ## Generate help output for the 'new' command.
  result = """doot new <name>

  Create a new Doot project with the given name.

  The project name must contain only letters, numbers, and hyphens.
  It cannot start or end with a hyphen.

Usage:
  doot new my-app

Generated structure:
  my-app/
    app.do              Entry point: schema, config
    views/layouts/      Template layouts
    static/             Static assets
    migrations/         Generated migrations
    .env                Environment variables
    .gitignore          Git ignore rules"""

proc showDevHelp*(): string =
  ## Generate help output for the 'dev' command.
  result = """doot dev

  Start the development server with file watching.

  Watches all .do files, views, and .env for changes.
  On change: full recompile and server restart.

Usage:
  doot dev

  The server will be available at http://localhost:3000"""

proc runNew*(args: seq[string]): int =
  ## Execute the 'doot new' command.
  ## Returns exit code.
  if args.len == 0:
    echo red("Error: ") & "Missing project name."
    echo ""
    echo "Usage: doot new <name>"
    return 2

  let name = args[0]
  let err = scaffoldProject(name)
  if err.message.len > 0:
    echo red("Error: ") & err.message
    return 2

  printWelcomeMessage(name)
  return 0

## gDevServer holds a pointer to the stack-allocated DevServer in runDev.
## It is only valid while runDev is on the call stack. The SIGINT handler
## calls quit(0) after shutdown, so the pointer never outlives the frame.
var gDevServer: ptr DevServer = nil

proc handleSigint() {.noconv.} =
  ## SIGINT handler for graceful shutdown of the dev server.
  if gDevServer != nil:
    gDevServer[].shutdownDevServer()
  quit(0)

proc runDev*(args: seq[string]): int =
  ## Execute the 'doot dev' command.
  ## Returns exit code.
  let projectDir = getCurrentDir()

  # Check if app.do exists
  if not fileExists(projectDir / "app.do"):
    echo red("Error: ") & "No app.do found in current directory."
    echo ""
    echo "  Make sure you are in a Doot project directory."
    echo "  Run 'doot new <name>' to create a new project."
    return 1

  var server = newDevServer(projectDir)
  gDevServer = addr server

  # Set up SIGINT handler for graceful shutdown
  setControlCHook(handleSigint)

  server.startDevLoop()
  gDevServer = nil
  return 0

proc runProd*(flags: seq[string]): int =
  ## Execute the 'doot --prod' command.
  ## Initializes the daemon on first run, shows status on subsequent runs.
  ## Handles --reset-password flag for password recovery.
  let dataDir = dootd_state.getDataDir()
  let db = initDootdDb(dataDir)
  defer: db.close()

  let resetPwd = "--reset-password" in flags

  if resetPwd:
    let newPwd = resetPassword(db)
    echo "Admin password has been reset."
    echo ""
    echo "New admin password: " & newPwd
    echo ""
    echo "Store this password securely. It will not be shown again."
    return 0

  let alreadyInitialized = isPasswordSet(db)

  if not alreadyInitialized:
    # First run: generate password and set up
    let password = generateAdminPassword()
    hashAndStorePassword(db, password)

    # Store config
    let binPath = getAppFilename()
    setConfig(db, "data_dir", dataDir)
    setConfig(db, "binary_path", binPath)
    setConfig(db, "dashboard_port", $DefaultDashboardPort)
    setConfig(db, "router_port", $DefaultRouterPort)

    echo "Doot Production Daemon initialized."
    echo ""
    echo "Admin password: " & password
    echo ""
    echo "Store this password securely. It will not be shown again."
    echo "Use --reset-password if you need to generate a new one."
    echo ""
    echo "Dashboard: http://localhost:" & $DefaultDashboardPort
    echo "Data directory: " & dataDir
    echo ""

    # Try to install systemd service (will fail gracefully in sandboxes)
    let installed = installService(binPath, dataDir)
    if installed:
      echo "Systemd service installed and started."
    else:
      echo "Note: Could not install systemd service (requires root)."
      echo "Service file content generated for manual installation."
    return 0
  else:
    # Already initialized: show status
    let state = loadState(db)
    echo "Doot Production Daemon is configured."
    echo ""
    echo "Dashboard: http://localhost:" & $state.config.dashboardPort
    echo "Data directory: " & dataDir
    echo "Managed apps: " & $state.apps.len
    echo ""
    echo "Use --reset-password to generate a new admin password."
    return 0

proc dispatch*(cliArgs: CliArgs): int =
  ## Dispatch to the appropriate command handler.
  ## Returns the process exit code.
  case cliArgs.command
  of cmdNew:
    return runNew(cliArgs.args)
  of cmdDev:
    return runDev(cliArgs.args)
  of cmdHelp:
    if cliArgs.args.len > 0:
      case cliArgs.args[0]
      of "new":
        echo showNewHelp()
      of "dev":
        echo showDevHelp()
      else:
        echo showHelp()
    else:
      echo showHelp()
    return 0
  of cmdProd:
    return runProd(cliArgs.flags)
  of cmdUnknown:
    let cmd = if cliArgs.args.len > 0: cliArgs.args[0] else: ""
    echo red("Error: ") & "Unknown command '" & cmd & "'."
    echo ""
    echo showHelp()
    return 2
