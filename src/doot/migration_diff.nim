## Migration diffing engine.
## Compares current schema AST against a stored snapshot to detect changes.
## Classifies changes as additive (safe) or destructive.

import ast, schema_snapshot

type
  SchemaChangeKind* = enum
    AddTable
    DropTable
    AddColumn
    DropColumn
    ChangeColumnType

  SchemaChange* = object
    case kind*: SchemaChangeKind
    of AddTable:
      addTableNode*: DootNode       # The full nkTable node to create
    of DropTable:
      dropTableName*: string
    of AddColumn:
      addColTable*: string          # Table name
      addColField*: DootNode        # The nkField node to add
    of DropColumn:
      dropColTable*: string         # Table name
      dropColName*: string          # Column name
    of ChangeColumnType:
      changeColTable*: string       # Table name
      changeColName*: string        # Column name
      changeColOldType*: string     # Previous type
      changeColNewType*: string     # New type

proc isDestructive*(change: SchemaChange): bool =
  ## Returns true if the change is destructive (requires confirmation).
  ## DropTable, DropColumn, and ChangeColumnType are destructive.
  ## AddTable and AddColumn are additive (safe).
  case change.kind
  of DropTable, DropColumn, ChangeColumnType:
    return true
  of AddTable, AddColumn:
    return false

proc diffSchema*(current: DootNode, previous: seq[TableSnapshot]): seq[SchemaChange] =
  ## Compares current schema AST against previous snapshot.
  ## Returns a sequence of detected changes.
  assert current.kind == nkSchema
  result = @[]

  # Build lookup of previous table names
  var prevTableNames: seq[string] = @[]
  for t in previous:
    prevTableNames.add(t.name)

  # Build lookup of current table names
  var currTableNames: seq[string] = @[]
  for t in current.schemaTables:
    currTableNames.add(t.tableName)

  # Detect new tables (in current but not in previous)
  for table in current.schemaTables:
    if table.tableName notin prevTableNames:
      result.add(SchemaChange(kind: AddTable, addTableNode: table))
    else:
      # Table exists in both - check for field changes
      var prevTable: TableSnapshot
      for pt in previous:
        if pt.name == table.tableName:
          prevTable = pt
          break

      # Get previous field names
      var prevFieldNames: seq[string] = @[]
      for f in prevTable.fields:
        prevFieldNames.add(f.name)

      # Get current field names
      var currFieldNames: seq[string] = @[]
      for f in table.tableFields:
        currFieldNames.add(f.fieldName)

      # Detect new columns (in current but not in previous)
      for field in table.tableFields:
        if field.fieldName notin prevFieldNames:
          result.add(SchemaChange(kind: AddColumn,
                                  addColTable: table.tableName,
                                  addColField: field))
        else:
          # Field exists in both - check for type change
          for prevField in prevTable.fields:
            if prevField.name == field.fieldName:
              if prevField.fieldType != field.fieldType:
                result.add(SchemaChange(kind: ChangeColumnType,
                                        changeColTable: table.tableName,
                                        changeColName: field.fieldName,
                                        changeColOldType: prevField.fieldType,
                                        changeColNewType: field.fieldType))
              break

      # Detect dropped columns (in previous but not in current)
      for prevField in prevTable.fields:
        if prevField.name notin currFieldNames:
          result.add(SchemaChange(kind: DropColumn,
                                  dropColTable: table.tableName,
                                  dropColName: prevField.name))

  # Detect dropped tables (in previous but not in current)
  for prevTable in previous:
    if prevTable.name notin currTableNames:
      result.add(SchemaChange(kind: DropTable,
                              dropTableName: prevTable.name))
