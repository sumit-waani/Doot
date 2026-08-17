## SQLite-backed state persistence for the dootd daemon.
## Manages config key-value store, application records, and app logs.

import std/[os, strutils]
import db_connector/db_sqlite
import ./dootd_types

const ConfigTableSQL* = """
  CREATE TABLE IF NOT EXISTS dootd_config (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )
"""

const AppsTableSQL* = """
  CREATE TABLE IF NOT EXISTS dootd_apps (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    hostname TEXT NOT NULL,
    github_url TEXT NOT NULL,
    pat TEXT NOT NULL DEFAULT '',
    branch TEXT NOT NULL DEFAULT 'main',
    env_vars TEXT NOT NULL DEFAULT '{}',
    internal_port INTEGER NOT NULL,
    memory_limit INTEGER NOT NULL DEFAULT 0,
    cpu_shares INTEGER NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'stopped'
  )
"""

const AppLogsTableSQL* = """
  CREATE TABLE IF NOT EXISTS dootd_app_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id INTEGER NOT NULL,
    timestamp TEXT NOT NULL,
    stream TEXT NOT NULL,
    message TEXT NOT NULL,
    FOREIGN KEY (app_id) REFERENCES dootd_apps(id)
  )
"""

proc getDataDir*(): string =
  ## Determine the data directory for dootd state.
  ## Uses /var/lib/dootd if running as root, otherwise ~/.dootd.
  if existsEnv("DOOTD_DATA_DIR"):
    return getEnv("DOOTD_DATA_DIR")
  let home = getHomeDir()
  result = home / UserDataDir

proc initDootdDb*(dataDir: string): DbConn =
  ## Initialize the dootd SQLite database.
  ## Creates the data directory and schema tables if they do not exist.
  createDir(dataDir)
  let dbPath = dataDir / "dootd.db"
  result = open(dbPath, "", "", "")
  result.exec(sql"PRAGMA journal_mode=WAL")
  result.exec(sql(ConfigTableSQL))
  result.exec(sql(AppsTableSQL))
  result.exec(sql(AppLogsTableSQL))

proc getConfig*(db: DbConn, key: string): string =
  ## Get a config value by key. Returns empty string if not found.
  let row = db.getRow(
    sql"SELECT value FROM dootd_config WHERE key = ?", key
  )
  result = row[0]

proc setConfig*(db: DbConn, key: string, value: string) =
  ## Set a config key-value pair (upsert).
  db.exec(
    sql"""INSERT INTO dootd_config (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = ?""",
    key, value, value
  )

proc deleteConfig*(db: DbConn, key: string) =
  ## Delete a config key.
  db.exec(sql"DELETE FROM dootd_config WHERE key = ?", key)

proc parseAppStatus(s: string): AppStatus =
  case s
  of "running": asRunning
  of "stopped": asStopped
  of "error": asError
  of "deploying": asDeploying
  else: asStopped

proc rowToAppConfig(row: seq[string]): AppConfig =
  ## Convert a database row to an AppConfig object.
  result = AppConfig(
    id: parseInt(row[0]).int64,
    name: row[1],
    hostname: row[2],
    githubUrl: row[3],
    pat: row[4],
    branch: row[5],
    envVars: row[6],
    internalPort: parseInt(row[7]),
    memoryLimit: parseInt(row[8]),
    cpuShares: parseInt(row[9]),
    status: parseAppStatus(row[10])
  )

proc getApps*(db: DbConn): seq[AppConfig] =
  ## Load all application configurations from the database.
  result = @[]
  let rows = db.getAllRows(
    sql"SELECT id, name, hostname, github_url, pat, branch, env_vars, internal_port, memory_limit, cpu_shares, status FROM dootd_apps ORDER BY id"
  )
  for row in rows:
    if row[0].len > 0:
      result.add(rowToAppConfig(row))

proc getApp*(db: DbConn, appId: int64): AppConfig =
  ## Load a single app by ID. Returns default AppConfig if not found.
  let row = db.getRow(
    sql"SELECT id, name, hostname, github_url, pat, branch, env_vars, internal_port, memory_limit, cpu_shares, status FROM dootd_apps WHERE id = ?",
    $appId
  )
  if row[0].len > 0:
    result = rowToAppConfig(row)

proc getAppByName*(db: DbConn, name: string): AppConfig =
  ## Load a single app by name. Returns default AppConfig if not found.
  let row = db.getRow(
    sql"SELECT id, name, hostname, github_url, pat, branch, env_vars, internal_port, memory_limit, cpu_shares, status FROM dootd_apps WHERE name = ?",
    name
  )
  if row[0].len > 0:
    result = rowToAppConfig(row)

proc nextInternalPort*(db: DbConn): int =
  ## Get the next available internal port for a new app.
  let row = db.getRow(
    sql"SELECT MAX(internal_port) FROM dootd_apps"
  )
  if row[0].len > 0:
    result = parseInt(row[0]) + 1
  else:
    result = InternalPortStart

proc saveAppConfig*(db: DbConn, app: AppConfig): int64 =
  ## Insert or update an app configuration.
  ## Returns the app ID.
  if app.id > 0:
    db.exec(
      sql"""UPDATE dootd_apps SET name = ?, hostname = ?, github_url = ?,
            pat = ?, branch = ?, env_vars = ?, internal_port = ?,
            memory_limit = ?, cpu_shares = ?, status = ? WHERE id = ?""",
      app.name, app.hostname, app.githubUrl, app.pat, app.branch,
      app.envVars, $app.internalPort, $app.memoryLimit, $app.cpuShares,
      $app.status, $app.id
    )
    result = app.id
  else:
    result = db.insertID(
      sql"""INSERT INTO dootd_apps (name, hostname, github_url, pat, branch,
            env_vars, internal_port, memory_limit, cpu_shares, status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
      app.name, app.hostname, app.githubUrl, app.pat, app.branch,
      app.envVars, $app.internalPort, $app.memoryLimit, $app.cpuShares,
      $app.status
    )

proc deleteApp*(db: DbConn, appId: int64) =
  ## Delete an app and its logs from the database.
  db.exec(sql"DELETE FROM dootd_app_logs WHERE app_id = ?", $appId)
  db.exec(sql"DELETE FROM dootd_apps WHERE id = ?", $appId)

proc updateAppStatus*(db: DbConn, appId: int64, status: AppStatus) =
  ## Update the status of an app.
  db.exec(
    sql"UPDATE dootd_apps SET status = ? WHERE id = ?",
    $status, $appId
  )

proc addAppLog*(db: DbConn, appId: int64, stream: string, message: string) =
  ## Add a log entry for an app.
  db.exec(
    sql"INSERT INTO dootd_app_logs (app_id, timestamp, stream, message) VALUES (?, datetime('now'), ?, ?)",
    $appId, stream, message
  )

proc getAppLogs*(db: DbConn, appId: int64, limit: int = 100): seq[tuple[timestamp, stream, message: string]] =
  ## Get recent log entries for an app.
  result = @[]
  let rows = db.getAllRows(
    sql"SELECT timestamp, stream, message FROM dootd_app_logs WHERE app_id = ? ORDER BY id DESC LIMIT ?",
    $appId, $limit
  )
  for row in rows:
    result.add((timestamp: row[0], stream: row[1], message: row[2]))

proc loadState*(db: DbConn): DootdState =
  ## Load the full daemon state from the database.
  let passwordHash = getConfig(db, "admin_password_hash")
  let dashboardPort = getConfig(db, "dashboard_port")
  let routerPort = getConfig(db, "router_port")

  result = DootdState(
    config: DootdConfig(
      dataDir: getConfig(db, "data_dir"),
      dashboardPort: if dashboardPort.len > 0: parseInt(dashboardPort) else: DefaultDashboardPort,
      routerPort: if routerPort.len > 0: parseInt(routerPort) else: DefaultRouterPort,
      binaryPath: getConfig(db, "binary_path")
    ),
    apps: getApps(db),
    passwordHash: passwordHash,
    initialized: passwordHash.len > 0
  )
