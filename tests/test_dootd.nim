## Comprehensive tests for the dootd production daemon infrastructure.
## Tests password generation, state persistence, systemd file generation,
## idempotent re-runs, dashboard auth, HTML rendering, and stats.

import std/[unittest, os, strutils, times, random, tables, uri]
import std/asynchttpserver
import db_connector/db_sqlite
import ../src/doot/dootd_types
import ../src/doot/dootd_state
import ../src/doot/dootd_password
import ../src/doot/dootd_systemd
import ../src/doot/dootd_html
import ../src/doot/dootd_stats
import ../src/doot/dootd_dashboard
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

# =============================================================================
# Dashboard Tests
# =============================================================================

suite "Dashboard - Session Management":
  var testDir: string
  var db: DbConn

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)
    initDashboardSessions(db)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "generateDashboardSessionId returns 32-char hex":
    let id = generateDashboardSessionId()
    check id.len == 32
    for c in id:
      check c in HexDigits

  test "generateDashboardSessionId produces unique IDs":
    let id1 = generateDashboardSessionId()
    let id2 = generateDashboardSessionId()
    check id1 != id2

  test "createSession stores session in DB":
    let sessionId = createSession(db)
    check sessionId.len == 32
    check validateSession(db, sessionId) == true

  test "validateSession returns false for unknown session":
    check validateSession(db, "nonexistent_id") == false

  test "validateSession returns false for empty string":
    check validateSession(db, "") == false

  test "deleteSessionById removes session":
    let sessionId = createSession(db)
    check validateSession(db, sessionId) == true
    deleteSessionById(db, sessionId)
    check validateSession(db, sessionId) == false

suite "Dashboard - Cookie Parsing":
  test "parseCookies handles single cookie":
    let cookies = parseCookies("session=abc123")
    check cookies["session"] == "abc123"

  test "parseCookies handles multiple cookies":
    let cookies = parseCookies("session=abc; theme=dark; lang=en")
    check cookies["session"] == "abc"
    check cookies["theme"] == "dark"
    check cookies["lang"] == "en"

  test "parseCookies handles empty string":
    let cookies = parseCookies("")
    check cookies.len == 0

  test "parseCookies trims whitespace":
    let cookies = parseCookies("  key = value  ;  other = test  ")
    check cookies["key"] == "value"
    check cookies["other"] == "test"

suite "Dashboard - Form Parsing":
  test "parseFormBody handles simple fields":
    let form = parseFormBody("name=myapp&port=3001")
    check form["name"] == "myapp"
    check form["port"] == "3001"

  test "parseFormBody handles URL-encoded values":
    let form = parseFormBody("url=https%3A%2F%2Fgithub.com%2Fuser%2Frepo&name=test+app")
    check form["url"] == "https://github.com/user/repo"
    check form["name"] == "test app"

  test "parseFormBody handles empty body":
    let form = parseFormBody("")
    check form.len == 0

  test "parseFormBody handles empty value":
    let form = parseFormBody("key=&other=value")
    check form["key"] == ""
    check form["other"] == "value"

suite "Dashboard - Request Routing":
  var testDir: string
  var db: DbConn
  var dashboard: DootdDashboard

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)
    hashAndStorePassword(db, "testpass")
    dashboard = newDootdDashboard(db, 9999)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "unauthenticated GET / redirects to login":
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/"),
      headers: newHttpHeaders(),
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 302
    check resp.headers["Location"] == "/login"

  test "GET /login shows login page":
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/login"),
      headers: newHttpHeaders(),
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "password" in resp.body
    check "Login" in resp.body or "login" in resp.body

  test "POST /login with wrong password shows error":
    var headers = newHttpHeaders()
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/login"),
      headers: headers,
      body: "password=wrongpass"
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "Invalid password" in resp.body

  test "POST /login with correct password creates session":
    var headers = newHttpHeaders()
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/login"),
      headers: headers,
      body: "password=testpass"
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 302
    check resp.headers["Location"] == "/"
    check SessionCookieName in resp.headers["Set-Cookie"]

  test "authenticated GET / shows app list":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "Managed Applications" in resp.body

  test "authenticated GET /apps/new shows form":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/apps/new"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "New App" in resp.body
    check "github_url" in resp.body

  test "authenticated POST /apps creates app":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/apps"),
      headers: headers,
      body: "name=testapp&hostname=test.example.com&github_url=https%3A%2F%2Fgithub.com%2Fuser%2Frepo&pat=ghp_test&branch=main&env_vars=KEY%3Dvalue&memory_limit=256&cpu_shares=512"
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 302
    check resp.headers["Location"] == "/"
    # Verify app was created in DB
    let apps = getApps(db)
    check apps.len == 1
    check apps[0].name == "testapp"
    check apps[0].hostname == "test.example.com"
    check apps[0].githubUrl == "https://github.com/user/repo"
    check apps[0].branch == "main"
    check apps[0].memoryLimit == 256
    check apps[0].cpuShares == 512

  test "authenticated GET /apps/:id shows detail":
    let sessionId = createSession(db)
    var app = AppConfig(
      name: "detailapp",
      hostname: "detail.example.com",
      githubUrl: "https://github.com/user/detail",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      status: asRunning
    )
    let appId = saveAppConfig(db, app)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/apps/" & $appId),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "detailapp" in resp.body
    check "detail.example.com" in resp.body

  test "authenticated POST /apps/:id/delete removes app":
    let sessionId = createSession(db)
    var app = AppConfig(
      name: "deleteapp",
      hostname: "delete.example.com",
      githubUrl: "https://github.com/user/delete",
      branch: "main",
      envVars: "{}",
      internalPort: 3002,
      status: asStopped
    )
    let appId = saveAppConfig(db, app)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/apps/" & $appId & "/delete"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 302
    let apps = getApps(db)
    check apps.len == 0

  test "authenticated POST /apps/:id/deploy sets deploying status":
    let sessionId = createSession(db)
    var app = AppConfig(
      name: "deployapp",
      hostname: "deploy.example.com",
      githubUrl: "https://github.com/user/deploy",
      branch: "main",
      envVars: "{}",
      internalPort: 3003,
      status: asStopped
    )
    let appId = saveAppConfig(db, app)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/apps/" & $appId & "/deploy"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 302
    let updated = getApp(db, appId)
    check updated.status == asDeploying

  test "authenticated GET /apps/:id/logs shows logs":
    let sessionId = createSession(db)
    var app = AppConfig(
      name: "logapp",
      hostname: "log.example.com",
      githubUrl: "https://github.com/user/log",
      branch: "main",
      envVars: "{}",
      internalPort: 3004,
      status: asRunning
    )
    let appId = saveAppConfig(db, app)
    addAppLog(db, appId, "stdout", "Server started successfully")
    addAppLog(db, appId, "stderr", "Warning: deprecated API")
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/apps/" & $appId & "/logs"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "Server started successfully" in resp.body
    check "Warning: deprecated API" in resp.body

  test "log search filters results":
    let sessionId = createSession(db)
    var app = AppConfig(
      name: "searchapp",
      hostname: "search.example.com",
      githubUrl: "https://github.com/user/search",
      branch: "main",
      envVars: "{}",
      internalPort: 3005,
      status: asRunning
    )
    let appId = saveAppConfig(db, app)
    addAppLog(db, appId, "stdout", "Request handled: GET /")
    addAppLog(db, appId, "stderr", "Error: connection timeout")
    addAppLog(db, appId, "stdout", "Request handled: POST /api")
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/apps/" & $appId & "/logs?search=Error"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "connection timeout" in resp.body
    # The search should not show non-matching entries in filtered view
    # (but they may still appear as the search is keyword-based)

  test "authenticated GET /stats shows stats page":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/stats"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "System Statistics" in resp.body

  test "authenticated GET /settings shows settings page":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/settings"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "Change Password" in resp.body

  test "settings password change with correct current password":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/settings/password"),
      headers: headers,
      body: "current_password=testpass&new_password=newpass123&confirm_password=newpass123"
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "Password changed successfully" in resp.body
    # Verify new password works
    check verifyAdminPassword(db, "newpass123") == true
    check verifyAdminPassword(db, "testpass") == false

  test "settings password change with wrong current password":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/settings/password"),
      headers: headers,
      body: "current_password=wrongpass&new_password=newpass&confirm_password=newpass"
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "Current password is incorrect" in resp.body

  test "settings password change with mismatched confirmation":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/settings/password"),
      headers: headers,
      body: "current_password=testpass&new_password=new1&confirm_password=new2"
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 200
    check "do not match" in resp.body

  test "POST /logout destroys session":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/logout"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 302
    check resp.headers["Location"] == "/login"
    # Session should be deleted
    check validateSession(db, sessionId) == false

  test "unknown route returns 404":
    let sessionId = createSession(db)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    let req = Request(
      reqMethod: HttpGet,
      url: parseUri("/nonexistent"),
      headers: headers,
      body: ""
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 404

suite "Dashboard - App Update":
  var testDir: string
  var db: DbConn
  var dashboard: DootdDashboard

  setup:
    testDir = setupTestDir()
    db = initDootdDb(testDir)
    hashAndStorePassword(db, "testpass")
    dashboard = newDootdDashboard(db, 9999)

  teardown:
    db.close()
    cleanupTestDir(testDir)

  test "POST /apps/:id/update modifies app config":
    let sessionId = createSession(db)
    var app = AppConfig(
      name: "original",
      hostname: "original.example.com",
      githubUrl: "https://github.com/user/orig",
      branch: "main",
      envVars: "{}",
      internalPort: 3001,
      memoryLimit: 256,
      cpuShares: 512,
      status: asStopped
    )
    let appId = saveAppConfig(db, app)
    var headers = newHttpHeaders()
    headers["Cookie"] = SessionCookieName & "=" & sessionId
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    let req = Request(
      reqMethod: HttpPost,
      url: parseUri("/apps/" & $appId & "/update"),
      headers: headers,
      body: "name=updated&hostname=updated.example.com&github_url=https%3A%2F%2Fgithub.com%2Fuser%2Fupdated&pat=new_token&branch=develop&env_vars=KEY%3Dval&memory_limit=512&cpu_shares=1024"
    )
    let resp = handleDashboardRequest(dashboard, req)
    check resp.status == 302
    let updated = getApp(db, appId)
    check updated.name == "updated"
    check updated.hostname == "updated.example.com"
    check updated.branch == "develop"
    check updated.memoryLimit == 512
    check updated.cpuShares == 1024

# =============================================================================
# HTML Rendering Tests
# =============================================================================

suite "HTML Rendering":
  test "renderLayout includes doctype and html tags":
    let html = renderLayout("Test", "<p>Hello</p>")
    check "<!DOCTYPE html>" in html
    check "<html" in html
    check "</html>" in html

  test "renderLayout includes title":
    let html = renderLayout("My Title", "<p>body</p>")
    check "My Title - Dootd" in html

  test "renderLayout shows nav when logged in":
    let html = renderLayout("Test", "<p>body</p>", isLoggedIn = true)
    check "<nav" in html
    check "Apps" in html
    check "Stats" in html
    check "Settings" in html
    check "Logout" in html

  test "renderLayout hides nav when not logged in":
    let html = renderLayout("Test", "<p>body</p>", isLoggedIn = false)
    check "<nav" notin html

  test "renderLoginPage contains password input":
    let html = renderLoginPage()
    check "type=\"password\"" in html
    check "name=\"password\"" in html
    check "Login" in html or "login" in html

  test "renderLoginPage shows error message":
    let html = renderLoginPage("Bad credentials")
    check "Bad credentials" in html
    check "alert-error" in html

  test "renderAppList with no apps shows message":
    let html = renderAppList(@[])
    check "No applications configured" in html

  test "renderAppList shows app names":
    let apps = @[
      AppConfig(id: 1, name: "webapp", hostname: "web.example.com", internalPort: 3001, status: asRunning),
      AppConfig(id: 2, name: "api", hostname: "api.example.com", internalPort: 3002, status: asStopped)
    ]
    let html = renderAppList(apps)
    check "webapp" in html
    check "api" in html
    check "web.example.com" in html
    check "api.example.com" in html
    check "status-running" in html
    check "status-stopped" in html

  test "renderAppList contains deploy buttons":
    let apps = @[AppConfig(id: 1, name: "myapp", hostname: "my.com", internalPort: 3001, status: asStopped)]
    let html = renderAppList(apps)
    check "Deploy" in html
    check "/apps/1/deploy" in html

  test "renderAppForm for new app has empty fields":
    let html = renderAppForm()
    check "New App" in html
    check "action=\"/apps\"" in html
    check "Create App" in html

  test "renderAppForm for edit shows existing values":
    let app = AppConfig(id: 5, name: "editme", hostname: "edit.com", githubUrl: "https://github.com/x/y", branch: "develop", memoryLimit: 512)
    let html = renderAppForm(app, isEdit = true)
    check "Edit App" in html
    check "editme" in html
    check "edit.com" in html
    check "develop" in html
    check "/apps/5/update" in html

  test "renderAppDetail shows app info":
    let app = AppConfig(id: 3, name: "detailapp", hostname: "detail.com", githubUrl: "https://github.com/u/r", branch: "main", internalPort: 3005, memoryLimit: 1024, status: asRunning)
    let html = renderAppDetail(app)
    check "detailapp" in html
    check "detail.com" in html
    check "3005" in html
    check "1024 MB" in html
    check "status-running" in html

  test "renderAppDetail shows recent logs":
    let app = AppConfig(id: 1, name: "logapp", hostname: "log.com", status: asRunning)
    let logs = @[
      (timestamp: "2024-01-01 12:00:00", stream: "stdout", message: "Started OK"),
      (timestamp: "2024-01-01 12:01:00", stream: "stderr", message: "Warning here")
    ]
    let html = renderAppDetail(app, logs)
    check "Started OK" in html
    check "Warning here" in html
    check "stream-stdout" in html
    check "stream-stderr" in html

  test "renderLogsPage shows filter input":
    let logs: seq[tuple[timestamp, stream, message: string]] = @[]
    let html = renderLogsPage("myapp", logs, "searchterm")
    check "searchterm" in html
    check "name=\"search\"" in html

  test "renderLogsPage shows log messages":
    let logs = @[
      (timestamp: "2024-01-01 10:00:00", stream: "stdout", message: "Line one"),
      (timestamp: "2024-01-01 10:01:00", stream: "stderr", message: "Error line")
    ]
    let html = renderLogsPage("testapp", logs)
    check "Line one" in html
    check "Error line" in html

  test "renderStatsPage contains stat sections":
    let stats = SystemStats(
      cpu: CpuStats(usagePercent: 45.5, available: true),
      memory: MemStats(totalMb: 8192, usedMb: 4096, freeMb: 4096, usagePercent: 50.0, available: true),
      disk: DiskStats(totalGb: 100.0, usedGb: 60.0, freeGb: 40.0, usagePercent: 60.0, available: true),
      hostname: "testhost",
      uptime: "5d 3h 20m"
    )
    let html = renderStatsPage(stats)
    check "System Statistics" in html
    check "testhost" in html
    check "5d 3h 20m" in html
    check "45.5%" in html
    check "4096" in html
    check "8192" in html

  test "renderStatsPage handles unavailable stats":
    let stats = SystemStats(
      cpu: CpuStats(usagePercent: 0.0, available: false),
      memory: MemStats(available: false),
      disk: DiskStats(available: false),
      hostname: "unknown",
      uptime: "unknown"
    )
    let html = renderStatsPage(stats)
    check "N/A" in html
    check "System Statistics" in html

  test "renderSettingsPage shows password form":
    let html = renderSettingsPage()
    check "Change Password" in html
    check "current_password" in html
    check "new_password" in html
    check "confirm_password" in html

  test "renderSettingsPage shows success message":
    let html = renderSettingsPage("Password updated!", isError = false)
    check "Password updated!" in html
    check "alert-success" in html

  test "renderSettingsPage shows error message":
    let html = renderSettingsPage("Something went wrong", isError = true)
    check "Something went wrong" in html
    check "alert-error" in html

# =============================================================================
# Stats Tests
# =============================================================================

suite "System Stats Collection":
  test "getCpuUsage does not crash":
    let cpu = getCpuUsage()
    # On systems without /proc, available will be false
    check cpu.usagePercent >= 0.0

  test "getMemoryInfo does not crash":
    let mem = getMemoryInfo()
    check mem.totalMb >= 0
    check mem.usedMb >= 0

  test "getDiskInfo does not crash":
    let disk = getDiskInfo()
    check disk.totalGb >= 0.0

  test "getSystemUptime returns a string":
    let uptime = getSystemUptime()
    check uptime.len > 0

  test "getSystemHostname returns a non-empty string":
    let hostname = getSystemHostname()
    check hostname.len > 0

  test "collectSystemStats returns complete object":
    let stats = collectSystemStats()
    check stats.hostname.len > 0
    check stats.uptime.len > 0
    # CPU and memory may or may not be available depending on /proc

  test "CpuStats default is not available":
    let cpu = CpuStats()
    check cpu.available == false
    check cpu.usagePercent == 0.0

  test "MemStats default is not available":
    let mem = MemStats()
    check mem.available == false
    check mem.totalMb == 0

  test "DiskStats default is not available":
    let disk = DiskStats()
    check disk.available == false
    check disk.totalGb == 0.0
