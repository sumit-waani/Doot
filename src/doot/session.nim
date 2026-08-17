## Session management for the Doot HTTP runtime.
## SQLite-backed sessions with JSON data storage.
## Cookie signing is a stub in Phase 3 (Phase 5 adds HMAC).

import std/[tables, strutils, json, times, random]
import db_connector/db_sqlite

type
  SessionStore* = ref object
    db*: DbConn

  SessionData* = object
    id*: string
    data*: Table[string, string]
    userId*: int64
    expiresAt*: string
    createdAt*: string

const SessionTableSQL* = """
  CREATE TABLE IF NOT EXISTS _sessions (
    session_id TEXT PRIMARY KEY,
    data TEXT,
    user_id INTEGER,
    expires_at TEXT,
    created_at TEXT
  )
"""

proc generateSessionId*(): string =
  ## Generate a random hex session ID (32 chars).
  var r = initRand()
  result = ""
  for i in 0..<16:
    result.add(toHex(r.rand(255).uint8, 2).toLowerAscii())

proc newSessionStore*(db: DbConn): SessionStore =
  ## Create a new session store backed by the given SQLite connection.
  result = SessionStore(db: db)
  db.exec(sql(SessionTableSQL))

proc loadSession*(store: SessionStore, sessionId: string): SessionData =
  ## Load a session from the database by session ID.
  ## Returns an empty session if not found.
  result = SessionData(
    id: sessionId,
    data: initTable[string, string](),
    userId: 0,
    expiresAt: "",
    createdAt: ""
  )
  if sessionId.len == 0:
    result.id = generateSessionId()
    return

  let row = store.db.getRow(
    sql"SELECT data, user_id, expires_at, created_at FROM _sessions WHERE session_id = ?",
    sessionId
  )
  if row[0] == "":
    # Session not found
    result.id = generateSessionId()
    return

  # Parse JSON data
  result.createdAt = row[3]
  result.expiresAt = row[2]
  try:
    result.userId = if row[1].len > 0: parseBiggestInt(row[1]).int64 else: 0'i64
  except ValueError:
    result.userId = 0

  try:
    let jsonData = parseJson(row[0])
    if jsonData.kind == JObject:
      for key, val in jsonData.pairs:
        if val.kind == JString:
          result.data[key] = val.getStr()
  except JsonParsingError:
    discard

proc saveSession*(store: SessionStore, session: SessionData) =
  ## Save session data to the database.
  var jsonObj = newJObject()
  for key, value in session.data.pairs:
    jsonObj[key] = newJString(value)
  let dataStr = $jsonObj
  let now = $now()

  # Upsert: try insert, on conflict update
  store.db.exec(
    sql"""INSERT INTO _sessions (session_id, data, user_id, expires_at, created_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(session_id) DO UPDATE SET data = ?, user_id = ?, expires_at = ?""",
    session.id, dataStr, $session.userId,
    session.expiresAt, if session.createdAt.len > 0: session.createdAt else: now,
    dataStr, $session.userId, session.expiresAt
  )

proc deleteSession*(store: SessionStore, sessionId: string) =
  ## Delete a session from the database.
  store.db.exec(sql"DELETE FROM _sessions WHERE session_id = ?", sessionId)

proc getSessionValue*(session: var SessionData, key: string): string =
  ## Get a value from the session data.
  if session.data.hasKey(key):
    return session.data[key]
  return ""

proc setSessionValue*(session: var SessionData, key: string, value: string) =
  ## Set a value in the session data.
  session.data[key] = value

proc deleteSessionValue*(session: var SessionData, key: string) =
  ## Remove a value from the session data.
  if session.data.hasKey(key):
    session.data.del(key)
