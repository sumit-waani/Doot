## Tests for Doot crypto primitives.
## Covers HMAC-SHA256 signing, argon2id password hashing, and cookie signing.

import std/[unittest, strutils]
import ../src/doot/crypto

suite "HMAC-SHA256 Signing":
  test "hmacSign produces consistent output for same key and data":
    let key = "my-secret-key"
    let data = "hello-world"
    let sig1 = hmacSign(key, data)
    let sig2 = hmacSign(key, data)
    check sig1 == sig2
    check sig1.len == 64  # SHA-256 produces 32 bytes = 64 hex chars

  test "hmacSign produces hex-encoded output":
    let sig = hmacSign("key", "data")
    for c in sig:
      check c in {'0'..'9', 'a'..'f'}

  test "hmacSign with different keys produces different signatures":
    let sig1 = hmacSign("key1", "data")
    let sig2 = hmacSign("key2", "data")
    check sig1 != sig2

  test "hmacSign with different data produces different signatures":
    let sig1 = hmacSign("key", "data1")
    let sig2 = hmacSign("key", "data2")
    check sig1 != sig2

  test "hmacSign with empty key still works":
    let sig = hmacSign("", "data")
    check sig.len == 64

  test "hmacSign with empty data still works":
    let sig = hmacSign("key", "")
    check sig.len == 64

suite "HMAC-SHA256 Verification":
  test "hmacVerify returns true for valid signature":
    let key = "secret"
    let data = "message"
    let sig = hmacSign(key, data)
    check hmacVerify(key, data, sig) == true

  test "hmacVerify returns false for tampered data":
    let key = "secret"
    let sig = hmacSign(key, "original")
    check hmacVerify(key, "tampered", sig) == false

  test "hmacVerify returns false for tampered signature":
    let key = "secret"
    let data = "message"
    let sig = hmacSign(key, data)
    let tampered = "a" & sig[1..^1]  # Change first char
    check hmacVerify(key, data, tampered) == false

  test "hmacVerify returns false for wrong key":
    let sig = hmacSign("key1", "data")
    check hmacVerify("key2", "data", sig) == false

  test "hmacVerify returns false for empty signature":
    check hmacVerify("key", "data", "") == false

  test "hmacVerify returns false for signature of wrong length":
    check hmacVerify("key", "data", "abc123") == false

suite "Timing-Safe Comparison":
  test "timingSafeEqual returns true for equal strings":
    check timingSafeEqual("hello", "hello") == true

  test "timingSafeEqual returns false for different strings":
    check timingSafeEqual("hello", "world") == false

  test "timingSafeEqual returns false for different lengths":
    check timingSafeEqual("short", "longer-string") == false

  test "timingSafeEqual returns true for empty strings":
    check timingSafeEqual("", "") == true

  test "timingSafeEqual returns false for empty vs non-empty":
    check timingSafeEqual("", "x") == false

suite "Argon2id Password Hashing":
  test "hashPassword produces argon2id encoded format":
    let hash = hashPassword("mypassword123")
    check hash.startsWith("$argon2id$")

  test "hashPassword produces different hashes for same password (random salt)":
    let hash1 = hashPassword("samepassword")
    let hash2 = hashPassword("samepassword")
    check hash1 != hash2  # Different salts

  test "hashPassword never stores plaintext":
    let password = "super-secret-password"
    let hash = hashPassword(password)
    check password notin hash

  test "hashPassword contains version info":
    let hash = hashPassword("test")
    check "v=19" in hash  # Argon2 version 0x13 = 19

  test "hashPassword with empty password works":
    let hash = hashPassword("")
    check hash.startsWith("$argon2id$")

suite "Argon2id Password Verification":
  test "verifyPassword returns true for correct password":
    let password = "correct-horse-battery-staple"
    let hash = hashPassword(password)
    check verifyPassword(password, hash) == true

  test "verifyPassword returns false for wrong password":
    let hash = hashPassword("original-password")
    check verifyPassword("wrong-password", hash) == false

  test "verifyPassword returns false for empty password when hash is non-empty":
    let hash = hashPassword("some-password")
    check verifyPassword("", hash) == false

  test "verifyPassword with empty password hash works":
    let hash = hashPassword("")
    check verifyPassword("", hash) == true
    check verifyPassword("not-empty", hash) == false

suite "Session Cookie Signing":
  test "signSessionCookie produces sessionId.signature format":
    let cookie = signSessionCookie("abc123", "secret")
    check '.' in cookie
    let parts = cookie.split('.')
    check parts.len == 2
    check parts[0] == "abc123"
    check parts[1].len == 64  # hex-encoded HMAC-SHA256

  test "signSessionCookie is deterministic for same inputs":
    let c1 = signSessionCookie("session1", "key")
    let c2 = signSessionCookie("session1", "key")
    check c1 == c2

  test "signSessionCookie produces different output for different secrets":
    let c1 = signSessionCookie("session1", "key1")
    let c2 = signSessionCookie("session1", "key2")
    check c1 != c2

suite "Session Cookie Verification":
  test "verifySessionCookie round-trips correctly":
    let secret = "my-app-secret"
    let sessionId = "abcdef1234567890"
    let cookie = signSessionCookie(sessionId, secret)
    let result = verifySessionCookie(cookie, secret)
    check result == sessionId

  test "verifySessionCookie returns empty for tampered session ID":
    let secret = "my-secret"
    let cookie = signSessionCookie("original-id", secret)
    # Replace session ID portion
    let tampered = "tampered-id" & cookie[cookie.find('.')..^1]
    check verifySessionCookie(tampered, secret) == ""

  test "verifySessionCookie returns empty for tampered signature":
    let secret = "my-secret"
    let cookie = signSessionCookie("session123", secret)
    # Modify last char of signature
    let tampered = cookie[0..^2] & (if cookie[^1] == 'a': "b" else: "a")
    check verifySessionCookie(tampered, secret) == ""

  test "verifySessionCookie returns empty for wrong secret":
    let cookie = signSessionCookie("session1", "secret1")
    check verifySessionCookie(cookie, "secret2") == ""

  test "verifySessionCookie returns empty for missing dot":
    check verifySessionCookie("nodothere", "secret") == ""

  test "verifySessionCookie returns empty for empty string":
    check verifySessionCookie("", "secret") == ""

  test "verifySessionCookie returns empty for just a dot":
    check verifySessionCookie(".", "secret") == ""

  test "verifySessionCookie returns empty for dot at start":
    check verifySessionCookie(".signature", "secret") == ""

  test "verifySessionCookie returns empty for dot at end":
    check verifySessionCookie("sessionid.", "secret") == ""

  test "verifySessionCookie handles session IDs with special characters":
    let secret = "key"
    let sessionId = "abc-def_123"
    let cookie = signSessionCookie(sessionId, secret)
    check verifySessionCookie(cookie, secret) == sessionId

  test "verifySessionCookie handles long session IDs":
    let secret = "key"
    let sessionId = "a".repeat(128)
    let cookie = signSessionCookie(sessionId, secret)
    check verifySessionCookie(cookie, secret) == sessionId

# =============================================================================
# Auth Module Tests (FEAT-002)
# =============================================================================

import std/[os, tables, times, net, httpclient]
import std/[asynchttpserver, asyncdispatch]
import db_connector/db_sqlite except Row
import ../src/doot/session
import ../src/doot/auth
import ../src/doot/db_types
import ../src/doot/ctx
import ../src/doot/response
import ../src/doot/server
import ../src/doot/router

proc setupTestDb(): DbConn =
  ## Create an in-memory SQLite database for testing.
  result = open(":memory:", "", "", "")

proc setupAuthTestDb(): (DbConn, SessionStore, AuthConfig) =
  ## Create a full auth test environment.
  let db = setupTestDb()
  let config = newAuthConfig(
    model = "users",
    roles = @["admin", "user"],
    emailVerification = false,
    sessionSecret = "test-secret-key-12345",
    sessionExpiry = 14
  )
  initAuth(db, config)
  let store = newSessionStore(db)
  return (db, store, config)

suite "Auth - User Creation":
  test "createUser inserts a user with hashed password":
    let (db, store, config) = setupAuthTestDb()
    let result = createUser(db, "test@example.com", "mypassword123")
    check result.ok == true
    check result.record != nil
    check result.record.getString("email") == "test@example.com"
    # Password should be hashed, not plaintext
    check result.record.getString("password_hash") != "mypassword123"
    check result.record.getString("password_hash").startsWith("$argon2id$")
    check result.record.id > 0
    db.close()

  test "createUser returns error for duplicate email":
    let (db, store, config) = setupAuthTestDb()
    let r1 = createUser(db, "dup@example.com", "pass1")
    check r1.ok == true
    let r2 = createUser(db, "dup@example.com", "pass2")
    check r2.ok == false
    check r2.errors.len > 0
    check "Email already exists" in r2.errors[0]
    db.close()

  test "createUser returns error for empty email":
    let (db, store, config) = setupAuthTestDb()
    let result = createUser(db, "", "password")
    check result.ok == false
    check "Email is required" in result.errors[0]
    db.close()

  test "createUser returns error for empty password":
    let (db, store, config) = setupAuthTestDb()
    let result = createUser(db, "user@example.com", "")
    check result.ok == false
    check "Password is required" in result.errors[0]
    db.close()

  test "createUser stores the specified role":
    let (db, store, config) = setupAuthTestDb()
    let result = createUser(db, "admin@example.com", "pass", "admin")
    check result.ok == true
    check result.record.getString("role") == "admin"
    db.close()

  test "createUser defaults email_verified to 0":
    let (db, store, config) = setupAuthTestDb()
    let result = createUser(db, "new@example.com", "pass")
    check result.ok == true
    check result.record.getInt("email_verified") == 0
    db.close()

suite "Auth - User Lookup":
  test "findUserByEmail returns user when found":
    let (db, store, config) = setupAuthTestDb()
    discard createUser(db, "find@example.com", "pass123", "user")
    let user = findUserByEmail(db, "find@example.com")
    check user != nil
    check user.getString("email") == "find@example.com"
    check user.getString("role") == "user"
    db.close()

  test "findUserByEmail returns nil when not found":
    let (db, store, config) = setupAuthTestDb()
    let user = findUserByEmail(db, "nonexistent@example.com")
    check user == nil
    db.close()

  test "findUserById returns user when found":
    let (db, store, config) = setupAuthTestDb()
    let result = createUser(db, "byid@example.com", "pass")
    check result.ok == true
    let user = findUserById(db, result.record.id)
    check user != nil
    check user.getString("email") == "byid@example.com"
    check user.id == result.record.id
    db.close()

  test "findUserById returns nil for non-existent id":
    let (db, store, config) = setupAuthTestDb()
    let user = findUserById(db, 99999)
    check user == nil
    db.close()

suite "Auth - User Authentication":
  test "authenticateUser returns user for correct credentials":
    let (db, store, config) = setupAuthTestDb()
    discard createUser(db, "auth@example.com", "correct-password")
    let user = authenticateUser(db, "auth@example.com", "correct-password")
    check user != nil
    check user.getString("email") == "auth@example.com"
    db.close()

  test "authenticateUser returns nil for wrong password":
    let (db, store, config) = setupAuthTestDb()
    discard createUser(db, "auth2@example.com", "correct-password")
    let user = authenticateUser(db, "auth2@example.com", "wrong-password")
    check user == nil
    db.close()

  test "authenticateUser returns nil for non-existent email":
    let (db, store, config) = setupAuthTestDb()
    let user = authenticateUser(db, "ghost@example.com", "password")
    check user == nil
    db.close()

  test "authenticateUser returns nil for empty password":
    let (db, store, config) = setupAuthTestDb()
    discard createUser(db, "auth3@example.com", "actual-password")
    let user = authenticateUser(db, "auth3@example.com", "")
    check user == nil
    db.close()

suite "Auth - Session Creation and Cookies":
  test "createSession returns a signed cookie":
    let (db, store, config) = setupAuthTestDb()
    discard createUser(db, "sess@example.com", "pass")
    let user = findUserByEmail(db, "sess@example.com")
    let cookie = createSession(store, user.id, config.sessionSecret)
    check cookie.len > 0
    check '.' in cookie
    # Verify the cookie is valid
    let sessionId = verifySessionCookie(cookie, config.sessionSecret)
    check sessionId.len > 0
    db.close()

  test "createSession stores session in database":
    let (db, store, config) = setupAuthTestDb()
    let r = createUser(db, "sess2@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret)
    let sessionId = verifySessionCookie(cookie, config.sessionSecret)
    let session = store.loadSession(sessionId)
    check session.id == sessionId
    check session.userId == r.record.id
    db.close()

  test "createSession sets expiry based on config":
    let (db, store, config) = setupAuthTestDb()
    let r = createUser(db, "sess3@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret, 7)
    let sessionId = verifySessionCookie(cookie, config.sessionSecret)
    let session = store.loadSession(sessionId)
    check session.expiresAt.len > 0
    db.close()

  test "destroySession removes session from database":
    let (db, store, config) = setupAuthTestDb()
    let r = createUser(db, "sess4@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret)
    let sessionId = verifySessionCookie(cookie, config.sessionSecret)
    # Verify session exists
    let sessionBefore = store.loadSession(sessionId)
    check sessionBefore.id == sessionId
    # Destroy it
    destroySession(store, cookie, config.sessionSecret)
    # Verify session is gone (loadSession will generate a new ID)
    let sessionAfter = store.loadSession(sessionId)
    check sessionAfter.id != sessionId
    db.close()

  test "destroySession is safe with invalid cookie":
    let (db, store, config) = setupAuthTestDb()
    # Should not raise
    destroySession(store, "invalid.cookie", config.sessionSecret)
    destroySession(store, "", config.sessionSecret)
    db.close()

suite "Auth - loadUserFromCookie":
  test "loadUserFromCookie returns user for valid session":
    let (db, store, config) = setupAuthTestDb()
    let r = createUser(db, "load@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret)
    let user = loadUserFromCookie(db, store, cookie, config.sessionSecret)
    check user != nil
    check user.getString("email") == "load@example.com"
    db.close()

  test "loadUserFromCookie returns nil for tampered cookie":
    let (db, store, config) = setupAuthTestDb()
    let r = createUser(db, "tamper@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret)
    # Tamper with the cookie
    let tampered = "tamperedsession." & cookie.split('.')[1]
    let user = loadUserFromCookie(db, store, tampered, config.sessionSecret)
    check user == nil
    db.close()

  test "loadUserFromCookie returns nil for expired session":
    let (db, store, config) = setupAuthTestDb()
    let r = createUser(db, "expire@example.com", "pass")
    # Create session with the store directly using an expired time
    let sessionId = generateSessionId()
    let expiredTime = (now() - initDuration(days = 1)).format("yyyy-MM-dd HH:mm:ss")
    let sessionData = SessionData(
      id: sessionId,
      data: initTable[string, string](),
      userId: r.record.id,
      expiresAt: expiredTime,
      createdAt: now().format("yyyy-MM-dd HH:mm:ss")
    )
    store.saveSession(sessionData)
    let cookie = signSessionCookie(sessionId, config.sessionSecret)
    let user = loadUserFromCookie(db, store, cookie, config.sessionSecret)
    check user == nil
    db.close()

  test "loadUserFromCookie returns nil for empty cookie":
    let (db, store, config) = setupAuthTestDb()
    let user = loadUserFromCookie(db, store, "", config.sessionSecret)
    check user == nil
    db.close()

  test "loadUserFromCookie returns nil for non-existent session":
    let (db, store, config) = setupAuthTestDb()
    let cookie = signSessionCookie("nonexistent-session-id", config.sessionSecret)
    let user = loadUserFromCookie(db, store, cookie, config.sessionSecret)
    check user == nil
    db.close()

  test "loadUserFromCookie returns nil for wrong secret":
    let (db, store, config) = setupAuthTestDb()
    let r = createUser(db, "wrong@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret)
    let user = loadUserFromCookie(db, store, cookie, "wrong-secret")
    check user == nil
    db.close()

suite "Auth - Cookie Header Parsing":
  test "parseCookieHeader extracts named cookie":
    let header = "doot_session=abc123.sig456; other=value"
    check parseCookieHeader(header, "doot_session") == "abc123.sig456"

  test "parseCookieHeader returns empty for missing cookie":
    let header = "other=value; another=thing"
    check parseCookieHeader(header, "doot_session") == ""

  test "parseCookieHeader handles single cookie":
    let header = "doot_session=mysession.mysig"
    check parseCookieHeader(header, "doot_session") == "mysession.mysig"

  test "parseCookieHeader handles empty header":
    check parseCookieHeader("", "doot_session") == ""

  test "parseCookieHeader handles spaces around values":
    let header = "  doot_session = abc123 ; other = val "
    check parseCookieHeader(header, "doot_session") == "abc123"

suite "Auth - Session Cleanup":
  test "cleanupExpiredSessions removes expired entries":
    let (db, store, config) = setupAuthTestDb()
    # Create an expired session
    let expiredTime = (now() - initDuration(days = 1)).format("yyyy-MM-dd HH:mm:ss")
    let expiredSession = SessionData(
      id: "expired-session-1",
      data: initTable[string, string](),
      userId: 1,
      expiresAt: expiredTime,
      createdAt: now().format("yyyy-MM-dd HH:mm:ss")
    )
    store.saveSession(expiredSession)
    # Create a valid session
    let validTime = (now() + initDuration(days = 7)).format("yyyy-MM-dd HH:mm:ss")
    let validSession = SessionData(
      id: "valid-session-1",
      data: initTable[string, string](),
      userId: 2,
      expiresAt: validTime,
      createdAt: now().format("yyyy-MM-dd HH:mm:ss")
    )
    store.saveSession(validSession)
    # Cleanup
    store.cleanupExpiredSessions()
    # Expired session should be gone
    let afterExpired = store.loadSession("expired-session-1")
    check afterExpired.id != "expired-session-1"
    # Valid session should still exist
    let afterValid = store.loadSession("valid-session-1")
    check afterValid.id == "valid-session-1"
    db.close()

  test "cleanupExpiredSessions is safe with no sessions":
    let (db, store, config) = setupAuthTestDb()
    # Should not raise
    store.cleanupExpiredSessions()
    db.close()

suite "Auth - Handler Signup":
  test "handleSignup creates user and returns Set-Cookie":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let ctx = newCtx()
    ctx.form["email"] = "signup@example.com"
    ctx.form["password"] = "newpassword123"
    let resp = handleSignup(authCtx, ctx)
    check resp.status == 302
    check resp.headers.hasKey("Set-Cookie")
    check "doot_session=" in resp.headers["Set-Cookie"]
    check "HttpOnly" in resp.headers["Set-Cookie"]
    # Verify user was created
    let user = findUserByEmail(db, "signup@example.com")
    check user != nil
    db.close()

  test "handleSignup returns 400 for missing email":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let ctx = newCtx()
    ctx.form["password"] = "somepassword"
    let resp = handleSignup(authCtx, ctx)
    check resp.status == 400
    db.close()

  test "handleSignup returns 400 for missing password":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let ctx = newCtx()
    ctx.form["email"] = "user@example.com"
    let resp = handleSignup(authCtx, ctx)
    check resp.status == 400
    db.close()

  test "handleSignup returns 422 for duplicate email":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    discard createUser(db, "existing@example.com", "pass")
    let ctx = newCtx()
    ctx.form["email"] = "existing@example.com"
    ctx.form["password"] = "newpass"
    let resp = handleSignup(authCtx, ctx)
    check resp.status == 422
    db.close()

  test "handleSignup with role creates user with that role":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let ctx = newCtx()
    ctx.form["email"] = "admin@example.com"
    ctx.form["password"] = "adminpass"
    ctx.form["role"] = "admin"
    let resp = handleSignup(authCtx, ctx)
    check resp.status == 302
    let user = findUserByEmail(db, "admin@example.com")
    check user != nil
    check user.getString("role") == "admin"
    db.close()

suite "Auth - Handler Login":
  test "handleLogin returns Set-Cookie for valid credentials":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    discard createUser(db, "login@example.com", "correctpass")
    let ctx = newCtx()
    ctx.form["email"] = "login@example.com"
    ctx.form["password"] = "correctpass"
    let resp = handleLogin(authCtx, ctx)
    check resp.status == 302
    check resp.headers.hasKey("Set-Cookie")
    check "doot_session=" in resp.headers["Set-Cookie"]
    db.close()

  test "handleLogin returns 401 for wrong password":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    discard createUser(db, "login2@example.com", "correctpass")
    let ctx = newCtx()
    ctx.form["email"] = "login2@example.com"
    ctx.form["password"] = "wrongpass"
    let resp = handleLogin(authCtx, ctx)
    check resp.status == 401
    db.close()

  test "handleLogin returns 401 for non-existent user":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let ctx = newCtx()
    ctx.form["email"] = "nobody@example.com"
    ctx.form["password"] = "somepass"
    let resp = handleLogin(authCtx, ctx)
    check resp.status == 401
    db.close()

  test "handleLogin returns 400 for missing fields":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let ctx = newCtx()
    let resp = handleLogin(authCtx, ctx)
    check resp.status == 400
    db.close()

suite "Auth - Handler Logout":
  test "handleLogout clears the session cookie":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    # First create a user and session
    let r = createUser(db, "logout@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret)
    let ctx = newCtx()
    ctx.headers["cookie"] = "doot_session=" & cookie
    let resp = handleLogout(authCtx, ctx)
    check resp.status == 302
    check resp.headers.hasKey("Set-Cookie")
    check "Max-Age=0" in resp.headers["Set-Cookie"]
    db.close()

  test "handleLogout destroys the session":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let r = createUser(db, "logout2@example.com", "pass")
    let cookie = createSession(store, r.record.id, config.sessionSecret)
    let sessionId = verifySessionCookie(cookie, config.sessionSecret)
    let ctx = newCtx()
    ctx.headers["cookie"] = "doot_session=" & cookie
    discard handleLogout(authCtx, ctx)
    # Session should no longer exist
    let user = loadUserFromCookie(db, store, cookie, config.sessionSecret)
    check user == nil
    db.close()

  test "handleLogout is safe without cookie":
    let (db, store, config) = setupAuthTestDb()
    let authCtx = AuthHandlerContext(db: db, store: store, config: config)
    let ctx = newCtx()
    let resp = handleLogout(authCtx, ctx)
    check resp.status == 302
    check "Max-Age=0" in resp.headers["Set-Cookie"]
    db.close()

# =============================================================================
# E2E Auth Tests with Real HTTP Server
# =============================================================================

const AuthTestPort = 18955

var authServerThread: Thread[DootServer]

proc setupAuthServer(): DootServer =
  ## Create a DootServer with auth enabled for E2E testing.
  let db = open(":memory:", "", "", "")
  let config = newAuthConfig(
    sessionSecret = "e2e-test-secret",
    sessionExpiry = 14,
    roles = @["admin", "user"]
  )
  initAuth(db, config)
  let store = newSessionStore(db)

  var server = newDootServer(port = AuthTestPort)
  server.sessionStore = store
  server.db = db
  server.authConfig = config
  server.authEnabled = true

  # Public route
  server.registerRoute(hmGet, "/public", proc(ctx: DootCtx): DootResponse {.gcsafe.} =
    explicitResponse(200, "Public page", "text/plain")
  , authRequired = false)

  # Protected route (requires auth)
  server.registerRoute(hmGet, "/protected", proc(ctx: DootCtx): DootResponse {.gcsafe.} =
    let email = if ctx.currentUser != nil: ctx.currentUser.getString("email") else: "none"
    explicitResponse(200, "Protected: " & email, "text/plain")
  , authRequired = true)

  # Admin-only route
  server.registerRoute(hmGet, "/admin", proc(ctx: DootCtx): DootResponse {.gcsafe.} =
    explicitResponse(200, "Admin panel", "text/plain")
  , authRequired = true, roleName = "admin")

  # Route that shows currentUser
  server.registerRoute(hmGet, "/whoami", proc(ctx: DootCtx): DootResponse {.gcsafe.} =
    if ctx.currentUser != nil:
      explicitResponse(200, ctx.currentUser.getString("email"), "text/plain")
    else:
      explicitResponse(200, "anonymous", "text/plain")
  , authRequired = false)

  # Register built-in auth routes
  registerAuthRoutes(server, db, config)

  return server

proc runAuthServerInThread(server: DootServer) {.thread.} =
  let httpServer = newAsyncHttpServer()
  proc cb(req: Request) {.async, gcsafe, closure.} =
    {.cast(gcsafe).}:
      await handleRequest(server, req)
  asyncCheck httpServer.serve(Port(AuthTestPort), cb)
  runForever()

proc startAuthTestServer() =
  let server = setupAuthServer()
  createThread(authServerThread, runAuthServerInThread, server)
  sleep(500)

proc authBaseUrl(): string = "http://127.0.0.1:" & $AuthTestPort

startAuthTestServer()

suite "E2E Auth - Public Routes":
  test "GET /public returns 200 without auth":
    let client = newHttpClient()
    let resp = client.get(authBaseUrl() & "/public")
    check resp.code == Http200
    check resp.body == "Public page"
    client.close()

suite "E2E Auth - Protected Routes":
  test "GET /protected returns 401 without session":
    let client = newHttpClient()
    try:
      let resp = client.get(authBaseUrl() & "/protected")
      check resp.code == Http401
    except HttpRequestError:
      check true
    client.close()

  test "GET /protected returns 200 with valid session":
    let client = newHttpClient(maxRedirects = 0)
    # First signup to get a session cookie
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    let signupResp = client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=protected@test.com&password=testpass123")
    check signupResp.code == Http302
    # Extract Set-Cookie
    let setCookie = $signupResp.headers["set-cookie"]
    check "doot_session=" in setCookie
    # Extract cookie value for subsequent request
    let cookieStart = setCookie.find("doot_session=") + 13
    let cookieEnd = setCookie.find(";", cookieStart)
    let cookieValue = setCookie[cookieStart ..< cookieEnd]

    # Now access protected route with cookie
    let client2 = newHttpClient()
    client2.headers = newHttpHeaders({"Cookie": "doot_session=" & cookieValue})
    let resp = client2.get(authBaseUrl() & "/protected")
    check resp.code == Http200
    check "protected@test.com" in resp.body
    client.close()
    client2.close()

suite "E2E Auth - Role Enforcement":
  test "GET /admin returns 403 for non-admin user":
    let client = newHttpClient(maxRedirects = 0)
    # Create a regular user
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    let signupResp = client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=regular@test.com&password=testpass123&role=user")
    check signupResp.code == Http302
    let setCookie = $signupResp.headers["set-cookie"]
    let cookieStart = setCookie.find("doot_session=") + 13
    let cookieEnd = setCookie.find(";", cookieStart)
    let cookieValue = setCookie[cookieStart ..< cookieEnd]

    let client2 = newHttpClient()
    client2.headers = newHttpHeaders({"Cookie": "doot_session=" & cookieValue})
    try:
      let resp = client2.get(authBaseUrl() & "/admin")
      check resp.code == Http403
    except HttpRequestError:
      check true
    client.close()
    client2.close()

  test "GET /admin returns 200 for admin user":
    let client = newHttpClient(maxRedirects = 0)
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    let signupResp = client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=admin@test.com&password=adminpass123&role=admin")
    check signupResp.code == Http302
    let setCookie = $signupResp.headers["set-cookie"]
    let cookieStart = setCookie.find("doot_session=") + 13
    let cookieEnd = setCookie.find(";", cookieStart)
    let cookieValue = setCookie[cookieStart ..< cookieEnd]

    let client2 = newHttpClient()
    client2.headers = newHttpHeaders({"Cookie": "doot_session=" & cookieValue})
    let resp = client2.get(authBaseUrl() & "/admin")
    check resp.code == Http200
    check resp.body == "Admin panel"
    client.close()
    client2.close()

suite "E2E Auth - Signup Flow":
  test "POST /signup creates user and sets session cookie":
    let client = newHttpClient(maxRedirects = 0)
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    let resp = client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=newsignup@test.com&password=pass123")
    check resp.code == Http302
    let setCookie = $resp.headers["set-cookie"]
    check "doot_session=" in setCookie
    check "HttpOnly" in setCookie
    check "SameSite=Lax" in setCookie
    client.close()

  test "POST /signup with duplicate email returns 422":
    let client = newHttpClient(maxRedirects = 0)
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    # Create user first
    discard client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=duptest@test.com&password=pass1")
    # Try again
    try:
      let resp = client.request(authBaseUrl() & "/signup",
        httpMethod = HttpPost,
        body = "email=duptest@test.com&password=pass2")
      check resp.code == Http422
    except HttpRequestError:
      check true
    client.close()

suite "E2E Auth - Login Flow":
  test "POST /login with valid credentials sets session cookie":
    let client = newHttpClient(maxRedirects = 0)
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    # First signup
    discard client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=logintest@test.com&password=mypassword")
    # Now login
    let resp = client.request(authBaseUrl() & "/login",
      httpMethod = HttpPost,
      body = "email=logintest@test.com&password=mypassword")
    check resp.code == Http302
    let setCookie = $resp.headers["set-cookie"]
    check "doot_session=" in setCookie
    client.close()

  test "POST /login with invalid credentials returns 401":
    let client = newHttpClient(maxRedirects = 0)
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    # First signup
    discard client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=loginbad@test.com&password=realpass")
    # Login with wrong password
    try:
      let resp = client.request(authBaseUrl() & "/login",
        httpMethod = HttpPost,
        body = "email=loginbad@test.com&password=wrongpass")
      check resp.code == Http401
    except HttpRequestError:
      check true
    client.close()

suite "E2E Auth - Logout Flow":
  test "POST /logout clears session and cookie":
    let client = newHttpClient(maxRedirects = 0)
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    # Signup
    let signupResp = client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=logouttest@test.com&password=pass123")
    check signupResp.code == Http302
    let setCookie = $signupResp.headers["set-cookie"]
    let cookieStart = setCookie.find("doot_session=") + 13
    let cookieEnd = setCookie.find(";", cookieStart)
    let cookieValue = setCookie[cookieStart ..< cookieEnd]

    # Logout with cookie
    let client2 = newHttpClient(maxRedirects = 0)
    client2.headers = newHttpHeaders({
      "Content-Type": "application/x-www-form-urlencoded",
      "Cookie": "doot_session=" & cookieValue
    })
    let logoutResp = client2.request(authBaseUrl() & "/logout", httpMethod = HttpPost)
    check logoutResp.code == Http302
    let clearCookie = $logoutResp.headers["set-cookie"]
    check "Max-Age=0" in clearCookie

    # Verify session is destroyed - protected route should now return 401
    let client3 = newHttpClient()
    client3.headers = newHttpHeaders({"Cookie": "doot_session=" & cookieValue})
    try:
      let resp = client3.get(authBaseUrl() & "/protected")
      check resp.code == Http401
    except HttpRequestError:
      check true
    client.close()
    client2.close()
    client3.close()

suite "E2E Auth - ctx.currentUser Population":
  test "ctx.currentUser is populated for authenticated request":
    let client = newHttpClient(maxRedirects = 0)
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    let signupResp = client.request(authBaseUrl() & "/signup",
      httpMethod = HttpPost,
      body = "email=whoami@test.com&password=pass123")
    check signupResp.code == Http302
    let setCookie = $signupResp.headers["set-cookie"]
    let cookieStart = setCookie.find("doot_session=") + 13
    let cookieEnd = setCookie.find(";", cookieStart)
    let cookieValue = setCookie[cookieStart ..< cookieEnd]

    let client2 = newHttpClient()
    client2.headers = newHttpHeaders({"Cookie": "doot_session=" & cookieValue})
    let resp = client2.get(authBaseUrl() & "/whoami")
    check resp.code == Http200
    check resp.body == "whoami@test.com"
    client.close()
    client2.close()

  test "ctx.currentUser is nil for unauthenticated request":
    let client = newHttpClient()
    let resp = client.get(authBaseUrl() & "/whoami")
    check resp.code == Http200
    check resp.body == "anonymous"
    client.close()

