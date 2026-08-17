## Migration runner.
## Applies pending migrations in sequential order, tracks applied migrations
## in _doot_migrations table. Fails fast on error.

import std/[os, strutils, algorithm]
import db_connector/db_sqlite

proc ensureMigrationsTable*(db: DbConn) =
  ## Creates the _doot_migrations tracking table if it doesn't exist.
  db.exec(sql"""CREATE TABLE IF NOT EXISTS _doot_migrations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filename TEXT NOT NULL UNIQUE,
    applied_at TEXT NOT NULL DEFAULT (datetime('now'))
  )""")

proc getAppliedMigrations*(db: DbConn): seq[string] =
  ## Returns filenames of all migrations that have already been applied.
  result = @[]
  let rows = db.getAllRows(sql"SELECT filename FROM _doot_migrations ORDER BY id")
  for row in rows:
    result.add(row[0])

proc getPendingMigrations*(migrationsDir: string, applied: seq[string]): seq[string] =
  ## Returns migration filenames that haven't been applied yet, sorted by number.
  result = @[]
  if not dirExists(migrationsDir):
    return

  for kind, path in walkDir(migrationsDir):
    if kind == pcFile:
      let filename = extractFilename(path)
      if filename.endsWith(".sql") and filename notin applied:
        result.add(filename)

  # Sort by filename (which sorts by number prefix)
  result.sort()

proc runMigrations*(db: DbConn, migrationsDir: string): tuple[applied: int, errors: seq[string]] =
  ## Applies pending migrations in order.
  ## Returns count of applied migrations and any errors encountered.
  ## Fails fast: stops at first error.
  result = (applied: 0, errors: @[])

  ensureMigrationsTable(db)

  let applied = getAppliedMigrations(db)
  let pending = getPendingMigrations(migrationsDir, applied)

  for filename in pending:
    let filepath = migrationsDir / filename
    let sqlContent = readFile(filepath)

    # Split by semicolons to execute multiple statements
    # Filter out empty/comment-only statements
    let statements = sqlContent.split(';')

    try:
      for stmt in statements:
        let trimmed = stmt.strip()
        if trimmed.len == 0:
          continue
        # Skip comment-only lines
        var hasSQL = false
        for line in trimmed.splitLines():
          let l = line.strip()
          if l.len > 0 and not l.startsWith("--"):
            hasSQL = true
            break
        if not hasSQL:
          continue

        db.exec(sql(trimmed & ";"))

      # Record successful migration
      db.exec(sql"INSERT INTO _doot_migrations (filename) VALUES (?)", filename)
      result.applied += 1
    except DbError:
      let errMsg = "Migration " & filename & " failed: " & getCurrentExceptionMsg()
      result.errors.add(errMsg)
      return  # Fail fast
