## Utility to convert parsed AST TableNode/FieldNode into TableSchema objects.
## This bridges the AST representation with the runtime query interface.

import ast, db_types, ddl

proc fieldNodeToSchema*(node: DootNode): FieldSchema =
  ## Converts an nkField AST node to a FieldSchema for runtime use.
  assert node.kind == nkField
  result.name = node.fieldName
  result.fieldType = node.fieldType
  result.sqlType = mapFieldType(node.fieldType)
  result.required = false
  result.maxLength = 0
  result.defaultValue = dbNull()

  for c in node.fieldConstraints:
    case c.key
    of "required":
      if c.value != nil and c.value.kind == nkBoolLit:
        result.required = c.value.boolValue
    of "max":
      if c.value != nil and c.value.kind == nkIntLit:
        result.maxLength = c.value.intValue
    of "default":
      if c.value != nil:
        case c.value.kind
        of nkStringLit:
          result.defaultValue = dbStr(c.value.strValue)
        of nkIntLit:
          result.defaultValue = dbInt(int64(c.value.intValue))
        of nkBoolLit:
          result.defaultValue = dbBool(c.value.boolValue)
        else:
          discard
    else:
      discard

proc tableNodeToSchema*(node: DootNode): TableSchema =
  ## Converts an nkTable AST node to a TableSchema for runtime use.
  assert node.kind == nkTable
  result.name = node.tableName
  result.hasTimestamps = node.hasTimestamps
  result.fields = @[]
  for field in node.tableFields:
    result.fields.add(fieldNodeToSchema(field))
