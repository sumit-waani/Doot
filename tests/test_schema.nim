## Tests for DDL generation from Schema AST nodes.
## Verifies CREATE TABLE output, type mapping, constraints, and timestamps.

import unittest
import std/strutils
import db_connector/db_sqlite
import ../src/doot/ast
import ../src/doot/ddl
import ../src/doot/db_types
import ../src/doot/schema_utils

suite "DDL Generation":
  test "basic table with id column":
    let table = newTableNode("posts")
    let ddlSql = generateDDL(table)
    check ddlSql.contains("CREATE TABLE posts")
    check ddlSql.contains("id INTEGER PRIMARY KEY AUTOINCREMENT")

  test "field type mapping - string to TEXT":
    let table = newTableNode("posts")
    let field = newFieldNode("title", "string")
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("title TEXT")

  test "field type mapping - text to TEXT":
    let table = newTableNode("articles")
    let field = newFieldNode("body", "text")
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("body TEXT")

  test "field type mapping - integer to INTEGER":
    let table = newTableNode("posts")
    let field = newFieldNode("views", "integer")
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("views INTEGER")

  test "field type mapping - boolean to INTEGER":
    let table = newTableNode("posts")
    let field = newFieldNode("published", "boolean")
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("published INTEGER")

  test "field type mapping - float to REAL":
    let table = newTableNode("products")
    let field = newFieldNode("price", "float")
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("price REAL")

  test "field type mapping - datetime to TEXT":
    let table = newTableNode("events")
    let field = newFieldNode("starts_at", "datetime")
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("starts_at TEXT")

  test "required constraint produces NOT NULL":
    let table = newTableNode("posts")
    let field = newFieldNode("title", "string")
    field.fieldConstraints.add(Constraint(key: "required", value: newBoolLitNode(true)))
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("title TEXT NOT NULL")

  test "non-required field does not have NOT NULL":
    let table = newTableNode("posts")
    let field = newFieldNode("subtitle", "string")
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("subtitle TEXT")
    check not ddlSql.contains("subtitle TEXT NOT NULL")

  test "default string value":
    let table = newTableNode("users")
    let field = newFieldNode("role", "string")
    field.fieldConstraints.add(Constraint(key: "default", value: newStringLitNode("member")))
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("role TEXT DEFAULT 'member'")

  test "default integer value":
    let table = newTableNode("posts")
    let field = newFieldNode("views", "integer")
    field.fieldConstraints.add(Constraint(key: "default", value: newIntLitNode(0)))
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("views INTEGER DEFAULT 0")

  test "default boolean value":
    let table = newTableNode("posts")
    let field = newFieldNode("published", "boolean")
    field.fieldConstraints.add(Constraint(key: "default", value: newBoolLitNode(false)))
    table.tableFields.add(field)
    let ddlSql = generateDDL(table)
    check ddlSql.contains("published INTEGER DEFAULT 0")

  test "timestamps generates created_at and updated_at":
    let table = newTableNode("posts")
    table.hasTimestamps = true
    let ddlSql = generateDDL(table)
    check ddlSql.contains("created_at TEXT NOT NULL DEFAULT (datetime('now'))")
    check ddlSql.contains("updated_at TEXT NOT NULL DEFAULT (datetime('now'))")

  test "multiple fields in correct order":
    let table = newTableNode("posts")
    let titleField = newFieldNode("title", "string")
    titleField.fieldConstraints.add(Constraint(key: "required", value: newBoolLitNode(true)))
    let bodyField = newFieldNode("body", "text")
    bodyField.fieldConstraints.add(Constraint(key: "required", value: newBoolLitNode(true)))
    let publishedField = newFieldNode("published", "boolean")
    publishedField.fieldConstraints.add(Constraint(key: "default", value: newBoolLitNode(false)))
    table.tableFields.add(titleField)
    table.tableFields.add(bodyField)
    table.tableFields.add(publishedField)
    table.hasTimestamps = true
    let ddlSql = generateDDL(table)

    check ddlSql.contains("id INTEGER PRIMARY KEY AUTOINCREMENT")
    check ddlSql.contains("title TEXT NOT NULL")
    check ddlSql.contains("body TEXT NOT NULL")
    check ddlSql.contains("published INTEGER DEFAULT 0")
    check ddlSql.contains("created_at TEXT NOT NULL DEFAULT (datetime('now'))")
    check ddlSql.contains("updated_at TEXT NOT NULL DEFAULT (datetime('now'))")

  test "generateAllDDL processes all tables in schema":
    let schema = newSchemaNode()
    let postsTable = newTableNode("posts")
    postsTable.tableFields.add(newFieldNode("title", "string"))
    postsTable.hasTimestamps = true
    let usersTable = newTableNode("users")
    usersTable.tableFields.add(newFieldNode("email", "string"))
    schema.schemaTables.add(postsTable)
    schema.schemaTables.add(usersTable)

    let ddls = generateAllDDL(schema)
    check ddls.len == 2
    check ddls[0].contains("CREATE TABLE posts")
    check ddls[1].contains("CREATE TABLE users")

  test "generated DDL executes successfully on SQLite":
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

    let ddlSql = generateDDL(table)
    let db = open(":memory:", "", "", "")
    defer: db.close()

    db.exec(sql(ddlSql))
    # Verify table was created by inserting a row
    db.exec(sql"INSERT INTO posts (title, body) VALUES (?, ?)", "Hello", "World")
    let row = db.getRow(sql"SELECT id, title, body, published FROM posts WHERE id = 1")
    check row[0] == "1"
    check row[1] == "Hello"
    check row[2] == "World"
    check row[3] == "0"

suite "Schema Utils - TableNode to TableSchema":
  test "converts basic table":
    let table = newTableNode("posts")
    let titleField = newFieldNode("title", "string")
    titleField.fieldConstraints.add(Constraint(key: "required", value: newBoolLitNode(true)))
    titleField.fieldConstraints.add(Constraint(key: "max", value: newIntLitNode(200)))
    table.tableFields.add(titleField)
    table.hasTimestamps = true

    let schema = tableNodeToSchema(table)
    check schema.name == "posts"
    check schema.hasTimestamps == true
    check schema.fields.len == 1
    check schema.fields[0].name == "title"
    check schema.fields[0].fieldType == "string"
    check schema.fields[0].sqlType == "TEXT"
    check schema.fields[0].required == true
    check schema.fields[0].maxLength == 200

  test "converts field with default value":
    let table = newTableNode("users")
    let roleField = newFieldNode("role", "string")
    roleField.fieldConstraints.add(Constraint(key: "default", value: newStringLitNode("member")))
    table.tableFields.add(roleField)

    let schema = tableNodeToSchema(table)
    check schema.fields[0].defaultValue.kind == dvString
    check schema.fields[0].defaultValue.strVal == "member"

  test "converts multiple fields":
    let table = newTableNode("products")
    table.tableFields.add(newFieldNode("name", "string"))
    table.tableFields.add(newFieldNode("price", "float"))
    table.tableFields.add(newFieldNode("quantity", "integer"))
    table.tableFields.add(newFieldNode("active", "boolean"))

    let schema = tableNodeToSchema(table)
    check schema.fields.len == 4
    check schema.fields[0].sqlType == "TEXT"
    check schema.fields[1].sqlType == "REAL"
    check schema.fields[2].sqlType == "INTEGER"
    check schema.fields[3].sqlType == "INTEGER"
