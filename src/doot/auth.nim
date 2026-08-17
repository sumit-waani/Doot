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

const UserTableDDL* = """
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    role TEXT DEFAULT '',
    email_verified INTEGER DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  )
"""

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

proc initAuth*(db: DbConn, config: AuthConfig) =
  ## Initialize auth tables: creates users table and sessions table.
  db.exec(sql(UserTableDDL))
  db.exec(sql(UserEmailIndexDDL))
  db.exec(sql(SessionTableSQL))

proc rowFromUser(row: seq[string]): Row =
  ## Convert a raw SQLite row to a typed Row object.
  ## Expected order: id, email, password_hash, role, email_verified, created_at, updated_at
  if row[0] == "":
    return nil
  result = newRow()
  try:
    result.id = parseBiggestInt(row[0]).int64
  except ValueError:
    result.id = 0
  result.fields["id"] = dbInt(result.id)
  result.fields["email"] = dbStr(row[1])
  result.fields["password_hash"] = dbStr(row[2])
  result.fields["role"] = dbStr(row[3])
  result.fields["email_verified"] = dbInt(if row[4] == "1": 1'i64 else: 0'i64)
  result.fields["created_at"] = dbStr(row[5])
  result.fields["updated_at"] = dbStr(row[6])

proc createUser*(db: DbConn, email: string, password: string,
                 role: string = ""): DbResult =
  ## Create a new user with hashed password.
  ## Returns ok result with user Row on success, error on duplicate email.
  if email.len == 0:
    return errResult(@["Email is required"])
  if password.len == 0:
    return errResult(@["Password is required"])

  # Check for existing user
  let existing = db.getRow(
    sql"SELECT id FROM users WHERE email = ?", email)
  if existing[0] != "":
    return errResult(@["Email already exists"])

  let hashedPassword = hashPassword(password)
  db.exec(sql"""INSERT INTO users (email, password_hash, role)
                VALUES (?, ?, ?)""", email, hashedPassword, role)

  let lastId = db.getRow(sql"SELECT last_insert_rowid()")[0]
  let userRow = db.getRow(
    sql"SELECT id, email, password_hash, role, email_verified, created_at, updated_at FROM users WHERE id = ?",
    lastId)

  let row = rowFromUser(userRow)
  if row == nil:
    return errResult(@["Failed to retrieve created user"])
  return okResult(row)

proc findUserByEmail*(db: DbConn, email: string): Row =
  ## Find a user by email. Returns nil if not found.
  let row = db.getRow(
    sql"SELECT id, email, password_hash, role, email_verified, created_at, updated_at FROM users WHERE email = ?",
    email)
  return rowFromUser(row)

proc findUserById*(db: DbConn, id: int64): Row =
  ## Find a user by ID. Returns nil if not found.
  let row = db.getRow(
    sql"SELECT id, email, password_hash, role, email_verified, created_at, updated_at FROM users WHERE id = ?",
    $id)
  return rowFromUser(row)

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
  let email = ctx.form.getOrDefault("email", "")
  let password = ctx.form.getOrDefault("password", "")
  let role = ctx.form.getOrDefault("role", "")

  if email.len == 0 or password.len == 0:
    return errorResponse(400, "Email and password are required")

  let dbResult = createUser(authCtx.db, email, password, role)
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
