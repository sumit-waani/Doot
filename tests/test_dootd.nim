## Comprehensive tests for the dootd production daemon infrastructure.
## Tests password generation, state persistence, systemd file generation,
## and idempotent re-runs.

import std/[unittest, os, strutils, times, random]
import db_connector/db_sqlite
import ../src/doot/dootd_types
import ../src/doot/dootd_state
import ../src/doot/dootd_password
import ../src/doot/dootd_systemd
import ../src/doot/cli

let testBaseDir = getTempDir() / "dootd_test_" & $epochTime().int

var testCounter = 0

proc setupTestDir(): string =
  ## Create a fresh temp directory for a test.
  inc testCounter
  let dir = testBaseDir / $testCounter & "_" & $rand(99999)
  createDir(dir)
  result = dir

proc cleanupTestDir(dir: string) =
  ## Remove a test directory.
  if dirExists(dir):
    removeDir(dir)

randomize()

suite "DootdTypes":
  test "AppStatus enum values":
    check $asRunning == "running"
    check $asStopped == "stopped"
    check $asError == "error"
    check $asDeploying == "deploying"

  test "default constants are set":
    check DefaultDashboardPort == 8080
    check DefaultRouterPort == 80
    check InternalPortStart == 3001
    check MaxApps == 100

  test "AppConfig default initialization":
    var app = AppConfig()
    check app.id == 0
    check app.name == ""
    check app.status == asRunning  # first enum value
    check app.internalPort == 0

  test "DootdConfig default initialization":
    var config = DootdConfig()
    check config.dataDir == ""
    check config.dashboardPort == 0
    check config.routerPort == 0

  test "DootdState default initialization":
    var state = DootdState()
    check state.apps.len == 0
    check state.passwordHash == ""
    check state.initialized == false

suite "DootdState - Database Initialization":
  var testDir: string

  setup:
    testDir = setupTestDir()

  teardown:
    cleanupTestDir(testDir)

  test "initDootdDb creates database file":
    let db = initDootdDb(testDir)
    defer: db.close()
    check fileExists(testDir / "dootd.db")

  test "initDootdDb creates data directory if needed":
    let subDir = testDir / "sub" / "dir"
    let db = initDootdDb(subDir)
    defer: db.close()
    check dirExists(subDir)
    check fileExists(subDir / "dootd.db")

  test "initDootdDb is idempotent":
    let db1 = initDootdDb(testDir)
    db1.close()
    # Second init should not fail or wipe data
    let db2 = initDootdDb(testDir)
    defer: db2.close()
    check fileExists(testDir / "dootd.db")

suite "DootdState - Config CRUD":
  var testDir: string
  var db: DbConn

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "getConfig returns empty for missing key":
    let val = getConfig(db, "nonexistent")
    check val == ""

  test "setConfig and getConfig round-trip":
    setConfig(db, "test_key", "test_value")
    let val = getConfig(db, "test_key")
    check val == "test_value"

  test "setConfig overwrites existing value":
    setConfig(db, "key", "value1")
    setConfig(db, "key", "value2")
    let val = getConfig(db, "key")
    check val == "value2"

  test "deleteConfig removes key":
    setConfig(db, "key", "value")
    deleteConfig(db, "key")
    let val = getConfig(db, "key")
    check val == ""

  test "multiple config keys are independent":
    setConfig(db, "key1", "val1")
    setConfig(db, "key2", "val2")
    check getConfig(db, "key1") == "val1"
    check getConfig(db, "key2") == "val2"

suite "DootdState - App CRUD":
  var testDir: string
  var db: DbConn

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "getApps returns empty initially":
    let apps = getApps(db)
    check apps.len == 0

  test "saveAppConfig inserts new app":
    var app = AppConfig(
      name: "myapp",
      hostname: "myapp.example.com",
      githubUrl: "https://github.com/user/repo",
      pat: "ghp_secret",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      memoryLimit: 512,
      cpuShares: 1024,
      status: asStopped
    )
    let id = saveAppConfig(db, app)
    check id > 0

  test "saveAppConfig and getApps round-trip":
    var app = AppConfig(
      name: "webapp",
      hostname: "webapp.example.com",
      githubUrl: "https://github.com/user/webapp",
      pat: "ghp_token",
      branch: "main",
      envVars: """{"PORT": "3001"}""",
      internalPort: 3001,
      memoryLimit: 256,
      cpuShares: 512,
      status: asStopped
    )
    discard saveAppConfig(db, app)
    let apps = getApps(db)
    check apps.len == 1
    check apps[0].name == "webapp"
    check apps[0].hostname == "webapp.example.com"
    check apps[0].githubUrl == "https://github.com/user/webapp"
    check apps[0].pat == "ghp_token"
    check apps[0].branch == "main"
    check apps[0].internalPort == 3001
    check apps[0].memoryLimit == 256
    check apps[0].cpuShares == 512
    check apps[0].status == asStopped

  test "saveAppConfig updates existing app":
    var app = AppConfig(
      name: "app1",
      hostname: "app1.example.com",
      githubUrl: "https://github.com/user/app1",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      status: asStopped
    )
    let id = saveAppConfig(db, app)
    app.id = id
    app.status = asRunning
    app.memoryLimit = 1024
    discard saveAppConfig(db, app)
    let apps = getApps(db)
    check apps.len == 1
    check apps[0].status == asRunning
    check apps[0].memoryLimit == 1024

  test "deleteApp removes app":
    var app = AppConfig(
      name: "todelete",
      hostname: "delete.example.com",
      githubUrl: "https://github.com/user/del",
      branch: "main",
      envVars: "{}",
      internalPort: 3002,
      status: asStopped
    )
    let id = saveAppConfig(db, app)
    deleteApp(db, id)
    let apps = getApps(db)
    check apps.len == 0

  test "deleteApp also removes app logs":
    var app = AppConfig(
      name: "logapp",
      hostname: "log.example.com",
      githubUrl: "https://github.com/user/log",
      branch: "main",
      envVars: "{}",
      internalPort: 3003,
      status: asRunning
    )
    let id = saveAppConfig(db, app)
    addAppLog(db, id, "stdout", "hello world")
    addAppLog(db, id, "stderr", "error happened")
    deleteApp(db, id)
    let logs = getAppLogs(db, id)
    check logs.len == 0

  test "getApp by id":
    var app = AppConfig(
      name: "findme",
      hostname: "find.example.com",
      githubUrl: "https://github.com/user/find",
      branch: "develop",
      envVars: "{}",
      internalPort: 3004,
      status: asStopped
    )
    let id = saveAppConfig(db, app)
    let found = getApp(db, id)
    check found.name == "findme"
    check found.branch == "develop"

  test "getAppByName":
    var app = AppConfig(
      name: "namedapp",
      hostname: "named.example.com",
      githubUrl: "https://github.com/user/named",
      branch: "main",
      envVars: "{}",
      internalPort: 3005,
      status: asRunning
    )
    discard saveAppConfig(db, app)
    let found = getAppByName(db, "namedapp")
    check found.name == "namedapp"
    check found.status == asRunning

  test "nextInternalPort returns start when no apps":
    let port = nextInternalPort(db)
    check port == InternalPortStart

  test "nextInternalPort increments from max":
    var app = AppConfig(
      name: "portapp",
      hostname: "port.example.com",
      githubUrl: "https://github.com/user/port",
      branch: "main",
      envVars: "{}",
      internalPort: 3005,
      status: asStopped
    )
    discard saveAppConfig(db, app)
    let port = nextInternalPort(db)
    check port == 3006

  test "updateAppStatus changes status":
    var app = AppConfig(
      name: "statusapp",
      hostname: "status.example.com",
      githubUrl: "https://github.com/user/status",
      branch: "main",
      envVars: "{}",
      internalPort: 3006,
      status: asStopped
    )
    let id = saveAppConfig(db, app)
    updateAppStatus(db, id, asRunning)
    let updated = getApp(db, id)
    check updated.status == asRunning

  test "multiple apps are ordered by id":
    for i in 1..3:
      var app = AppConfig(
        name: "app" & $i,
        hostname: "app" & $i & ".example.com",
        githubUrl: "https://github.com/user/app" & $i,
        branch: "main",
        envVars: "{}",
        internalPort: 3000 + i,
        status: asStopped
      )
      discard saveAppConfig(db, app)
    let apps = getApps(db)
    check apps.len == 3
    check apps[0].name == "app1"
    check apps[1].name == "app2"
    check apps[2].name == "app3"

suite "DootdState - App Logs":
  var testDir: string
  var db: DbConn

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "addAppLog and getAppLogs round-trip":
    var app = AppConfig(
      name: "logtest",
      hostname: "log.example.com",
      githubUrl: "https://github.com/user/log",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      status: asRunning
    )
    let id = saveAppConfig(db, app)
    addAppLog(db, id, "stdout", "Server started")
    addAppLog(db, id, "stderr", "Warning: something")
    let logs = getAppLogs(db, id)
    check logs.len == 2
    # Logs are ordered DESC by id, so most recent first
    check logs[0].stream == "stderr"
    check logs[0].message == "Warning: something"
    check logs[1].stream == "stdout"
    check logs[1].message == "Server started"

  test "getAppLogs respects limit":
    var app = AppConfig(
      name: "limitlog",
      hostname: "limit.example.com",
      githubUrl: "https://github.com/user/limit",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      status: asRunning
    )
    let id = saveAppConfig(db, app)
    for i in 1..10:
      addAppLog(db, id, "stdout", "Message " & $i)
    let logs = getAppLogs(db, id, limit = 5)
    check logs.len == 5

suite "DootdState - loadState":
  var testDir: string
  var db: DbConn

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "loadState without password shows not initialized":
    let state = loadState(db)
    check state.initialized == false
    check state.passwordHash == ""

  test "loadState with password shows initialized":
    setConfig(db, "admin_password_hash", "$argon2id$fakehash")
    let state = loadState(db)
    check state.initialized == true
    check state.passwordHash == "$argon2id$fakehash"

  test "loadState includes apps":
    var app = AppConfig(
      name: "stateapp",
      hostname: "state.example.com",
      githubUrl: "https://github.com/user/state",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      status: asRunning
    )
    discard saveAppConfig(db, app)
    let state = loadState(db)
    check state.apps.len == 1
    check state.apps[0].name == "stateapp"

  test "loadState uses default ports when not configured":
    let state = loadState(db)
    check state.config.dashboardPort == DefaultDashboardPort
    check state.config.routerPort == DefaultRouterPort

  test "loadState reads configured ports":
    setConfig(db, "dashboard_port", "9090")
    setConfig(db, "router_port", "8888")
    let state = loadState(db)
    check state.config.dashboardPort == 9090
    check state.config.routerPort == 8888

suite "DootdPassword - Generation":
  test "generateAdminPassword returns correct format":
    let pwd = generateAdminPassword()
    # Format: xxxx-xxxx-xxxx (3 groups of 4 with hyphens)
    let parts = pwd.split('-')
    check parts.len == 3
    for part in parts:
      check part.len == 4

  test "generateAdminPassword total length is 14":
    let pwd = generateAdminPassword()
    # 12 chars + 2 hyphens = 14
    check pwd.len == 14

  test "generateAdminPassword uses only valid characters":
    let validChars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    for i in 0..9:  # Generate multiple to test randomness
      let pwd = generateAdminPassword()
      for c in pwd:
        if c != '-':
          check c in validChars

  test "generateAdminPassword produces different passwords":
    let pwd1 = generateAdminPassword()
    let pwd2 = generateAdminPassword()
    # Extremely unlikely to be equal with 12 random chars
    check pwd1 != pwd2

  test "generateAdminPassword excludes ambiguous characters":
    # Run many times to ensure ambiguous chars never appear
    for i in 0..49:
      let pwd = generateAdminPassword()
      for c in pwd:
        if c != '-':
          check c != 'l'
          check c != 'I'
          check c != '1'
          check c != 'O'
          check c != '0'

suite "DootdPassword - Hash and Verify":
  var testDir: string
  var db: DbConn

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "isPasswordSet returns false initially":
    check isPasswordSet(db) == false

  test "hashAndStorePassword sets password":
    hashAndStorePassword(db, "testpass123")
    check isPasswordSet(db) == true

  test "verifyAdminPassword with correct password":
    hashAndStorePassword(db, "secretpassword")
    check verifyAdminPassword(db, "secretpassword") == true

  test "verifyAdminPassword with wrong password":
    hashAndStorePassword(db, "correctpassword")
    check verifyAdminPassword(db, "wrongpassword") == false

  test "verifyAdminPassword returns false when no password set":
    check verifyAdminPassword(db, "anything") == false

  test "resetPassword changes the password":
    hashAndStorePassword(db, "oldpassword")
    let newPwd = resetPassword(db)
    check newPwd.len == 14  # Format: xxxx-xxxx-xxxx
    check verifyAdminPassword(db, newPwd) == true
    check verifyAdminPassword(db, "oldpassword") == false

  test "hashAndStorePassword stores argon2id hash":
    hashAndStorePassword(db, "mypassword")
    let hash = getConfig(db, "admin_password_hash")
    check hash.startsWith("$argon2id$")

suite "DootdPassword - Idempotent Re-runs":
  var testDir: string

  setup:
    testDir = setupTestDir()

  teardown:
    cleanupTestDir(testDir)

  test "second init does not wipe password":
    let db1 = initDootdDb(testDir)
    hashAndStorePassword(db1, "firstpassword")
    db1.close()

    # Re-init the database
    let db2 = initDootdDb(testDir)
    defer: db2.close()
    check isPasswordSet(db2) == true
    check verifyAdminPassword(db2, "firstpassword") == true

  test "second init does not wipe apps":
    let db1 = initDootdDb(testDir)
    var app = AppConfig(
      name: "persistent",
      hostname: "persist.example.com",
      githubUrl: "https://github.com/user/persist",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      status: asRunning
    )
    discard saveAppConfig(db1, app)
    db1.close()

    # Re-init the database
    let db2 = initDootdDb(testDir)
    defer: db2.close()
    let apps = getApps(db2)
    check apps.len == 1
    check apps[0].name == "persistent"

  test "second init does not wipe config":
    let db1 = initDootdDb(testDir)
    setConfig(db1, "dashboard_port", "9090")
    setConfig(db1, "custom_key", "custom_value")
    db1.close()

    # Re-init the database
    let db2 = initDootdDb(testDir)
    defer: db2.close()
    check getConfig(db2, "dashboard_port") == "9090"
    check getConfig(db2, "custom_key") == "custom_value"

suite "DootdSystemd - Service File Generation":
  test "generateServiceFile contains Unit section":
    let content = generateServiceFile("/usr/local/bin/doot", "/var/lib/dootd")
    check "[Unit]" in content
    check "Description=Doot Production Daemon" in content
    check "After=network.target" in content

  test "generateServiceFile contains Service section":
    let content = generateServiceFile("/usr/local/bin/doot", "/var/lib/dootd")
    check "[Service]" in content
    check "Type=simple" in content
    check "Restart=always" in content
    check "RestartSec=5" in content

  test "generateServiceFile contains correct ExecStart":
    let content = generateServiceFile("/opt/doot/bin/doot", "/opt/doot/data")
    check "ExecStart=/opt/doot/bin/doot --prod" in content

  test "generateServiceFile contains correct WorkingDirectory":
    let content = generateServiceFile("/usr/bin/doot", "/var/lib/dootd")
    check "WorkingDirectory=/var/lib/dootd" in content

  test "generateServiceFile contains Install section":
    let content = generateServiceFile("/usr/bin/doot", "/var/lib/dootd")
    check "[Install]" in content
    check "WantedBy=multi-user.target" in content

  test "generateServiceFile contains PATH environment":
    let content = generateServiceFile("/usr/bin/doot", "/var/lib/dootd")
    check "Environment=PATH=/usr/bin:/bin" in content

  test "serviceFilePath returns correct path":
    check serviceFilePath() == "/etc/systemd/system/dootd.service"

  test "isServiceInstalled returns false in sandbox":
    # In the test sandbox, the service file does not exist
    check isServiceInstalled() == false

  test "installService fails gracefully without root":
    # Should return false since we cannot write to /etc/systemd/system
    let result = installService("/usr/bin/doot", "/var/lib/dootd")
    check result == false

  test "generateServiceFile with custom paths":
    let content = generateServiceFile("/home/user/.nimble/bin/doot", "/home/user/.dootd")
    check "/home/user/.nimble/bin/doot --prod" in content
    check "WorkingDirectory=/home/user/.dootd" in content

suite "CLI --prod Flag Parsing":
  test "parse --prod command":
    let result = parseArgs(@["--prod"])
    check result.command == cmdProd

  test "parse --prod with --reset-password":
    let result = parseArgs(@["--prod", "--reset-password"])
    check result.command == cmdProd
    check "--reset-password" in result.flags

  test "parse --prod with multiple flags":
    let result = parseArgs(@["--prod", "--reset-password", "--verbose"])
    check result.command == cmdProd
    check "--reset-password" in result.flags
    check "--verbose" in result.flags

suite "Integration - Full Init Flow":
  var testDir: string

  setup:
    testDir = setupTestDir()

  teardown:
    cleanupTestDir(testDir)

  test "first run initializes and stores password":
    let db = initDootdDb(testDir)
    defer: db.close()
    check isPasswordSet(db) == false

    let pwd = generateAdminPassword()
    hashAndStorePassword(db, pwd)
    setConfig(db, "data_dir", testDir)
    setConfig(db, "dashboard_port", $DefaultDashboardPort)

    check isPasswordSet(db) == true
    check verifyAdminPassword(db, pwd) == true
    check getConfig(db, "data_dir") == testDir

  test "subsequent run detects initialization":
    let db = initDootdDb(testDir)
    hashAndStorePassword(db, "initialpass")
    setConfig(db, "data_dir", testDir)
    db.close()

    # Simulate second run
    let db2 = initDootdDb(testDir)
    defer: db2.close()
    let state = loadState(db2)
    check state.initialized == true

  test "reset-password works after initial setup":
    let db = initDootdDb(testDir)
    defer: db.close()

    hashAndStorePassword(db, "original")
    check verifyAdminPassword(db, "original") == true

    let newPwd = resetPassword(db)
    check verifyAdminPassword(db, newPwd) == true
    check verifyAdminPassword(db, "original") == false

  test "full state lifecycle":
    let db = initDootdDb(testDir)
    defer: db.close()

    # Initialize
    hashAndStorePassword(db, "admin123")
    setConfig(db, "dashboard_port", "8080")

    # Add an app
    var app = AppConfig(
      name: "blog",
      hostname: "blog.example.com",
      githubUrl: "https://github.com/user/blog",
      pat: "ghp_token",
      branch: "main",
      envVars: """{"DATABASE_URL": "sqlite:blog.db"}""",
      internalPort: 3001,
      memoryLimit: 512,
      cpuShares: 1024,
      status: asStopped
    )
    let appId = saveAppConfig(db, app)

    # Deploy (update status)
    updateAppStatus(db, appId, asDeploying)
    var updated = getApp(db, appId)
    check updated.status == asDeploying

    # Start
    updateAppStatus(db, appId, asRunning)
    addAppLog(db, appId, "stdout", "Listening on port 3001")

    # Verify full state
    let state = loadState(db)
    check state.initialized == true
    check state.apps.len == 1
    check state.apps[0].name == "blog"
    check state.apps[0].status == asRunning
    check state.config.dashboardPort == 8080

    # Check logs
    let logs = getAppLogs(db, appId)
    check logs.len == 1
    check "Listening on port 3001" in logs[0].message
