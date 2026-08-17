## Comprehensive tests for the CLI module, scaffold, watcher, and error formatting.

import std/[unittest, os, strutils, tables]
import ../src/doot/cli
import ../src/doot/scaffold
import ../src/doot/watcher
import ../src/doot/error_format

suite "Project Name Validation":
  test "valid simple name":
    check isValidProjectName("myapp") == true

  test "valid name with hyphens":
    check isValidProjectName("my-app") == true

  test "valid name with numbers":
    check isValidProjectName("app123") == true

  test "valid alphanumeric with hyphens":
    check isValidProjectName("my-app-2") == true

  test "valid single character":
    check isValidProjectName("a") == true

  test "invalid empty name":
    check isValidProjectName("") == false

  test "invalid name with spaces":
    check isValidProjectName("my app") == false

  test "invalid name with underscore":
    check isValidProjectName("my_app") == false

  test "invalid name with special chars":
    check isValidProjectName("my@app") == false

  test "invalid name with dots":
    check isValidProjectName("my.app") == false

  test "invalid leading hyphen":
    check isValidProjectName("-myapp") == false

  test "invalid trailing hyphen":
    check isValidProjectName("myapp-") == false

  test "invalid name with slash":
    check isValidProjectName("my/app") == false

  test "invalid name with bang":
    check isValidProjectName("app!") == false

suite "Scaffold File Generation":
  test "app.do has config block with port 3000":
    let content = generateAppDo()
    check "port 3000" in content
    check "config do" in content
    check "end" in content

  test "app.do has schema block":
    let content = generateAppDo()
    check "schema do" in content

  test "app.do has session_secret env reference":
    let content = generateAppDo()
    check "session_secret" in content
    check "SESSION_SECRET" in content

  test "base layout has doctype html":
    let content = generateBaseLayout()
    check "doctype html" in content

  test "base layout has html structure":
    let content = generateBaseLayout()
    check "html" in content
    check "head" in content
    check "body" in content

  test "base layout has block content":
    let content = generateBaseLayout()
    check "block content" in content

  test "base layout has title":
    let content = generateBaseLayout()
    check "title" in content

  test "app.css is valid CSS":
    let content = generateAppCss()
    check "body" in content
    check "{" in content
    check "}" in content

  test "session secret is 64 hex chars":
    let secret = generateSessionSecret()
    check secret.len == 64
    for c in secret:
      check c in {'0'..'9', 'a'..'f'}

  test "env file contains SESSION_SECRET":
    let secret = generateSessionSecret()
    let content = generateEnvFile(secret)
    check "SESSION_SECRET=" in content
    check secret in content

  test "env example has placeholder":
    let content = generateEnvExample()
    check "SESSION_SECRET=" in content
    check "your_secret_here" in content

  test "gitignore contains .env":
    let content = generateGitignore()
    check ".env" in content

  test "gitignore contains .doot-build/":
    let content = generateGitignore()
    check ".doot-build/" in content

  test "gitignore contains uploads/":
    let content = generateGitignore()
    check "uploads/" in content

  test "gitignore contains *.db":
    let content = generateGitignore()
    check "*.db" in content

suite "Scaffold Project Creation":
  setup:
    let testDir = "test-scaffold-proj"
    if dirExists(testDir):
      removeDir(testDir)

  teardown:
    let testDir = "test-scaffold-proj"
    if dirExists(testDir):
      removeDir(testDir)

  test "creates project directory":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check dirExists("test-scaffold-proj")

  test "creates app.do file":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check fileExists("test-scaffold-proj/app.do")

  test "creates views/layouts/base.do":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check fileExists("test-scaffold-proj/views/layouts/base.do")

  test "creates static/app.css":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check fileExists("test-scaffold-proj/static/app.css")

  test "creates migrations directory":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check dirExists("test-scaffold-proj/migrations")

  test "creates uploads directory":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check dirExists("test-scaffold-proj/uploads")

  test "creates .env file with secret":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check fileExists("test-scaffold-proj/.env")
    let content = readFile("test-scaffold-proj/.env")
    check "SESSION_SECRET=" in content
    # Secret should be 64 hex chars
    let lines = content.splitLines()
    for line in lines:
      if line.startsWith("SESSION_SECRET="):
        let secret = line.split("=")[1]
        check secret.len == 64

  test "creates .env.example":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check fileExists("test-scaffold-proj/.env.example")

  test "creates .gitignore":
    let err = scaffoldProject("test-scaffold-proj")
    check err.message == ""
    check fileExists("test-scaffold-proj/.gitignore")
    let content = readFile("test-scaffold-proj/.gitignore")
    check ".env" in content
    check ".doot-build/" in content
    check "uploads/" in content
    check "*.db" in content

  test "rejects invalid project name":
    let err = scaffoldProject("bad name")
    check err.message.len > 0
    check not dirExists("bad name")

  test "rejects existing directory":
    createDir("test-scaffold-proj")
    let err = scaffoldProject("test-scaffold-proj")
    check err.message.len > 0
    check "already exists" in err.message

suite "CLI Argument Parsing":
  test "no args shows help":
    let result = parseArgs(@[])
    check result.command == cmdHelp

  test "parse 'new' command":
    let result = parseArgs(@["new", "myapp"])
    check result.command == cmdNew
    check result.args == @["myapp"]

  test "parse 'new' without name":
    let result = parseArgs(@["new"])
    check result.command == cmdNew
    check result.args.len == 0

  test "parse 'dev' command":
    let result = parseArgs(@["dev"])
    check result.command == cmdDev

  test "parse 'help' command":
    let result = parseArgs(@["help"])
    check result.command == cmdHelp

  test "parse '--help' flag":
    let result = parseArgs(@["--help"])
    check result.command == cmdHelp

  test "parse '-h' flag":
    let result = parseArgs(@["-h"])
    check result.command == cmdHelp

  test "parse '--prod' flag":
    let result = parseArgs(@["--prod"])
    check result.command == cmdProd

  test "parse unknown command":
    let result = parseArgs(@["unknown"])
    check result.command == cmdUnknown
    check result.args == @["unknown"]

  test "parse 'help new' for subcommand help":
    let result = parseArgs(@["help", "new"])
    check result.command == cmdHelp
    check result.args == @["new"]

suite "Help Output":
  test "help contains 'new' command":
    let output = showHelp()
    check "new" in output
    check "Create a new Doot project" in output

  test "help contains 'dev' command":
    let output = showHelp()
    check "dev" in output
    check "Start development server" in output

  test "help contains 'help' command":
    let output = showHelp()
    check "help" in output
    check "Show this help message" in output

  test "help contains usage":
    let output = showHelp()
    check "Usage:" in output
    check "doot <command> [options]" in output

  test "help contains production section":
    let output = showHelp()
    check "--prod" in output
    check "production" in output.toLowerAscii()

  test "help contains description":
    let output = showHelp()
    check "Doot - DSL for web applications" in output

  test "new help shows usage":
    let output = showNewHelp()
    check "doot new" in output
    check "my-app" in output

  test "dev help shows usage":
    let output = showDevHelp()
    check "doot dev" in output
    check "localhost:3000" in output

suite "File Watcher":
  setup:
    let watchDir = "test_watch_dir"
    if dirExists(watchDir):
      removeDir(watchDir)
    createDir(watchDir)

  teardown:
    let watchDir = "test_watch_dir"
    if dirExists(watchDir):
      removeDir(watchDir)

  test "create watcher with default config":
    let config = newWatcherConfig()
    check config.pollIntervalMs == 500
    check config.debounceMs == 150
    check ".do" in config.watchPatterns
    check ".env" in config.watchPaths

  test "create watcher with custom config":
    let config = newWatcherConfig(pollIntervalMs = 200, debounceMs = 100)
    check config.pollIntervalMs == 200
    check config.debounceMs == 100

  test "excludes correct directories":
    let config = newWatcherConfig()
    check ".git" in config.excludeDirs
    check ".doot-build" in config.excludeDirs
    check "migrations" in config.excludeDirs
    check "uploads" in config.excludeDirs
    check "static" notin config.excludeDirs

  test "scan finds .do files":
    writeFile("test_watch_dir/app.do", "test content")
    var w = newFileWatcher("test_watch_dir")
    let files = w.scanFiles()
    check files.len == 1
    check "app.do" in files[0]

  test "scan finds .env file":
    writeFile("test_watch_dir/.env", "SECRET=test")
    var w = newFileWatcher("test_watch_dir")
    let files = w.scanFiles()
    check files.len == 1
    check ".env" in files[0]

  test "scan ignores non-watched files":
    writeFile("test_watch_dir/readme.txt", "test")
    var w = newFileWatcher("test_watch_dir")
    let files = w.scanFiles()
    check files.len == 0

  test "scan finds nested .do files":
    createDir("test_watch_dir/views")
    writeFile("test_watch_dir/views/home.do", "test")
    var w = newFileWatcher("test_watch_dir")
    let files = w.scanFiles()
    check files.len == 1
    check "home.do" in files[0]

  test "scan excludes .git directory":
    createDir("test_watch_dir/.git")
    writeFile("test_watch_dir/.git/config.do", "test")
    var w = newFileWatcher("test_watch_dir")
    let files = w.scanFiles()
    check files.len == 0

  test "scan watches static directory":
    createDir("test_watch_dir/static")
    writeFile("test_watch_dir/static/app.css", "body { }")
    var w = newFileWatcher("test_watch_dir")
    let files = w.scanFiles()
    check files.len == 1
    check "app.css" in files[0]

  test "record baseline stores mtimes":
    writeFile("test_watch_dir/app.do", "content")
    var w = newFileWatcher("test_watch_dir")
    w.recordBaseline()
    check w.mtimes.len == 1

  test "detect new file":
    var w = newFileWatcher("test_watch_dir")
    w.recordBaseline()
    writeFile("test_watch_dir/new.do", "new content")
    let changes = w.detectChanges()
    check changes.len == 1
    check changes[0].kind == fckCreated

  test "detect modified file":
    writeFile("test_watch_dir/app.do", "original")
    var w = newFileWatcher("test_watch_dir")
    w.recordBaseline()
    # Ensure mtime changes - sleep briefly
    sleep(50)
    writeFile("test_watch_dir/app.do", "modified content")
    let changes = w.detectChanges()
    check changes.len == 1
    check changes[0].kind == fckModified

  test "detect deleted file":
    writeFile("test_watch_dir/app.do", "content")
    var w = newFileWatcher("test_watch_dir")
    w.recordBaseline()
    removeFile("test_watch_dir/app.do")
    let changes = w.detectChanges()
    check changes.len == 1
    check changes[0].kind == fckDeleted

  test "no changes when nothing changed":
    writeFile("test_watch_dir/app.do", "content")
    var w = newFileWatcher("test_watch_dir")
    w.recordBaseline()
    let changes = w.detectChanges()
    check changes.len == 0

  test "debounce prevents immediate trigger":
    var w = newFileWatcher("test_watch_dir")
    let changes = @[FileChange(path: "test.do", kind: fckModified)]
    let shouldFire = w.shouldTrigger(changes)
    check shouldFire == false
    check w.debouncing == true

  test "debounce triggers after delay":
    var w = newFileWatcher("test_watch_dir", newWatcherConfig(debounceMs = 10))
    let changes = @[FileChange(path: "test.do", kind: fckModified)]
    discard w.shouldTrigger(changes)
    sleep(20)
    let shouldFire = w.shouldTrigger(@[])
    check shouldFire == true
    check w.debouncing == false

suite "Error Formatting":
  test "format parse error with file and line":
    let output = formatParseError("app.do", 5, 10, "Unexpected token")
    check "app.do" in output
    check "line 5" in output
    check "Unexpected token" in output

  test "format parse error with source line and caret":
    let output = formatParseError("app.do", 3, 5, "Unknown keyword",
                                  sourceLine = "    routr \"/posts\" do")
    check "routr" in output
    check "Unknown keyword" in output

  test "format parse error with suggestion":
    let output = formatParseError("posts.do", 12, 5, "Unknown field",
                                  suggestion = "title")
    check "Did you mean" in output
    check "title" in output

  test "format compile error":
    let output = formatCompileError("undeclared identifier: 'foo'")
    check "Compile Error" in output
    check "undeclared identifier" in output

  test "format runtime error":
    let output = formatRuntimeError("Index out of bounds", "at line 42")
    check "Runtime Error" in output
    check "Index out of bounds" in output
    check "line 42" in output

  test "format dev banner":
    let output = formatDevBanner(3000)
    check "localhost:3000" in output

  test "format recompiling message":
    let output = formatRecompiling()
    check "Recompiling" in output

  test "format recompile failure":
    let output = formatRecompileFailure()
    check "failed" in output.toLowerAscii()
