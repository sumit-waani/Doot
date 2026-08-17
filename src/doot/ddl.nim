## DDL generation from Schema AST nodes.
## Converts TableNode/FieldNode AST into CREATE TABLE SQL statements.

import ast

proc mapFieldType*(fieldType: string): string =
  ## Maps Doot field types to SQLite column types.
  case fieldType
  of "string": "TEXT"
  of "text": "TEXT"
  of "integer": "INTEGER"
  of "boolean": "INTEGER"
  of "float": "REAL"
  of "datetime": "TEXT"
  else: "TEXT"

proc getDefaultValue*(field: DootNode): string =
  ## Extracts the DEFAULT clause for a field, if any.
  for c in field.fieldConstraints:
    if c.key == "default":
      if c.value != nil:
        case c.value.kind
        of nkStringLit:
          return " DEFAULT '" & c.value.strValue & "'"
        of nkIntLit:
          return " DEFAULT " & $c.value.intValue
        of nkBoolLit:
          if c.value.boolValue:
            return " DEFAULT 1"
          else:
            return " DEFAULT 0"
        else:
          discard
  return ""

proc isRequired*(field: DootNode): bool =
  ## Checks if a field has required: true constraint.
  for c in field.fieldConstraints:
    if c.key == "required":
      if c.value != nil and c.value.kind == nkBoolLit and c.value.boolValue:
        return true
  return false

proc generateFieldDDL*(field: DootNode): string =
  ## Generates the column definition for a single field.
  result = field.fieldName & " " & mapFieldType(field.fieldType)
  if isRequired(field):
    result &= " NOT NULL"
  result &= getDefaultValue(field)

proc generateDDL*(table: DootNode): string =
  ## Generates a CREATE TABLE statement from a TableNode.
  assert table.kind == nkTable
  var columns: seq[string] = @[]

  # Auto-generated id column
  columns.add("id INTEGER PRIMARY KEY AUTOINCREMENT")

  # Table fields
  for field in table.tableFields:
    columns.add(generateFieldDDL(field))

  # Timestamps
  if table.hasTimestamps:
    columns.add("created_at TEXT NOT NULL DEFAULT (datetime('now'))")
    columns.add("updated_at TEXT NOT NULL DEFAULT (datetime('now'))")

  result = "CREATE TABLE " & table.tableName & " (\n"
  for i, col in columns:
    result &= "  " & col
    if i < columns.len - 1:
      result &= ","
    result &= "\n"
  result &= ");"

proc generateAllDDL*(schema: DootNode): seq[string] =
  ## Generates CREATE TABLE statements for all tables in a schema node.
  assert schema.kind == nkSchema
  result = @[]
  for table in schema.schemaTables:
    result.add(generateDDL(table))
