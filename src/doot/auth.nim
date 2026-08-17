## Authentication module for the Doot HTTP runtime.
## Provides user table DDL, user CRUD operations, session cookie integration,
## auth middleware for populating ctx.currentUser, and built-in
## signup/login/logout route handlers.

import std/[tables, strutils, times]
import db_connector/db_sqlite except Row
import ./crypto
import ./session
import ./db_types
import ./ctx
import ./response

type
  AuthConfig* = object
    model*: string               ## Model name (e.g., "users")
    roles*: seq[string]          ## Allowed roles
    emailVerification*: bool     ## Whether email verification is enabled
    sessionSecret*: string       ## HMAC secret for cookie signing
    sessionExpiry*: int          ## Session expiry in days (default 14)

proc generateUserTableDDL*(config: AuthConfig): string =
  ## Generates the CREATE TABLE IF NOT EXISTS users DDL based on config.
  ## Conditionally includes role (if roles configured) and email_verified
  ## (if emailVerification enabled), matching generateAuthDDL behavior.
  var columns: seq[string] = @[]
  columns.add("id INTEGER PRIMARY KEY AUTOINCREMENT")
  columns.add("email TEXT NOT NULL UNIQUE")
  columns.add("password_hash TEXT NOT NULL")

  if config.roles.len > 0:
    columns.add("role TEXT DEFAULT ''")

  if config.emailVerification:
    columns.add("email_verified INTEGER DEFAULT 0")

  columns.add("created_at TEXT NOT NULL DEFAULT (datetime('now'))")
  columns.add("updated_at TEXT NOT NULL DEFAULT (datetime('now'))")

  let tableName = if config.model.len > 0: config.model else: "users"
  result = "CREATE TABLE IF NOT EXISTS " & tableName & " (\n"
  for i, col in columns:
    result &= "  " & col
    if i < columns.len - 1:
      result &= ","
    result &= "\n"
  result &= ")"

const UserEmailIndexDDL* = """
  CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users(email)
"""

proc newAuthConfig*(model: string = "users", roles: seq[string] = @[],
                    emailVerification: bool = false,
                    sessionSecret: string = "change-me-in-production",
                    sessionExpiry: int = 14): AuthConfig =
  AuthConfig(
    model: model,
    roles: roles,
    emailVerification: emailVerification,
    sessionSecret: sessionSecret,
    sessionExpiry: sessionExpiry
  )

# Module-level config flags used by query functions to determine column layout.
# These are simple value types (not GC'd) to avoid GC-safety issues in async code.
var moduleHasRoles: bool = true
var moduleHasEmailVerification: bool = true

proc userSelectColumns*(): string =
  ## Build the SELECT column list for user queries based on module flags.
  var cols = @["id", "email", "password_hash"]
  if moduleHasRoles:
    cols.add("role")
  if moduleHasEmailVerification:
    cols.add("email_verified")
  cols.add("created_at")
  cols.add("updated_at")
  return cols.join(", ")

proc userColumnCount*(): int =
  ## Return the number of columns a user query will return.
  result = 5  # id, email, password_hash, created_at, updated_at
  if moduleHasRoles:
    result += 1
  if moduleHasEmailVerification:
    result += 1

proc initAuth*(db: DbConn, config: AuthConfig) =
  ## Initialize auth tables: creates users table and sessions table.
  ## The users table schema is driven by config (roles, emailVerification)
  ## to stay consistent with generateAuthDDL used by the codegen pipeline.
  ## Also stores the config flags at module level for use by query functions.
  moduleHasRoles = config.roles.len > 0
  moduleHasEmailVerification = config.emailVerification
  db.exec(sql(generateUserTableDDL(config)))
  db.exec(sql(UserEmailIndexDDL))
  db.exec(sql(SessionTableSQL))
  # Clean up any expired sessions on startup
  let store = SessionStore(db: db)
  store.cleanupExpiredSessions()

proc rowFromUser(row: seq[string], columnCount: int): Row =
  ## Convert a raw SQLite row to a typed Row object.
  ## Column layout is determined by the module-level config flags:
  ##   7 cols: id, email, password_hash, role, email_verified, created_at, updated_at
  ##   6 cols (roles only): id, email, password_hash, role, created_at, updated_at
  ##   6 cols (email_verified only): id, email, password_hash, email_verified, created_at, updated_at
  ##   5 cols (minimal): id, email, password_hash, created_at, updated_at
  if row.len == 0 or row[0] == "":
    return nil
  result = newRow()
  try:
    result.id = parseBiggestInt(row[0]).int64
  except ValueError:
    result.id = 0
  result.fields["id"] = dbInt(result.id)
  result.fields["email"] = dbStr(row[1])
  result.fields["password_hash"] = dbStr(row[2])

  # Use module flags to determine layout
  var idx = 3

  if moduleHasRoles:
    result.fields["role"] = dbStr(row[idx])
    idx += 1
  else:
    result.fields["role"] = dbStr("")

  if moduleHasEmailVerification:
    result.fields["email_verified"] = dbInt(if row[idx] == "1": 1'i64 else: 0'i64)
    idx += 1
  else:
    result.fields["email_verified"] = dbInt(0'i64)

  result.fields["created_at"] = dbStr(row[idx])
  result.fields["updated_at"] = dbStr(row[idx + 1])

proc createUser*(db: DbConn, email: string, password: string,
                 role: string = ""): DbResult =
  ## Create a new user with hashed password.
  ## Returns ok result with user Row on success, error on duplicate email.
  if email.len == 0:
    return errResult(@["Email is required"])
  if password.len == 0:
    return errResult(@["Password is required"])

  # Check for existing user (fast path to avoid hashing when email is taken)
  let existing = db.getRow(
    sql"SELECT id FROM users WHERE email = ?", email)
  if existing[0] != "":
    return errResult(@["Email already exists"])

  let hashedPassword = hashPassword(password)

  # Build INSERT dynamically based on config
  var insertCols = "email, password_hash"
  var insertPlaceholders = "?, ?"
  var insertValues: seq[string] = @[email, hashedPassword]
  if moduleHasRoles:
    insertCols &= ", role"
    insertPlaceholders &= ", ?"
    insertValues.add(role)

  let insertSql = "INSERT INTO users (" & insertCols & ") VALUES (" & insertPlaceholders & ")"

  # Wrap the INSERT in try/except to handle the TOCTOU race: if another
  # connection inserts the same email between our SELECT and INSERT, the
  # UNIQUE constraint will raise a DbError which we map to a user-friendly error.
  try:
    case insertValues.len
    of 2:
      db.exec(sql(insertSql), insertValues[0], insertValues[1])
    of 3:
      db.exec(sql(insertSql), insertValues[0], insertValues[1], insertValues[2])
    else:
      db.exec(sql(insertSql), insertValues[0], insertValues[1])
  except DbError:
    return errResult(@["Email already exists"])

  let lastId = db.getRow(sql"SELECT last_insert_rowid()")[0]
  let selectCols = userSelectColumns()
  let colCount = userColumnCount()
  let userRow = db.getRow(
    sql("SELECT " & selectCols & " FROM users WHERE id = ?"),
    lastId)

  let row = rowFromUser(userRow, colCount)
  if row == nil:
    return errResult(@["Failed to retrieve created user"])
  return okResult(row)

proc findUserByEmail*(db: DbConn, email: string): Row =
  ## Find a user by email. Returns nil if not found.
  let selectCols = userSelectColumns()
  let colCount = userColumnCount()
  let row = db.getRow(
    sql("SELECT " & selectCols & " FROM users WHERE email = ?"),
    email)
  return rowFromUser(row, colCount)

proc findUserById*(db: DbConn, id: int64): Row =
  ## Find a user by ID. Returns nil if not found.
  let selectCols = userSelectColumns()
  let colCount = userColumnCount()
  let row = db.getRow(
    sql("SELECT " & selectCols & " FROM users WHERE id = ?"),
    $id)
  return rowFromUser(row, colCount)

proc authenticateUser*(db: DbConn, email: string, password: string): Row =
  ## Authenticate a user with email and password.
  ## Returns user Row if credentials are valid, nil otherwise.
  let user = findUserByEmail(db, email)
  if user == nil:
    return nil
  let storedHash = user.getString("password_hash")
  if verifyPassword(password, storedHash):
    return user
  return nil

proc createSession*(store: SessionStore, userId: int64, secret: string,
                    expiresInDays: int = 14): string =
  ## Create a new session for the given user and return a signed cookie value.
  let sessionId = generateSessionId()
  let expiry = now() + initDuration(days = expiresInDays)
  let expiryStr = expiry.format("yyyy-MM-dd HH:mm:ss")

  let sessionData = SessionData(
    id: sessionId,
    data: initTable[string, string](),
    userId: userId,
    expiresAt: expiryStr,
    createdAt: now().format("yyyy-MM-dd HH:mm:ss")
  )
  store.saveSession(sessionData)

  # Return the signed cookie
  return signSessionCookie(sessionId, secret)

proc destroySession*(store: SessionStore, cookie: string, secret: string) =
  ## Verify cookie signature and destroy the session.
  let sessionId = verifySessionCookie(cookie, secret)
  if sessionId.len > 0:
    store.deleteSession(sessionId)

proc loadUserFromCookie*(db: DbConn, store: SessionStore, cookie: string,
                         secret: string): Row =
  ## Load a user from a signed session cookie.
  ## Verifies HMAC, loads session, checks expiry, loads user.
  ## Returns nil if any step fails.
  if cookie.len == 0:
    return nil

  let sessionId = verifySessionCookie(cookie, secret)
  if sessionId.len == 0:
    return nil

  let session = store.loadSession(sessionId)
  # If session was not found (a new ID was generated), return nil
  if session.id != sessionId:
    return nil

  # Check expiry
  if session.expiresAt.len > 0:
    try:
      let expiryTime = parse(session.expiresAt, "yyyy-MM-dd HH:mm:ss")
      if now() > expiryTime:
        # Session expired, clean it up
        store.deleteSession(sessionId)
        return nil
    except TimeParseError:
      # If we can't parse the expiry, consider it invalid
      return nil

  if session.userId == 0:
    return nil

  return findUserById(db, session.userId)

proc parseCookieHeader*(cookieHeader: string, name: string): string =
  ## Parse a Cookie header to extract a specific cookie value.
  ## Cookie header format: "key1=value1; key2=value2"
  result = ""
  if cookieHeader.len == 0:
    return
  let pairs = cookieHeader.split(";")
  for pair in pairs:
    let trimmed = pair.strip()
    let eqIdx = trimmed.find('=')
    if eqIdx > 0:
      let key = trimmed[0 ..< eqIdx].strip()
      let value = trimmed[eqIdx + 1 .. ^1].strip()
      if key == name:
        return value

proc makeSessionCookieHeader*(value: string, maxAge: int = 1209600): string =
  ## Build a Set-Cookie header value for the session cookie.
  "doot_session=" & value & "; Path=/; HttpOnly; SameSite=Lax; Max-Age=" & $maxAge

proc clearSessionCookieHeader*(): string =
  ## Build a Set-Cookie header to clear the session cookie.
  "doot_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"

# =============================================================================
# Email Verification
# =============================================================================

proc generateVerificationToken*(userId: int64, secret: string): string =
  ## Generate a signed email verification token for the given userId.
  ## Format: userId.hmacSignature (base10 userId, hex HMAC-SHA256).
  let data = $userId
  let sig = hmacSign(secret, data)
  return data & "." & sig

proc verifyEmailToken*(token: string, secret: string): int64 =
  ## Verify an email verification token and return the userId.
  ## Returns 0 if the token is invalid or tampered.
  if token.len == 0:
    return 0
  let dotIdx = token.rfind('.')
  if dotIdx <= 0 or dotIdx >= token.len - 1:
    return 0
  let data = token[0 ..< dotIdx]
  let sig = token[dotIdx + 1 .. ^1]
  if not hmacVerify(secret, data, sig):
    return 0
  try:
    result = parseBiggestInt(data).int64
  except ValueError:
    result = 0

# =============================================================================
# Built-in route handlers
# =============================================================================

type
  AuthHandlerContext* = object
    db*: DbConn
    store*: SessionStore
    config*: AuthConfig

proc handleSignup*(authCtx: AuthHandlerContext, ctx: DootCtx): DootResponse =
  ## Built-in signup handler: reads email/password from form, creates user,
  ## creates session, returns redirect with Set-Cookie.
  ## Note: the built-in handler never reads "role" from the form to prevent
  ## users from self-assigning privileged roles (e.g., "admin").
  ## Roles should be assigned by admin logic or business rules, not during signup.
  let email = ctx.form.getOrDefault("email", "")
  let password = ctx.form.getOrDefault("password", "")

  if email.len == 0 or password.len == 0:
    return errorResponse(400, "Email and password are required")

  let dbResult = createUser(authCtx.db, email, password, "")
  if not dbResult.ok:
    return errorResponse(422, dbResult.errors.join(", "))

  # Create session for the new user
  let cookie = createSession(authCtx.store, dbResult.record.id,
                             authCtx.config.sessionSecret,
                             authCtx.config.sessionExpiry)

  var resp = redirectResponse("/")
  resp.headers["Set-Cookie"] = makeSessionCookieHeader(cookie,
    authCtx.config.sessionExpiry * 86400)
  return resp

proc handleLogin*(authCtx: AuthHandlerContext, ctx: DootCtx): DootResponse =
  ## Built-in login handler: reads email/password from form, authenticates,
  ## creates session, returns redirect with Set-Cookie.
  let email = ctx.form.getOrDefault("email", "")
  let password = ctx.form.getOrDefault("password", "")

  if email.len == 0 or password.len == 0:
    return errorResponse(400, "Email and password are required")

  let user = authenticateUser(authCtx.db, email, password)
  if user == nil:
    return errorResponse(401, "Invalid email or password")

  # Create session
  let cookie = createSession(authCtx.store, user.id,
                             authCtx.config.sessionSecret,
                             authCtx.config.sessionExpiry)

  var resp = redirectResponse("/")
  resp.headers["Set-Cookie"] = makeSessionCookieHeader(cookie,
    authCtx.config.sessionExpiry * 86400)
  return resp

proc handleLogout*(authCtx: AuthHandlerContext, ctx: DootCtx): DootResponse =
  ## Built-in logout handler: reads session cookie, destroys session,
  ## returns redirect with cleared cookie.
  let cookieHeader = ctx.headers.getOrDefault("cookie", "")
  let cookieValue = parseCookieHeader(cookieHeader, "doot_session")

  if cookieValue.len > 0:
    destroySession(authCtx.store, cookieValue, authCtx.config.sessionSecret)

  var resp = redirectResponse("/")
  resp.headers["Set-Cookie"] = clearSessionCookieHeader()
  return resp
