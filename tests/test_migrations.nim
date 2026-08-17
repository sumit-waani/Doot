## Comprehensive tests for the migration system:
## - Schema snapshot serialization (round-trip)
## - Diff engine (detecting all change types)
## - isDestructive classification
## - Migration SQL generation
## - Migration file naming and numbering
## - Migration runner (apply, skip applied, fail-fast)

import std/[unittest, json, os, strutils]
import db_connector/db_sqlite
import ../src/doot/ast
import ../src/doot/schema_snapshot
import ../src/doot/migration_diff
import ../src/doot/migration_gen
import ../src/doot/migration_runner

# Helper: create a simple schema with one table
proc makePostsSchema(): DootNode =
  let schema = newSchemaNode()
  let table = newTableNode("posts")
  table.hasTimestamps = true

  let titleField = newFieldNode("title", "string")
  titleField.fieldConstraints.add(Constraint(key: "required",
    value: newBoolLitNode(true)))
  titleField.fieldConstraints.add(Constraint(key: "max",
    value: newIntLitNode(200)))

  let bodyField = newFieldNode("body", "text")
  bodyField.fieldConstraints.add(Constraint(key: "required",
    value: newBoolLitNode(true)))

  let publishedField = newFieldNode("published", "boolean")
  publishedField.fieldConstraints.add(Constraint(key: "default",
    value: newBoolLitNode(false)))

  table.tableFields = @[titleField, bodyField, publishedField]
  schema.schemaTables.add(table)
  return schema

# Helper: create a schema with two tables
proc makeMultiSchema(): DootNode =
  let schema = makePostsSchema()
  let comments = newTableNode("comments")
  comments.hasTimestamps = true
  let commentBody = newFieldNode("body", "text")
  commentBody.fieldConstraints.add(Constraint(key: "required",
    value: newBoolLitNode(true)))
  let postId = newFieldNode("post_id", "integer")
  postId.fieldConstraints.add(Constraint(key: "required",
    value: newBoolLitNode(true)))
  comments.tableFields = @[commentBody, postId]
  schema.schemaTables.add(comments)
  return schema

suite "Schema Snapshot Serialization":
  test "schemaToJson produces valid JSON with all fields":
    let schema = makePostsSchema()
    let j = schemaToJson(schema)
    check j.hasKey("tables")
    check j["tables"].len == 1

    let table = j["tables"][0]
    check table["name"].getStr() == "posts"
    check table["hasTimestamps"].getBool() == true
    check table["fields"].len == 3

    let titleField = table["fields"][0]
    check titleField["name"].getStr() == "title"
    check titleField["type"].getStr() == "string"
    check titleField["required"].getBool() == true
    check titleField["maxLength"].getInt() == 200

  test "schemaToJson captures default values":
    let schema = makePostsSchema()
    let j = schemaToJson(schema)
    let publishedField = j["tables"][0]["fields"][2]
    check publishedField["name"].getStr() == "published"
    check publishedField["defaultValue"].getStr() == "b:false"

  test "jsonToSnapshot round-trip produces equivalent TableSnapshot":
    let schema = makePostsSchema()
    let j = schemaToJson(schema)
    let snapshots = jsonToSnapshot(j)

    check snapshots.len == 1
    check snapshots[0].name == "posts"
    check snapshots[0].hasTimestamps == true
    check snapshots[0].fields.len == 3
    check snapshots[0].fields[0].name == "title"
    check snapshots[0].fields[0].fieldType == "string"
    check snapshots[0].fields[0].required == true
    check snapshots[0].fields[0].maxLength == 200
    check snapshots[0].fields[1].name == "body"
    check snapshots[0].fields[1].fieldType == "text"
    check snapshots[0].fields[2].name == "published"
    check snapshots[0].fields[2].fieldType == "boolean"

  test "saveSnapshot and loadSnapshot round-trip":
    let schema = makePostsSchema()
    let tmpDir = getTempDir() / "doot_test_snapshot"
    let path = tmpDir / "schema_snapshot.json"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    saveSnapshot(schema, path)
    check fileExists(path)

    let loaded = loadSnapshot(path)
    check loaded.len == 1
    check loaded[0].name == "posts"
    check loaded[0].fields.len == 3
    check loaded[0].fields[0].name == "title"

  test "loadSnapshot returns empty seq for non-existent file":
    let result = loadSnapshot("/nonexistent/path/snapshot.json")
    check result.len == 0

  test "multi-table schema serialization":
    let schema = makeMultiSchema()
    let j = schemaToJson(schema)
    check j["tables"].len == 2
    check j["tables"][0]["name"].getStr() == "posts"
    check j["tables"][1]["name"].getStr() == "comments"

    let snapshots = jsonToSnapshot(j)
    check snapshots.len == 2
    check snapshots[1].fields.len == 2

suite "Migration Diff Engine":
  test "detects AddTable for new table":
    let schema = makePostsSchema()
    let previous: seq[TableSnapshot] = @[]  # empty previous

    let changes = diffSchema(schema, previous)
    check changes.len == 1
    check changes[0].kind == AddTable
    check changes[0].addTableNode.tableName == "posts"

  test "detects DropTable for removed table":
    let schema = newSchemaNode()  # empty current schema
    let previous = @[TableSnapshot(name: "posts", fields: @[], hasTimestamps: true)]

    let changes = diffSchema(schema, previous)
    check changes.len == 1
    check changes[0].kind == DropTable
    check changes[0].dropTableName == "posts"

  test "detects AddColumn for new field in existing table":
    # Current schema has posts with title, body, published, slug
    let schema = makePostsSchema()
    let slugField = newFieldNode("slug", "string")
    schema.schemaTables[0].tableFields.add(slugField)

    # Previous snapshot has posts with title, body, published (no slug)
    let previous = @[TableSnapshot(
      name: "posts",
      fields: @[
        FieldSnapshot(name: "title", fieldType: "string", required: true, maxLength: 200),
        FieldSnapshot(name: "body", fieldType: "text", required: true, maxLength: 0),
        FieldSnapshot(name: "published", fieldType: "boolean", required: false, maxLength: 0)
      ],
      hasTimestamps: true
    )]

    let changes = diffSchema(schema, previous)
    check changes.len == 1
    check changes[0].kind == AddColumn
    check changes[0].addColTable == "posts"
    check changes[0].addColField.fieldName == "slug"

  test "detects DropColumn for removed field":
    # Current schema has posts with title, body (published removed)
    let schema = newSchemaNode()
    let table = newTableNode("posts")
    table.hasTimestamps = true
    let titleField = newFieldNode("title", "string")
    let bodyField = newFieldNode("body", "text")
    table.tableFields = @[titleField, bodyField]
    schema.schemaTables.add(table)

    # Previous had title, body, published
    let previous = @[TableSnapshot(
      name: "posts",
      fields: @[
        FieldSnapshot(name: "title", fieldType: "string", required: false, maxLength: 0),
        FieldSnapshot(name: "body", fieldType: "text", required: false, maxLength: 0),
        FieldSnapshot(name: "published", fieldType: "boolean", required: false, maxLength: 0)
      ],
      hasTimestamps: true
    )]

    let changes = diffSchema(schema, previous)
    check changes.len == 1
    check changes[0].kind == DropColumn
    check changes[0].dropColTable == "posts"
    check changes[0].dropColName == "published"

  test "detects ChangeColumnType for type change":
    # Current schema: posts with title as text (was string)
    let schema = newSchemaNode()
    let table = newTableNode("posts")
    let titleField = newFieldNode("title", "text")  # changed from string to text
    table.tableFields = @[titleField]
    schema.schemaTables.add(table)

    # Previous: title was string
    let previous = @[TableSnapshot(
      name: "posts",
      fields: @[
        FieldSnapshot(name: "title", fieldType: "string", required: false, maxLength: 0)
      ],
      hasTimestamps: false
    )]

    let changes = diffSchema(schema, previous)
    check changes.len == 1
    check changes[0].kind == ChangeColumnType
    check changes[0].changeColTable == "posts"
    check changes[0].changeColName == "title"
    check changes[0].changeColOldType == "string"
    check changes[0].changeColNewType == "text"

  test "detects multiple changes simultaneously":
    # Current: posts(title, body) + comments(body, post_id) - two tables
    let schema = makeMultiSchema()

    # Previous: only posts(title, body, published) - one table, different fields
    let previous = @[TableSnapshot(
      name: "posts",
      fields: @[
        FieldSnapshot(name: "title", fieldType: "string", required: true, maxLength: 200),
        FieldSnapshot(name: "body", fieldType: "text", required: true, maxLength: 0),
        FieldSnapshot(name: "published", fieldType: "boolean", required: false, maxLength: 0)
      ],
      hasTimestamps: true
    )]

    let changes = diffSchema(schema, previous)
    # Should detect: AddTable(comments) (no field changes since posts matches)
    var hasAddTable = false
    for c in changes:
      if c.kind == AddTable and c.addTableNode.tableName == "comments":
        hasAddTable = true
    check hasAddTable

  test "no changes detected for identical schema":
    let schema = makePostsSchema()
    let previous = @[TableSnapshot(
      name: "posts",
      fields: @[
        FieldSnapshot(name: "title", fieldType: "string", required: true, maxLength: 200),
        FieldSnapshot(name: "body", fieldType: "text", required: true, maxLength: 0),
        FieldSnapshot(name: "published", fieldType: "boolean", required: false, maxLength: 0)
      ],
      hasTimestamps: true
    )]

    let changes = diffSchema(schema, previous)
    check changes.len == 0

suite "isDestructive Classification":
  test "AddTable is not destructive":
    let change = SchemaChange(kind: AddTable,
      addTableNode: newTableNode("posts"))
    check isDestructive(change) == false

  test "AddColumn is not destructive":
    let change = SchemaChange(kind: AddColumn,
      addColTable: "posts",
      addColField: newFieldNode("slug", "string"))
    check isDestructive(change) == false

  test "DropTable is destructive":
    let change = SchemaChange(kind: DropTable,
      dropTableName: "posts")
    check isDestructive(change) == true

  test "DropColumn is destructive":
    let change = SchemaChange(kind: DropColumn,
      dropColTable: "posts",
      dropColName: "slug")
    check isDestructive(change) == true

  test "ChangeColumnType is destructive":
    let change = SchemaChange(kind: ChangeColumnType,
      changeColTable: "posts",
      changeColName: "title",
      changeColOldType: "string",
      changeColNewType: "text")
    check isDestructive(change) == true

suite "Migration SQL Generation":
  test "AddTable produces valid CREATE TABLE":
    let table = newTableNode("posts")
    table.hasTimestamps = true
    let titleField = newFieldNode("title", "string")
    titleField.fieldConstraints.add(Constraint(key: "required",
      value: newBoolLitNode(true)))
    table.tableFields = @[titleField]

    let change = SchemaChange(kind: AddTable, addTableNode: table)
    let sql = generateMigrationSQL(change)

    check "CREATE TABLE posts" in sql
    check "id INTEGER PRIMARY KEY AUTOINCREMENT" in sql
    check "title TEXT NOT NULL" in sql
    check "created_at TEXT NOT NULL DEFAULT (datetime('now'))" in sql
    check "updated_at TEXT NOT NULL DEFAULT (datetime('now'))" in sql

  test "AddColumn produces valid ALTER TABLE ADD COLUMN":
    let field = newFieldNode("slug", "string")
    let change = SchemaChange(kind: AddColumn,
      addColTable: "posts",
      addColField: field)
    let sql = generateMigrationSQL(change)

    check sql == "ALTER TABLE posts ADD COLUMN slug TEXT;"

  test "AddColumn with NOT NULL constraint":
    let field = newFieldNode("email", "string")
    field.fieldConstraints.add(Constraint(key: "required",
      value: newBoolLitNode(true)))
    let change = SchemaChange(kind: AddColumn,
      addColTable: "users",
      addColField: field)
    let sql = generateMigrationSQL(change)

    check sql == "ALTER TABLE users ADD COLUMN email TEXT NOT NULL;"

  test "DropColumn produces valid ALTER TABLE DROP COLUMN":
    let change = SchemaChange(kind: DropColumn,
      dropColTable: "posts",
      dropColName: "subtitle")
    let sql = generateMigrationSQL(change)

    check sql == "ALTER TABLE posts DROP COLUMN subtitle;"

  test "DropTable produces valid DROP TABLE":
    let change = SchemaChange(kind: DropTable,
      dropTableName: "comments")
    let sql = generateMigrationSQL(change)

    check sql == "DROP TABLE comments;"

  test "ChangeColumnType produces comment-based migration":
    let change = SchemaChange(kind: ChangeColumnType,
      changeColTable: "posts",
      changeColName: "count",
      changeColOldType: "string",
      changeColNewType: "integer")
    let sql = generateMigrationSQL(change)

    check "Change column type" in sql
    check "posts.count" in sql
    check "Manual migration required" in sql

suite "Migration File Naming and Numbering":
  test "generates file with 001 prefix for first migration":
    let tmpDir = getTempDir() / "doot_test_migrations_naming"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let table = newTableNode("posts")
    table.hasTimestamps = true
    let titleField = newFieldNode("title", "string")
    table.tableFields = @[titleField]
    let change = SchemaChange(kind: AddTable, addTableNode: table)

    let filename = generateMigrationFile(@[change], tmpDir)
    check filename == "001_create_posts.sql"
    check fileExists(tmpDir / filename)

  test "generates sequential numbering":
    let tmpDir = getTempDir() / "doot_test_migrations_seq"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Write a fake first migration
    writeFile(tmpDir / "001_create_posts.sql", "-- fake")

    let field = newFieldNode("slug", "string")
    let change = SchemaChange(kind: AddColumn,
      addColTable: "posts",
      addColField: field)

    let filename = generateMigrationFile(@[change], tmpDir)
    check filename == "002_add_slug_to_posts.sql"

  test "generates descriptive names for different change types":
    let tmpDir = getTempDir() / "doot_test_migrations_desc"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # DropTable
    let change1 = SchemaChange(kind: DropTable, dropTableName: "comments")
    let f1 = generateMigrationFile(@[change1], tmpDir)
    check "drop_comments" in f1

    # DropColumn
    let change2 = SchemaChange(kind: DropColumn,
      dropColTable: "posts", dropColName: "subtitle")
    let f2 = generateMigrationFile(@[change2], tmpDir)
    check "drop_subtitle_from_posts" in f2

  test "returns empty string for empty changes":
    let tmpDir = getTempDir() / "doot_test_migrations_empty"
    let filename = generateMigrationFile(@[], tmpDir)
    check filename == ""

  test "migration file contains SQL content":
    let tmpDir = getTempDir() / "doot_test_migrations_content"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    let table = newTableNode("users")
    let emailField = newFieldNode("email", "string")
    emailField.fieldConstraints.add(Constraint(key: "required",
      value: newBoolLitNode(true)))
    table.tableFields = @[emailField]
    let change = SchemaChange(kind: AddTable, addTableNode: table)

    let filename = generateMigrationFile(@[change], tmpDir)
    let content = readFile(tmpDir / filename)
    check "CREATE TABLE users" in content
    check "email TEXT NOT NULL" in content
    check "id INTEGER PRIMARY KEY AUTOINCREMENT" in content

  test "getNextMigrationNumber with no existing migrations":
    let tmpDir = getTempDir() / "doot_test_next_num_empty"
    createDir(tmpDir)
    defer: removeDir(tmpDir)
    check getNextMigrationNumber(tmpDir) == 1

  test "getNextMigrationNumber with existing migrations":
    let tmpDir = getTempDir() / "doot_test_next_num"
    createDir(tmpDir)
    defer: removeDir(tmpDir)
    writeFile(tmpDir / "001_create_posts.sql", "")
    writeFile(tmpDir / "002_add_slug.sql", "")
    check getNextMigrationNumber(tmpDir) == 3

suite "Migration Runner":
  test "ensureMigrationsTable creates tracking table":
    let db = open(":memory:", "", "", "")
    defer: db.close()

    ensureMigrationsTable(db)

    # Verify table exists
    let rows = db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type='table' AND name='_doot_migrations'")
    check rows.len == 1
    check rows[0][0] == "_doot_migrations"

  test "getAppliedMigrations returns empty for fresh DB":
    let db = open(":memory:", "", "", "")
    defer: db.close()
    ensureMigrationsTable(db)

    let applied = getAppliedMigrations(db)
    check applied.len == 0

  test "runMigrations applies pending migrations":
    let db = open(":memory:", "", "", "")
    defer: db.close()

    let tmpDir = getTempDir() / "doot_test_runner_apply"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create a migration file that creates a table
    writeFile(tmpDir / "001_create_posts.sql",
      "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL);")

    let result = runMigrations(db, tmpDir)
    check result.applied == 1
    check result.errors.len == 0

    # Verify table was created
    let rows = db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type='table' AND name='posts'")
    check rows.len == 1

    # Verify migration was recorded
    let applied = getAppliedMigrations(db)
    check applied.len == 1
    check applied[0] == "001_create_posts.sql"

  test "runMigrations skips already-applied migrations":
    let db = open(":memory:", "", "", "")
    defer: db.close()

    let tmpDir = getTempDir() / "doot_test_runner_skip"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create two migration files
    writeFile(tmpDir / "001_create_posts.sql",
      "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL);")
    writeFile(tmpDir / "002_add_slug.sql",
      "ALTER TABLE posts ADD COLUMN slug TEXT;")

    # Run first time - applies both
    let result1 = runMigrations(db, tmpDir)
    check result1.applied == 2
    check result1.errors.len == 0

    # Run again - should skip both
    let result2 = runMigrations(db, tmpDir)
    check result2.applied == 0
    check result2.errors.len == 0

  test "runMigrations applies only new migrations":
    let db = open(":memory:", "", "", "")
    defer: db.close()

    let tmpDir = getTempDir() / "doot_test_runner_new"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create first migration and run
    writeFile(tmpDir / "001_create_posts.sql",
      "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL);")
    let result1 = runMigrations(db, tmpDir)
    check result1.applied == 1

    # Add second migration and run again
    writeFile(tmpDir / "002_add_slug.sql",
      "ALTER TABLE posts ADD COLUMN slug TEXT;")
    let result2 = runMigrations(db, tmpDir)
    check result2.applied == 1
    check result2.errors.len == 0

    # Verify both migrations recorded
    let applied = getAppliedMigrations(db)
    check applied.len == 2

  test "runMigrations fails fast on SQL error":
    let db = open(":memory:", "", "", "")
    defer: db.close()

    let tmpDir = getTempDir() / "doot_test_runner_fail"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # First migration is valid
    writeFile(tmpDir / "001_create_posts.sql",
      "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);")
    # Second migration has invalid SQL
    writeFile(tmpDir / "002_invalid.sql",
      "ALTER TABLE nonexistent_table ADD COLUMN foo TEXT;")
    # Third migration should never run
    writeFile(tmpDir / "003_add_slug.sql",
      "ALTER TABLE posts ADD COLUMN slug TEXT;")

    let result = runMigrations(db, tmpDir)
    # First migration applied, second failed, third not attempted
    check result.applied == 1
    check result.errors.len == 1
    check "002_invalid.sql" in result.errors[0]

    # Verify only first migration was recorded
    let applied = getAppliedMigrations(db)
    check applied.len == 1
    check applied[0] == "001_create_posts.sql"

  test "runMigrations handles multiple statements in one file":
    let db = open(":memory:", "", "", "")
    defer: db.close()

    let tmpDir = getTempDir() / "doot_test_runner_multi"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Migration with multiple statements
    writeFile(tmpDir / "001_create_tables.sql",
      "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);\nCREATE TABLE comments (id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT);")

    let result = runMigrations(db, tmpDir)
    check result.applied == 1
    check result.errors.len == 0

    # Verify both tables created
    let rows = db.getAllRows(sql"SELECT name FROM sqlite_master WHERE type='table' AND name IN ('posts', 'comments') ORDER BY name")
    check rows.len == 2

  test "runMigrations applies in sequential order":
    let db = open(":memory:", "", "", "")
    defer: db.close()

    let tmpDir = getTempDir() / "doot_test_runner_order"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # Create migrations that depend on order
    writeFile(tmpDir / "001_create_posts.sql",
      "CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT);")
    writeFile(tmpDir / "002_add_slug.sql",
      "ALTER TABLE posts ADD COLUMN slug TEXT;")
    writeFile(tmpDir / "003_add_body.sql",
      "ALTER TABLE posts ADD COLUMN body TEXT;")

    let result = runMigrations(db, tmpDir)
    check result.applied == 3
    check result.errors.len == 0

    # Verify all columns exist
    let rows = db.getAllRows(sql"PRAGMA table_info(posts)")
    var colNames: seq[string] = @[]
    for row in rows:
      colNames.add(row[1])
    check "id" in colNames
    check "title" in colNames
    check "slug" in colNames
    check "body" in colNames

  test "getPendingMigrations returns empty for nonexistent directory":
    let pending = getPendingMigrations("/nonexistent/dir", @[])
    check pending.len == 0

  test "getPendingMigrations sorts by filename":
    let tmpDir = getTempDir() / "doot_test_pending_sort"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    writeFile(tmpDir / "003_third.sql", "")
    writeFile(tmpDir / "001_first.sql", "")
    writeFile(tmpDir / "002_second.sql", "")

    let pending = getPendingMigrations(tmpDir, @[])
    check pending.len == 3
    check pending[0] == "001_first.sql"
    check pending[1] == "002_second.sql"
    check pending[2] == "003_third.sql"

  test "getPendingMigrations excludes applied":
    let tmpDir = getTempDir() / "doot_test_pending_exclude"
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    writeFile(tmpDir / "001_first.sql", "")
    writeFile(tmpDir / "002_second.sql", "")
    writeFile(tmpDir / "003_third.sql", "")

    let pending = getPendingMigrations(tmpDir, @["001_first.sql", "002_second.sql"])
    check pending.len == 1
    check pending[0] == "003_third.sql"
