## Query interface for Doot database operations.
## Implements CRUD operations with parameterized SQL and validation.
## All queries use ? placeholders - no string concatenation of user values.

import std/[tables, options, strutils, strformat]
import db_connector/db_sqlite
import db_types

type
  SqlRow = db_sqlite.Row  # db_sqlite.Row is seq[string]

# Validation

proc validate*(schema: TableSchema, values: Table[string, DbValue], isUpdate: bool = false): seq[string] =
  ## Validates field values against schema constraints.
  ## Returns a list of error messages (empty if valid).
  var errors: seq[string] = @[]

  for field in schema.fields:
    if field.name in values:
      let val = values[field.name]
      # Check max length for string/text fields
      if field.maxLength > 0:
        case val.kind
        of dvString:
          if val.strVal.len > field.maxLength:
            errors.add(fmt"{field.name} exceeds maximum length of {field.maxLength}")
        of dvDatetime:
          if val.datetimeVal.len > field.maxLength:
            errors.add(fmt"{field.name} exceeds maximum length of {field.maxLength}")
        else:
          discard
      # Check required fields are not empty
      if field.required:
        case val.kind
        of dvNull:
          errors.add(fmt"{field.name} is required")
        of dvString:
          if val.strVal.len == 0:
            errors.add(fmt"{field.name} is required")
        else:
          discard
    else:
      # Field not provided
      if not isUpdate and field.required and field.defaultValue.isNull:
        errors.add(fmt"{field.name} is required")

  return errors

proc dbValueToSqlString(val: DbValue): string =
  ## Converts a DbValue to a string suitable for parameterized query binding.
  case val.kind
  of dvNull: ""
  of dvString: val.strVal
  of dvInt: $val.intVal
  of dvFloat: $val.floatVal
  of dvBool:
    if val.boolVal: "1" else: "0"
  of dvDatetime: val.datetimeVal

proc rowFromSqlRow(sqlRow: SqlRow, schema: TableSchema): db_types.Row =
  ## Converts a raw SQL result row into a typed Row object.
  ## Column order: id, then schema fields in order, then optionally created_at, updated_at
  result = newRow()

  # First column is always id
  if sqlRow.len > 0 and sqlRow[0].len > 0:
    result.id = parseBiggestInt(sqlRow[0])

  var colIdx = 1
  for field in schema.fields:
    if colIdx < sqlRow.len:
      let rawVal = sqlRow[colIdx]
      if rawVal.len == 0:
        result[field.name] = dbNull()
      else:
        case field.fieldType
        of "string", "text":
          result[field.name] = dbStr(rawVal)
        of "integer":
          result[field.name] = dbInt(parseBiggestInt(rawVal))
        of "boolean":
          result[field.name] = dbBool(rawVal != "0" and rawVal.len > 0)
        of "float":
          result[field.name] = dbFloat(parseFloat(rawVal))
        of "datetime":
          result[field.name] = dbDatetime(rawVal)
        else:
          result[field.name] = dbStr(rawVal)
    colIdx.inc

  # Timestamps
  if schema.hasTimestamps:
    if colIdx < sqlRow.len:
      let createdAt = sqlRow[colIdx]
      if createdAt.len > 0:
        result["created_at"] = dbDatetime(createdAt)
      else:
        result["created_at"] = dbNull()
      colIdx.inc
    if colIdx < sqlRow.len:
      let updatedAt = sqlRow[colIdx]
      if updatedAt.len > 0:
        result["updated_at"] = dbDatetime(updatedAt)
      else:
        result["updated_at"] = dbNull()
      colIdx.inc

# CRUD Operations

proc dbFind*(db: DbConn, schema: TableSchema, id: int): Option[db_types.Row] =
  ## SELECT by primary key. Returns Some(Row) or None.
  var selectCols: seq[string] = @["id"]
  for field in schema.fields:
    selectCols.add(field.name)
  if schema.hasTimestamps:
    selectCols.add("created_at")
    selectCols.add("updated_at")

  let querySql = "SELECT " & selectCols.join(", ") & " FROM " & schema.name & " WHERE id = ?"
  let row = db.getRow(sql(querySql), $id)

  # Check if row was found (all empty strings means not found)
  if row[0].len == 0:
    return none(db_types.Row)

  return some(rowFromSqlRow(row, schema))

proc dbCreate*(db: DbConn, schema: TableSchema, values: Table[string, DbValue]): DbResult =
  ## INSERT a new row with validation. Returns a DbResult with the created record.
  let errors = validate(schema, values)
  if errors.len > 0:
    return errResult(errors)

  var fieldNames: seq[string] = @[]
  var placeholders: seq[string] = @[]
  var params: seq[string] = @[]

  for field in schema.fields:
    if field.name in values:
      fieldNames.add(field.name)
      placeholders.add("?")
      params.add(dbValueToSqlString(values[field.name]))
    elif not field.defaultValue.isNull:
      fieldNames.add(field.name)
      placeholders.add("?")
      params.add(dbValueToSqlString(field.defaultValue))

  let insertSql = "INSERT INTO " & schema.name & " (" &
            fieldNames.join(", ") & ") VALUES (" &
            placeholders.join(", ") & ")"

  let lastId = db.insertID(sql(insertSql), params)

  # Fetch the created row
  let found = dbFind(db, schema, int(lastId))
  if found.isSome:
    return okResult(found.get)
  else:
    # Should not happen, but handle gracefully
    let row = newRow(lastId)
    for field in schema.fields:
      if field.name in values:
        row[field.name] = values[field.name]
    return okResult(row)

proc dbFindBy*(db: DbConn, schema: TableSchema, field: string, value: DbValue): Option[db_types.Row] =
  ## SELECT by arbitrary field. Returns first match or None.
  var selectCols: seq[string] = @["id"]
  for f in schema.fields:
    selectCols.add(f.name)
  if schema.hasTimestamps:
    selectCols.add("created_at")
    selectCols.add("updated_at")

  let querySql = "SELECT " & selectCols.join(", ") & " FROM " & schema.name &
            " WHERE " & field & " = ? LIMIT 1"
  let row = db.getRow(sql(querySql), dbValueToSqlString(value))

  if row[0].len == 0:
    return none(db_types.Row)

  return some(rowFromSqlRow(row, schema))

proc dbAll*(db: DbConn, schema: TableSchema, where: string = "",
            whereParams: seq[string] = @[], order: string = "",
            limit: int = 0): seq[db_types.Row] =
  ## SELECT with optional filtering, ordering, and limit.
  ## The where clause should use ? placeholders with values in whereParams.
  var selectCols: seq[string] = @["id"]
  for field in schema.fields:
    selectCols.add(field.name)
  if schema.hasTimestamps:
    selectCols.add("created_at")
    selectCols.add("updated_at")

  var querySql = "SELECT " & selectCols.join(", ") & " FROM " & schema.name

  if where.len > 0:
    querySql &= " WHERE " & where

  if order.len > 0:
    querySql &= " ORDER BY " & order

  if limit > 0:
    querySql &= " LIMIT " & $limit

  let rows = db.getAllRows(sql(querySql), whereParams)

  result = @[]
  for sqlRow in rows:
    if sqlRow[0].len > 0:
      result.add(rowFromSqlRow(sqlRow, schema))

proc dbUpdate*(db: DbConn, schema: TableSchema, row: db_types.Row,
               values: Table[string, DbValue]): DbResult =
  ## UPDATE a row with validation. Returns a DbResult.
  let errors = validate(schema, values, isUpdate = true)
  if errors.len > 0:
    return errResult(errors)

  var setClauses: seq[string] = @[]
  var params: seq[string] = @[]

  for field in schema.fields:
    if field.name in values:
      setClauses.add(field.name & " = ?")
      params.add(dbValueToSqlString(values[field.name]))

  if schema.hasTimestamps:
    setClauses.add("updated_at = datetime('now')")

  if setClauses.len == 0:
    return okResult(row)

  params.add($row.id)

  let updateSql = "UPDATE " & schema.name & " SET " &
            setClauses.join(", ") & " WHERE id = ?"

  db.exec(sql(updateSql), params)

  # Fetch the updated row
  let found = dbFind(db, schema, int(row.id))
  if found.isSome:
    return okResult(found.get)
  else:
    return okResult(row)

proc dbDelete*(db: DbConn, schema: TableSchema, row: db_types.Row): DbResult =
  ## DELETE a row by primary key. Returns a DbResult.
  let deleteSql = "DELETE FROM " & schema.name & " WHERE id = ?"
  db.exec(sql(deleteSql), $row.id)
  return okResult(row)
