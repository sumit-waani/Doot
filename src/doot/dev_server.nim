## Dev server orchestrator for 'doot dev'.
## Manages the compile-restart cycle: parse .do files, detect schema changes,
## generate migrations, and restart the server on file changes.

import std/[os, osproc, times, strutils]
import watcher, error_format
import lexer, parser, ast
import migration_diff, migration_gen, schema_snapshot

type
  DevServerState* = enum
    dsStarting
    dsRunning
    dsRecompiling
    dsError
    dsStopped

  DevServer* = object
    state*: DevServerState
    projectDir*: string
    buildDir*: string
    fileWatcher*: FileWatcher
    serverProcess*: Process
    port*: int
    lastSchemaSnapshot*: seq[TableSnapshot]

proc newDevServer*(projectDir: string, port: int = 3000): DevServer =
  ## Create a new dev server instance for the given project.
  let buildDir = projectDir / ".doot-build"
  let config = newWatcherConfig()
  result = DevServer(
    state: dsStarting,
    projectDir: projectDir,
    buildDir: buildDir,
    fileWatcher: newFileWatcher(projectDir, config),
    serverProcess: nil,
    port: port,
    lastSchemaSnapshot: @[]
  )

proc ensureBuildDir*(server: var DevServer) =
  ## Create the build directory if it doesn't exist.
  if not dirExists(server.buildDir):
    createDir(server.buildDir)

proc parseProject*(server: var DevServer): (DootNode, seq[ParseError]) =
  ## Parse the app.do file and return the AST and any errors.
  let appDoPath = server.projectDir / "app.do"
  if not fileExists(appDoPath):
    let err = ParseError(
      file: appDoPath,
      line: 0,
      col: 0,
      message: "app.do not found in project directory",
      suggestion: "Run 'doot new <name>' to create a new project"
    )
    return (nil, @[err])

  let source = readFile(appDoPath)
  let tokens = tokenize(source, appDoPath)
  let (ast, errors) = parseWithErrors(tokens, appDoPath)
  return (ast, errors)

proc checkSchemaChanges*(server: var DevServer, appAst: DootNode): seq[SchemaChange] =
  ## Check for schema changes by comparing current schema to last snapshot.
  result = @[]
  if appAst == nil or appAst.kind != nkApp:
    return
  if appAst.appSchema == nil:
    return

  let snapshotPath = server.buildDir / "schema_snapshot.json"
  if fileExists(snapshotPath):
    let previous = loadSnapshot(snapshotPath)
    result = diffSchema(appAst.appSchema, previous)

  # Save current schema as new snapshot
  saveSnapshot(appAst.appSchema, snapshotPath)

proc handleSchemaChanges*(server: var DevServer, changes: seq[SchemaChange]) =
  ## Handle detected schema changes: generate migration files.
  if changes.len == 0:
    return

  let migrationsDir = server.projectDir / "migrations"
  if not dirExists(migrationsDir):
    createDir(migrationsDir)

  # Check for destructive changes
  var hasDestructive = false
  for change in changes:
    if change.isDestructive:
      hasDestructive = true
      break

  if hasDestructive:
    echo formatRecompiling()
    echo ""
    echo yellow("  Warning: Destructive schema changes detected!")
    echo "  The following changes may result in data loss:"
    echo ""
    for change in changes:
      if change.isDestructive:
        case change.kind
        of DropTable:
          echo "    - Drop table: " & change.dropTableName
        of DropColumn:
          echo "    - Drop column: " & change.dropColName & " from " & change.dropColTable
        of ChangeColumnType:
          echo "    - Change type of " & change.changeColName & " in " & change.changeColTable
        else:
          discard
    echo ""
    stdout.write "  Apply these changes? [y/N] "
    stdout.flushFile()
    let answer = stdin.readLine()
    if answer.toLowerAscii() notin ["y", "yes"]:
      echo "  Skipping destructive changes."
      return

  # Generate migration file
  let filename = generateMigrationFile(changes, migrationsDir)
  if filename.len > 0:
    echo green("  Generated migration: ") & filename

proc stopServer*(server: var DevServer) =
  ## Stop the running server process if any.
  if server.serverProcess != nil:
    try:
      server.serverProcess.terminate()
      discard server.serverProcess.waitForExit(timeout = 3000)
      server.serverProcess.close()
    except OSError:
      discard
    server.serverProcess = nil

proc displayErrors*(errors: seq[ParseError]) =
  ## Display parse errors in a user-friendly format.
  for err in errors:
    echo formatParseError(err.file, err.line, err.col, err.message, err.suggestion)

proc startDevLoop*(server: var DevServer) =
  ## Start the main dev server loop.
  ## This is the entry point for 'doot dev'.
  server.ensureBuildDir()
  server.fileWatcher.recordBaseline()

  # Initial parse
  let (appAst, errors) = server.parseProject()
  if errors.len > 0:
    server.state = dsError
    displayErrors(errors)
    echo formatRecompileFailure()
  else:
    # Check for schema changes on startup
    if appAst != nil:
      let changes = server.checkSchemaChanges(appAst)
      server.handleSchemaChanges(changes)

    server.state = dsRunning
    echo formatDevBanner(server.port)

  # Main watch loop
  var running = true
  while running:
    sleep(server.fileWatcher.config.pollIntervalMs)

    let changes = server.fileWatcher.detectChanges()
    if server.fileWatcher.shouldTrigger(changes):
      let pending = server.fileWatcher.getPendingChanges()
      if pending.len > 0:
        echo formatRecompiling()
        let startTime = cpuTime()

        # Stop current server
        server.stopServer()

        # Re-parse
        let (newAst, newErrors) = server.parseProject()
        if newErrors.len > 0:
          server.state = dsError
          displayErrors(newErrors)
          echo formatRecompileFailure()
        else:
          # Check schema changes
          if newAst != nil:
            let schemaChanges = server.checkSchemaChanges(newAst)
            server.handleSchemaChanges(schemaChanges)

          let elapsed = (cpuTime() - startTime) * 1000.0
          echo formatRecompileSuccess(elapsed)
          server.state = dsRunning
    elif changes.len == 0 and server.fileWatcher.debouncing:
      # Check if debounce period has passed with no new changes
      discard server.fileWatcher.shouldTrigger(@[])

proc shutdownDevServer*(server: var DevServer) =
  ## Gracefully shut down the dev server.
  server.stopServer()
  server.state = dsStopped
  echo "\n" & green("  Server stopped.") & "\n"
