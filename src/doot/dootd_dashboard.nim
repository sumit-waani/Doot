## Dashboard HTTP server for the dootd production daemon.
## Provides a web UI for managing deployed applications.
## Uses std/asynchttpserver with cookie-based session authentication.

import std/[asynchttpserver, asyncdispatch, strutils, tables, uri, sysrand, times]
import db_connector/db_sqlite
import ./dootd_types
import ./dootd_state
import ./dootd_password
import ./dootd_html
import ./dootd_stats

const
  SessionCookieName* = "dootd_session"
  SessionExpireHours* = 24
  CsrfTokenLength* = 16

# =============================================================================
# Session Management (simplified, SQLite-backed)
# =============================================================================

const DashboardSessionTableSQL* = """
  CREATE TABLE IF NOT EXISTS dootd_sessions (
    session_id TEXT PRIMARY KEY,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL
  )
"""

proc initDashboardSessions*(db: DbConn) =
  ## Create the sessions table if it does not exist.
  db.exec(sql(DashboardSessionTableSQL))

proc generateDashboardSessionId*(): string =
  ## Generate a cryptographically secure random hex session ID (32 chars).
  var bytes: array[16, byte]
  if not urandom(bytes):
    raise newException(OSError, "Failed to read from system random source")
  result = ""
  for b in bytes:
    result.add(toHex(b, 2).toLowerAscii())

proc createSession*(db: DbConn): string =
  ## Create a new session and return the session ID.
  let sessionId = generateDashboardSessionId()
  let now = $now()
  let expires = $(now() + initDuration(hours = SessionExpireHours))
  db.exec(
    sql"INSERT INTO dootd_sessions (session_id, created_at, expires_at) VALUES (?, ?, ?)",
    sessionId, now, expires
  )
  result = sessionId

proc validateSession*(db: DbConn, sessionId: string): bool =
  ## Check if a session exists and is not expired.
  ## Compares the stored expires_at timestamp against the current time.
  if sessionId.len == 0:
    return false
  let row = db.getRow(
    sql"SELECT expires_at FROM dootd_sessions WHERE session_id = ?",
    sessionId
  )
  if row[0].len == 0:
    return false
  # Enforce expiry: compare stored timestamp to current time
  try:
    let expiresAt = parse(row[0], "yyyy-MM-dd'T'HH:mm:sszzz")
    if now() > expiresAt:
      # Session has expired - delete it and reject
      db.exec(sql"DELETE FROM dootd_sessions WHERE session_id = ?", sessionId)
      return false
  except TimeParseError:
    # If the timestamp cannot be parsed, try alternative format
    try:
      let expiresAt = parse(row[0], "yyyy-MM-dd HH:mm:ss")
      if now() > expiresAt:
        db.exec(sql"DELETE FROM dootd_sessions WHERE session_id = ?", sessionId)
        return false
    except TimeParseError:
      # If we still cannot parse, accept the session (backward compat)
      discard
  result = true

proc deleteSessionById*(db: DbConn, sessionId: string) =
  ## Delete a session from the database.
  db.exec(sql"DELETE FROM dootd_sessions WHERE session_id = ?", sessionId)

# =============================================================================
# CSRF Token Management
# =============================================================================

proc generateCsrfToken*(): string =
  ## Generate a cryptographically secure random hex CSRF token.
  var bytes: array[CsrfTokenLength, byte]
  if not urandom(bytes):
    raise newException(OSError, "Failed to read from system random source")
  result = ""
  for b in bytes:
    result.add(toHex(b, 2).toLowerAscii())

proc getCsrfToken*(db: DbConn, sessionId: string): string =
  ## Get or create a CSRF token for the given session.
  ## Stored as a config key: csrf_<sessionId>.
  let key = "csrf_" & sessionId
  result = getConfig(db, key)
  if result.len == 0:
    result = generateCsrfToken()
    setConfig(db, key, result)

proc validateCsrfToken*(db: DbConn, sessionId: string, token: string): bool =
  ## Validate a CSRF token against the stored value for the session.
  if sessionId.len == 0 or token.len == 0:
    return false
  let stored = getConfig(db, "csrf_" & sessionId)
  result = stored.len > 0 and stored == token

proc deleteCsrfToken*(db: DbConn, sessionId: string) =
  ## Delete the CSRF token for a session (on logout).
  deleteConfig(db, "csrf_" & sessionId)

# =============================================================================
# Request Parsing Helpers
# =============================================================================

proc parseCookies*(cookieHeader: string): Table[string, string] =
  ## Parse a Cookie header into key-value pairs.
  result = initTable[string, string]()
  if cookieHeader.len == 0:
    return
  for part in cookieHeader.split(';'):
    let trimmed = part.strip()
    let eqPos = trimmed.find('=')
    if eqPos > 0:
      let key = trimmed[0 ..< eqPos].strip()
      let value = trimmed[eqPos + 1 .. ^1].strip()
      result[key] = value

proc parseFormBody*(body: string): Table[string, string] =
  ## Parse a URL-encoded form body into key-value pairs.
  result = initTable[string, string]()
  if body.len == 0:
    return
  for part in body.split('&'):
    let eqPos = part.find('=')
    if eqPos > 0:
      let key = decodeUrl(part[0 ..< eqPos])
      let value = decodeUrl(part[eqPos + 1 .. ^1])
      result[key] = value

proc parseQueryString*(query: string): Table[string, string] =
  ## Parse a URL query string into key-value pairs.
  result = parseFormBody(query)

proc extractPathSegments*(path: string): seq[string] =
  ## Split a URL path into non-empty segments.
  result = @[]
  for seg in path.split('/'):
    if seg.len > 0:
      result.add(seg)

# =============================================================================
# Dashboard Response Helpers
# =============================================================================

type
  DashboardResponse* = object
    status*: int
    headers*: Table[string, string]
    body*: string

proc htmlResponse*(status: int, body: string): DashboardResponse =
  var headers = initTable[string, string]()
  headers["Content-Type"] = "text/html; charset=utf-8"
  DashboardResponse(status: status, headers: headers, body: body)

proc redirectTo*(path: string): DashboardResponse =
  var headers = initTable[string, string]()
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Location"] = path
  DashboardResponse(status: 302, headers: headers, body: "Redirecting to " & path)

proc redirectWithCookie*(path: string, cookieName: string, cookieValue: string): DashboardResponse =
  var headers = initTable[string, string]()
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Location"] = path
  headers["Set-Cookie"] = cookieName & "=" & cookieValue & "; Path=/; HttpOnly; SameSite=Strict"
  DashboardResponse(status: 302, headers: headers, body: "Redirecting to " & path)

proc redirectClearCookie*(path: string, cookieName: string): DashboardResponse =
  var headers = initTable[string, string]()
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Location"] = path
  headers["Set-Cookie"] = cookieName & "=; Path=/; HttpOnly; Max-Age=0"
  DashboardResponse(status: 302, headers: headers, body: "Redirecting to " & path)

# =============================================================================
# Dashboard Request Handler
# =============================================================================

type
  DootdDashboard* = ref object
    port*: int
    db*: DbConn
    running*: bool

proc newDootdDashboard*(db: DbConn, port: int = DefaultDashboardPort): DootdDashboard =
  ## Create a new dashboard instance.
  initDashboardSessions(db)
  DootdDashboard(port: port, db: db, running: false)

proc getSessionFromRequest*(dashboard: DootdDashboard, req: Request): string =
  ## Extract and validate the session ID from the request cookie.
  ## Returns the session ID if valid, empty string otherwise.
  let cookieHeader = req.headers.getOrDefault("cookie")
  let cookies = parseCookies(cookieHeader)
  if cookies.hasKey(SessionCookieName):
    let sessionId = cookies[SessionCookieName]
    if validateSession(dashboard.db, sessionId):
      return sessionId
  return ""

proc isAuthenticated*(dashboard: DootdDashboard, req: Request): bool =
  ## Check if the request has a valid session.
  getSessionFromRequest(dashboard, req).len > 0

proc handleLogin(dashboard: DootdDashboard, req: Request): DashboardResponse =
  ## Handle POST /login - verify password and create session.
  let form = parseFormBody(req.body)
  let password = form.getOrDefault("password")

  if password.len == 0:
    return htmlResponse(200, renderLoginPage("Password is required"))

  if verifyAdminPassword(dashboard.db, password):
    let sessionId = createSession(dashboard.db)
    return redirectWithCookie("/", SessionCookieName, sessionId)
  else:
    return htmlResponse(200, renderLoginPage("Invalid password"))

proc handleLogout(dashboard: DootdDashboard, req: Request): DashboardResponse =
  ## Handle POST /logout - destroy session and redirect to login.
  let sessionId = getSessionFromRequest(dashboard, req)
  if sessionId.len > 0:
    deleteCsrfToken(dashboard.db, sessionId)
    deleteSessionById(dashboard.db, sessionId)
  return redirectClearCookie("/login", SessionCookieName)

proc handleAppList(dashboard: DootdDashboard, csrfToken: string): DashboardResponse =
  ## Handle GET / - show app list.
  let apps = getApps(dashboard.db)
  return htmlResponse(200, renderAppList(apps, csrfToken))

proc handleAppNew(dashboard: DootdDashboard, csrfToken: string): DashboardResponse =
  ## Handle GET /apps/new - show create app form.
  return htmlResponse(200, renderAppForm(csrfToken = csrfToken))

proc handleAppCreate(dashboard: DootdDashboard, req: Request): DashboardResponse =
  ## Handle POST /apps - create a new app.
  let form = parseFormBody(req.body)
  let name = form.getOrDefault("name")
  let hostname = form.getOrDefault("hostname")
  let githubUrl = form.getOrDefault("github_url")
  let pat = form.getOrDefault("pat")
  let branch = if form.hasKey("branch") and form["branch"].len > 0: form["branch"] else: "main"
  let envVars = form.getOrDefault("env_vars")
  let memoryLimit = try: parseInt(form.getOrDefault("memory_limit", "0")) except ValueError: 0
  let cpuShares = try: parseInt(form.getOrDefault("cpu_shares", "0")) except ValueError: 0

  if name.len == 0 or hostname.len == 0 or githubUrl.len == 0:
    # Show form with error - for simplicity redirect back
    return redirectTo("/apps/new")

  let port = nextInternalPort(dashboard.db)
  var app = AppConfig(
    name: name,
    hostname: hostname,
    githubUrl: githubUrl,
    pat: pat,
    branch: branch,
    envVars: envVars,
    internalPort: port,
    memoryLimit: memoryLimit,
    cpuShares: cpuShares,
    status: asStopped
  )
  discard saveAppConfig(dashboard.db, app)
  return redirectTo("/")

proc handleAppDetail(dashboard: DootdDashboard, appId: int64, csrfToken: string): DashboardResponse =
  ## Handle GET /apps/:id - show app detail.
  let app = getApp(dashboard.db, appId)
  if app.id == 0:
    return htmlResponse(404, renderLayout("Not Found", "<div class=\"container\"><div class=\"card\"><p>App not found.</p></div></div>"))
  let logs = getAppLogs(dashboard.db, appId, limit = 20)
  return htmlResponse(200, renderAppDetail(app, logs, csrfToken))

proc handleAppEdit(dashboard: DootdDashboard, appId: int64, csrfToken: string): DashboardResponse =
  ## Handle GET /apps/:id/edit - show edit form.
  let app = getApp(dashboard.db, appId)
  if app.id == 0:
    return htmlResponse(404, renderLayout("Not Found", "<div class=\"container\"><div class=\"card\"><p>App not found.</p></div></div>"))
  return htmlResponse(200, renderAppForm(app, isEdit = true, csrfToken = csrfToken))

proc handleAppUpdate(dashboard: DootdDashboard, appId: int64, req: Request): DashboardResponse =
  ## Handle POST /apps/:id/update - update app config.
  let form = parseFormBody(req.body)
  var app = getApp(dashboard.db, appId)
  if app.id == 0:
    return redirectTo("/")

  app.name = form.getOrDefault("name", app.name)
  app.hostname = form.getOrDefault("hostname", app.hostname)
  app.githubUrl = form.getOrDefault("github_url", app.githubUrl)
  app.pat = form.getOrDefault("pat", app.pat)
  app.branch = if form.hasKey("branch") and form["branch"].len > 0: form["branch"] else: app.branch
  app.envVars = form.getOrDefault("env_vars", app.envVars)
  app.memoryLimit = try: parseInt(form.getOrDefault("memory_limit", $app.memoryLimit)) except ValueError: app.memoryLimit
  app.cpuShares = try: parseInt(form.getOrDefault("cpu_shares", $app.cpuShares)) except ValueError: app.cpuShares

  discard saveAppConfig(dashboard.db, app)
  return redirectTo("/apps/" & $appId)

proc handleAppDelete(dashboard: DootdDashboard, appId: int64): DashboardResponse =
  ## Handle POST /apps/:id/delete - delete an app.
  deleteApp(dashboard.db, appId)
  return redirectTo("/")

proc handleAppDeploy(dashboard: DootdDashboard, appId: int64): DashboardResponse =
  ## Handle POST /apps/:id/deploy - trigger deploy (mark as deploying).
  let app = getApp(dashboard.db, appId)
  if app.id == 0:
    return redirectTo("/")
  updateAppStatus(dashboard.db, appId, asDeploying)
  addAppLog(dashboard.db, appId, "stdout", "Deploy triggered from dashboard")
  return redirectTo("/apps/" & $appId)

proc handleAppLogs(dashboard: DootdDashboard, appId: int64, query: string): DashboardResponse =
  ## Handle GET /apps/:id/logs - view app logs.
  let app = getApp(dashboard.db, appId)
  if app.id == 0:
    return htmlResponse(404, renderLayout("Not Found", "<div class=\"container\"><div class=\"card\"><p>App not found.</p></div></div>"))

  let params = parseQueryString(query)
  let search = params.getOrDefault("search")

  var logs = getAppLogs(dashboard.db, appId, limit = 200)

  # Filter logs by search term if provided
  if search.len > 0:
    var filtered: seq[tuple[timestamp, stream, message: string]] = @[]
    for log in logs:
      if search.toLowerAscii() in log.message.toLowerAscii():
        filtered.add(log)
    logs = filtered

  return htmlResponse(200, renderLogsPage(app.name, logs, search))

proc handleStats(dashboard: DootdDashboard): DashboardResponse =
  ## Handle GET /stats - show system stats.
  let stats = collectSystemStats()
  return htmlResponse(200, renderStatsPage(stats))

proc handleSettings(dashboard: DootdDashboard, csrfToken: string): DashboardResponse =
  ## Handle GET /settings - show settings page.
  return htmlResponse(200, renderSettingsPage(csrfToken = csrfToken))

proc handlePasswordChange(dashboard: DootdDashboard, req: Request): DashboardResponse =
  ## Handle POST /settings/password - change admin password.
  let form = parseFormBody(req.body)
  let currentPassword = form.getOrDefault("current_password")
  let newPassword = form.getOrDefault("new_password")
  let confirmPassword = form.getOrDefault("confirm_password")

  if currentPassword.len == 0 or newPassword.len == 0:
    return htmlResponse(200, renderSettingsPage("All fields are required", isError = true))

  if newPassword != confirmPassword:
    return htmlResponse(200, renderSettingsPage("New passwords do not match", isError = true))

  if newPassword.len < 4:
    return htmlResponse(200, renderSettingsPage("New password must be at least 4 characters", isError = true))

  if not verifyAdminPassword(dashboard.db, currentPassword):
    return htmlResponse(200, renderSettingsPage("Current password is incorrect", isError = true))

  hashAndStorePassword(dashboard.db, newPassword)
  return htmlResponse(200, renderSettingsPage("Password changed successfully"))

proc handleDashboardRequest*(dashboard: DootdDashboard, req: Request): DashboardResponse =
  ## Main router for dashboard requests.
  let parsedUrl = parseUri($req.url)
  let path = parsedUrl.path
  let query = parsedUrl.query
  let httpMethod = $req.reqMethod
  let segments = extractPathSegments(path)

  # Public routes (no auth needed)
  if path == "/login":
    if httpMethod == "GET":
      return htmlResponse(200, renderLoginPage())
    elif httpMethod == "POST":
      return handleLogin(dashboard, req)

  # All other routes require authentication
  if not isAuthenticated(dashboard, req):
    return redirectTo("/login")

  # Get session for CSRF token
  let sessionId = getSessionFromRequest(dashboard, req)
  let csrfToken = getCsrfToken(dashboard.db, sessionId)

  # Validate CSRF token on all authenticated POST requests
  if httpMethod == "POST":
    let form = parseFormBody(req.body)
    let submittedToken = form.getOrDefault("csrf_token")
    if not validateCsrfToken(dashboard.db, sessionId, submittedToken):
      return htmlResponse(403, renderLayout("Forbidden",
        "<div class=\"container\"><div class=\"card\"><div class=\"alert alert-error\">Invalid or missing CSRF token. Please try again.</div></div></div>"))

  # POST /logout
  if path == "/logout" and httpMethod == "POST":
    return handleLogout(dashboard, req)

  # GET / - app list
  if path == "/" and httpMethod == "GET":
    return handleAppList(dashboard, csrfToken)

  # GET /apps/new - new app form
  if path == "/apps/new" and httpMethod == "GET":
    return handleAppNew(dashboard, csrfToken)

  # POST /apps - create app
  if path == "/apps" and httpMethod == "POST":
    return handleAppCreate(dashboard, req)

  # GET /stats
  if path == "/stats" and httpMethod == "GET":
    return handleStats(dashboard)

  # GET /settings
  if path == "/settings" and httpMethod == "GET":
    return handleSettings(dashboard, csrfToken)

  # POST /settings/password
  if path == "/settings/password" and httpMethod == "POST":
    return handlePasswordChange(dashboard, req)

  # App-specific routes: /apps/:id, /apps/:id/action
  if segments.len >= 2 and segments[0] == "apps":
    let appId = try: parseInt(segments[1]).int64 except ValueError: 0'i64
    if appId > 0:
      if segments.len == 2 and httpMethod == "GET":
        return handleAppDetail(dashboard, appId, csrfToken)

      if segments.len == 3:
        case segments[2]
        of "edit":
          if httpMethod == "GET":
            return handleAppEdit(dashboard, appId, csrfToken)
        of "update":
          if httpMethod == "POST":
            return handleAppUpdate(dashboard, appId, req)
        of "delete":
          if httpMethod == "POST":
            return handleAppDelete(dashboard, appId)
        of "deploy":
          if httpMethod == "POST":
            return handleAppDeploy(dashboard, appId)
        of "logs":
          if httpMethod == "GET":
            return handleAppLogs(dashboard, appId, query)
        else:
          discard

  # 404
  return htmlResponse(404, renderLayout("Not Found", "<div class=\"container\"><div class=\"card\"><p>Page not found.</p></div></div>"))

proc startDashboard*(dashboard: DootdDashboard) {.async.} =
  ## Start the dashboard HTTP server.
  dashboard.running = true
  let httpServer = newAsyncHttpServer()
  echo "Dootd dashboard starting on port " & $dashboard.port

  proc cb(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      let resp = handleDashboardRequest(dashboard, req)
      var headers = newHttpHeaders()
      for key, value in resp.headers.pairs:
        headers.add(key, value)
      await req.respond(HttpCode(resp.status), resp.body, headers)

  httpServer.listen(Port(dashboard.port))
  while dashboard.running:
    if httpServer.shouldAcceptRequest():
      await httpServer.acceptRequest(cb)
    else:
      await sleepAsync(500)

proc runDashboard*(dashboard: DootdDashboard) =
  ## Run the dashboard server (blocking).
  waitFor startDashboard(dashboard)
