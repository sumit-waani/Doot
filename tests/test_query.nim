## Tests for CRUD operations, validation, and Result objects.
## Uses an actual in-memory SQLite database.

import unittest
import std/[tables, options, strutils]
import db_connector/db_sqlite
import ../src/doot/ast
import ../src/doot/ddl
import ../src/doot/db_types
import ../src/doot/schema_utils
import ../src/doot/query

# Helper to set up a test database with a posts table
proc setupTestDb(): tuple[db: DbConn, schema: TableSchema] =
  let db = open(":memory:", "", "", "")

  # Build the table AST
  let table = newTableNode("posts")
  let titleField = newFieldNode("title", "string")
  titleField.fieldConstraints.add(Constraint(key: "required", value: newBoolLitNode(true)))
  titleField.fieldConstraints.add(Constraint(key: "max", value: newIntLitNode(200)))
  let bodyField = newFieldNode("body", "text")
  bodyField.fieldConstraints.add(Constraint(key: "required", value: newBoolLitNode(true)))
  let publishedField = newFieldNode("published", "boolean")
  publishedField.fieldConstraints.add(Constraint(key: "default", value: newBoolLitNode(false)))
  table.tableFields.add(titleField)
  table.tableFields.add(bodyField)
  table.tableFields.add(publishedField)
  table.hasTimestamps = true

  # Generate and execute DDL
  let ddlSql = generateDDL(table)
  db.exec(sql(ddlSql))

  # Build the TableSchema
  let schema = tableNodeToSchema(table)
  return (db, schema)

suite "dbCreate - INSERT operations":
  test "creates a row with valid data and returns ok result":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Hello World")
    values["body"] = dbStr("This is a test post")

    let result = dbCreate(db, schema, values)
    check result.ok == true
    check result.errors.len == 0
    check result.record != nil
    check result.record.id == 1
    check result.record.getString("title") == "Hello World"
    check result.record.getString("body") == "This is a test post"

  test "creates multiple rows with incrementing ids":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values1 = initTable[string, DbValue]()
    values1["title"] = dbStr("First Post")
    values1["body"] = dbStr("Body 1")
    let r1 = dbCreate(db, schema, values1)

    var values2 = initTable[string, DbValue]()
    values2["title"] = dbStr("Second Post")
    values2["body"] = dbStr("Body 2")
    let r2 = dbCreate(db, schema, values2)

    check r1.record.id == 1
    check r2.record.id == 2

  test "applies default values when field not provided":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Test")
    values["body"] = dbStr("Body")

    let result = dbCreate(db, schema, values)
    check result.ok == true
    # published defaults to false (0)
    check result.record.getBool("published") == false

  test "fails with missing required field":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Hello")
    # body is required but not provided

    let result = dbCreate(db, schema, values)
    check result.ok == false
    check result.errors.len > 0
    check "body is required" in result.errors

  test "fails with empty string for required field":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("")
    values["body"] = dbStr("Some body")

    let result = dbCreate(db, schema, values)
    check result.ok == false
    check "title is required" in result.errors

  test "fails with max length violation":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("x".repeat(201))
    values["body"] = dbStr("Body")

    let result = dbCreate(db, schema, values)
    check result.ok == false
    check result.errors.len > 0
    check "title exceeds maximum length of 200" in result.errors

  test "max length at boundary passes":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("x".repeat(200))
    values["body"] = dbStr("Body")

    let result = dbCreate(db, schema, values)
    check result.ok == true

suite "dbFind - SELECT by primary key":
  test "finds existing row by id":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Find Me")
    values["body"] = dbStr("Body")
    discard dbCreate(db, schema, values)

    let found = dbFind(db, schema, 1)
    check found.isSome
    check found.get.id == 1
    check found.get.getString("title") == "Find Me"
    check found.get.getString("body") == "Body"

  test "returns None for non-existent id":
    let (db, schema) = setupTestDb()
    defer: db.close()

    let found = dbFind(db, schema, 999)
    check found.isNone

  test "returns correct row among multiple":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var v1 = initTable[string, DbValue]()
    v1["title"] = dbStr("First")
    v1["body"] = dbStr("Body 1")
    discard dbCreate(db, schema, v1)

    var v2 = initTable[string, DbValue]()
    v2["title"] = dbStr("Second")
    v2["body"] = dbStr("Body 2")
    discard dbCreate(db, schema, v2)

    let found = dbFind(db, schema, 2)
    check found.isSome
    check found.get.getString("title") == "Second"

suite "dbFindBy - SELECT by field value":
  test "finds row by field value":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Unique Title")
    values["body"] = dbStr("Body")
    discard dbCreate(db, schema, values)

    let found = dbFindBy(db, schema, "title", dbStr("Unique Title"))
    check found.isSome
    check found.get.getString("title") == "Unique Title"

  test "returns None when no match":
    let (db, schema) = setupTestDb()
    defer: db.close()

    let found = dbFindBy(db, schema, "title", dbStr("Does Not Exist"))
    check found.isNone

  test "returns first match when multiple exist":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var v1 = initTable[string, DbValue]()
    v1["title"] = dbStr("Same Title")
    v1["body"] = dbStr("Body 1")
    discard dbCreate(db, schema, v1)

    var v2 = initTable[string, DbValue]()
    v2["title"] = dbStr("Same Title")
    v2["body"] = dbStr("Body 2")
    discard dbCreate(db, schema, v2)

    let found = dbFindBy(db, schema, "title", dbStr("Same Title"))
    check found.isSome
    check found.get.id == 1

suite "dbAll - SELECT multiple rows":
  test "returns all rows":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var v1 = initTable[string, DbValue]()
    v1["title"] = dbStr("Post A")
    v1["body"] = dbStr("Body A")
    discard dbCreate(db, schema, v1)

    var v2 = initTable[string, DbValue]()
    v2["title"] = dbStr("Post B")
    v2["body"] = dbStr("Body B")
    discard dbCreate(db, schema, v2)

    var v3 = initTable[string, DbValue]()
    v3["title"] = dbStr("Post C")
    v3["body"] = dbStr("Body C")
    discard dbCreate(db, schema, v3)

    let rows = dbAll(db, schema)
    check rows.len == 3

  test "returns empty seq when no rows":
    let (db, schema) = setupTestDb()
    defer: db.close()

    let rows = dbAll(db, schema)
    check rows.len == 0

  test "returns rows with order":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var v1 = initTable[string, DbValue]()
    v1["title"] = dbStr("B Post")
    v1["body"] = dbStr("Body")
    discard dbCreate(db, schema, v1)

    var v2 = initTable[string, DbValue]()
    v2["title"] = dbStr("A Post")
    v2["body"] = dbStr("Body")
    discard dbCreate(db, schema, v2)

    let rows = dbAll(db, schema, order = "title ASC")
    check rows.len == 2
    check rows[0].getString("title") == "A Post"
    check rows[1].getString("title") == "B Post"

  test "returns rows with descending order":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var v1 = initTable[string, DbValue]()
    v1["title"] = dbStr("First")
    v1["body"] = dbStr("Body")
    discard dbCreate(db, schema, v1)

    var v2 = initTable[string, DbValue]()
    v2["title"] = dbStr("Second")
    v2["body"] = dbStr("Body")
    discard dbCreate(db, schema, v2)

    let rows = dbAll(db, schema, order = "id DESC")
    check rows.len == 2
    check rows[0].getString("title") == "Second"
    check rows[1].getString("title") == "First"

  test "returns rows with limit":
    let (db, schema) = setupTestDb()
    defer: db.close()

    for i in 1..5:
      var v = initTable[string, DbValue]()
      v["title"] = dbStr("Post " & $i)
      v["body"] = dbStr("Body")
      discard dbCreate(db, schema, v)

    let rows = dbAll(db, schema, limit = 2)
    check rows.len == 2

  test "returns rows with where clause":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var v1 = initTable[string, DbValue]()
    v1["title"] = dbStr("Published Post")
    v1["body"] = dbStr("Body")
    v1["published"] = dbBool(true)
    discard dbCreate(db, schema, v1)

    var v2 = initTable[string, DbValue]()
    v2["title"] = dbStr("Draft Post")
    v2["body"] = dbStr("Body")
    v2["published"] = dbBool(false)
    discard dbCreate(db, schema, v2)

    let rows = dbAll(db, schema, where = "published = ?", whereParams = @["1"])
    check rows.len == 1
    check rows[0].getString("title") == "Published Post"

suite "dbUpdate - UPDATE operations":
  test "updates fields and returns ok result":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Original Title")
    values["body"] = dbStr("Original Body")
    let createResult = dbCreate(db, schema, values)

    var updateValues = initTable[string, DbValue]()
    updateValues["title"] = dbStr("New Title")

    let updateResult = dbUpdate(db, schema, createResult.record, updateValues)
    check updateResult.ok == true
    check updateResult.record.getString("title") == "New Title"
    # Body should remain unchanged
    check updateResult.record.getString("body") == "Original Body"

  test "update with validation failure returns errors":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Original")
    values["body"] = dbStr("Body")
    let createResult = dbCreate(db, schema, values)

    var updateValues = initTable[string, DbValue]()
    updateValues["title"] = dbStr("x".repeat(201))

    let updateResult = dbUpdate(db, schema, createResult.record, updateValues)
    check updateResult.ok == false
    check "title exceeds maximum length of 200" in updateResult.errors

  test "update with empty required field fails":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Original")
    values["body"] = dbStr("Body")
    let createResult = dbCreate(db, schema, values)

    var updateValues = initTable[string, DbValue]()
    updateValues["title"] = dbStr("")

    let updateResult = dbUpdate(db, schema, createResult.record, updateValues)
    check updateResult.ok == false
    check "title is required" in updateResult.errors

suite "dbDelete - DELETE operations":
  test "deletes a row from the database":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("To Delete")
    values["body"] = dbStr("Body")
    let createResult = dbCreate(db, schema, values)

    let deleteResult = dbDelete(db, schema, createResult.record)
    check deleteResult.ok == true

    # Verify row is gone
    let found = dbFind(db, schema, int(createResult.record.id))
    check found.isNone

  test "delete does not affect other rows":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var v1 = initTable[string, DbValue]()
    v1["title"] = dbStr("Keep This")
    v1["body"] = dbStr("Body 1")
    discard dbCreate(db, schema, v1)

    var v2 = initTable[string, DbValue]()
    v2["title"] = dbStr("Delete This")
    v2["body"] = dbStr("Body 2")
    let r2 = dbCreate(db, schema, v2)

    discard dbDelete(db, schema, r2.record)

    let remaining = dbAll(db, schema)
    check remaining.len == 1
    check remaining[0].getString("title") == "Keep This"

suite "DbResult pattern":
  test "ok result has ok=true and record":
    let row = newRow(1)
    row["title"] = dbStr("Test")
    let result = okResult(row)
    check result.ok == true
    check result.errors.len == 0
    check result.record != nil
    check result.record.id == 1

  test "error result has ok=false and errors":
    let result = errResult(@["field is required", "another error"])
    check result.ok == false
    check result.errors.len == 2
    check "field is required" in result.errors
    check "another error" in result.errors
    check result.record == nil

suite "Row type access":
  test "getString returns string value":
    let row = newRow(1)
    row["name"] = dbStr("hello")
    check row.getString("name") == "hello"

  test "getInt returns int value":
    let row = newRow(1)
    row["count"] = dbInt(42)
    check row.getInt("count") == 42

  test "getFloat returns float value":
    let row = newRow(1)
    row["price"] = dbFloat(19.99)
    check row.getFloat("price") == 19.99

  test "getBool returns bool value":
    let row = newRow(1)
    row["active"] = dbBool(true)
    check row.getBool("active") == true

  test "isNull checks null values":
    let v = dbNull()
    check v.isNull == true
    let s = dbStr("hello")
    check s.isNull == false

suite "Parameterized queries verification":
  test "create uses parameterized SQL (not string concat)":
    # This test verifies that the database operations work correctly
    # with special characters that would break non-parameterized queries
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Robert'); DROP TABLE posts;--")
    values["body"] = dbStr("SQL injection attempt")

    let result = dbCreate(db, schema, values)
    check result.ok == true

    # Table should still exist and contain the row
    let found = dbFind(db, schema, 1)
    check found.isSome
    check found.get.getString("title") == "Robert'); DROP TABLE posts;--"

  test "find_by uses parameterized SQL":
    let (db, schema) = setupTestDb()
    defer: db.close()

    var values = initTable[string, DbValue]()
    values["title"] = dbStr("Normal Post")
    values["body"] = dbStr("Body")
    discard dbCreate(db, schema, values)

    # Try to inject via the search value
    let found = dbFindBy(db, schema, "title", dbStr("' OR '1'='1"))
    check found.isNone
