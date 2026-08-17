## Schema snapshot serialization.
## Serializes schema AST to JSON and saves/loads .doot/schema_snapshot.json.

import std/[json, os]
import ast

type
  FieldSnapshot* = object
    name*: string
    fieldType*: string
    required*: bool
    maxLength*: int
    defaultValue*: string   # serialized as string representation

  TableSnapshot* = object
    name*: string
    fields*: seq[FieldSnapshot]
    hasTimestamps*: bool

proc fieldToJson(field: DootNode): JsonNode =
  ## Serializes a single field AST node to JSON.
  assert field.kind == nkField
  result = newJObject()
  result["name"] = newJString(field.fieldName)
  result["type"] = newJString(field.fieldType)

  var required = false
  var maxLength = 0
  var defaultValue = ""

  for c in field.fieldConstraints:
    case c.key
    of "required":
      if c.value != nil and c.value.kind == nkBoolLit:
        required = c.value.boolValue
    of "max":
      if c.value != nil and c.value.kind == nkIntLit:
        maxLength = c.value.intValue
    of "default":
      if c.value != nil:
        case c.value.kind
        of nkStringLit:
          defaultValue = "s:" & c.value.strValue
        of nkIntLit:
          defaultValue = "i:" & $c.value.intValue
        of nkBoolLit:
          defaultValue = "b:" & $c.value.boolValue
        else:
          discard
    else:
      discard

  result["required"] = newJBool(required)
  result["maxLength"] = newJInt(maxLength)
  result["defaultValue"] = newJString(defaultValue)

proc tableToJson(table: DootNode): JsonNode =
  ## Serializes a single table AST node to JSON.
  assert table.kind == nkTable
  result = newJObject()
  result["name"] = newJString(table.tableName)
  result["hasTimestamps"] = newJBool(table.hasTimestamps)

  var fields = newJArray()
  for field in table.tableFields:
    fields.add(fieldToJson(field))
  result["fields"] = fields

proc schemaToJson*(schema: DootNode): JsonNode =
  ## Serializes a schema AST (all tables) to JSON.
  assert schema.kind == nkSchema
  result = newJObject()
  var tables = newJArray()
  for table in schema.schemaTables:
    tables.add(tableToJson(table))
  result["tables"] = tables

proc jsonToFieldSnapshot(j: JsonNode): FieldSnapshot =
  ## Deserializes a field from JSON.
  result.name = j["name"].getStr()
  result.fieldType = j["type"].getStr()
  result.required = j["required"].getBool()
  result.maxLength = j["maxLength"].getInt()
  result.defaultValue = j["defaultValue"].getStr()

proc jsonToTableSnapshot(j: JsonNode): TableSnapshot =
  ## Deserializes a table from JSON.
  result.name = j["name"].getStr()
  result.hasTimestamps = j["hasTimestamps"].getBool()
  result.fields = @[]
  for fieldJ in j["fields"]:
    result.fields.add(jsonToFieldSnapshot(fieldJ))

proc jsonToSnapshot*(j: JsonNode): seq[TableSnapshot] =
  ## Deserializes the entire snapshot JSON to a sequence of TableSnapshot objects.
  result = @[]
  for tableJ in j["tables"]:
    result.add(jsonToTableSnapshot(tableJ))

proc saveSnapshot*(schema: DootNode, path: string) =
  ## Saves schema snapshot to the given file path.
  ## Creates parent directories if they don't exist.
  let dir = parentDir(path)
  if dir.len > 0:
    createDir(dir)
  let j = schemaToJson(schema)
  writeFile(path, j.pretty())

proc loadSnapshot*(path: string): seq[TableSnapshot] =
  ## Loads a schema snapshot from the given file path.
  ## Returns empty seq if file doesn't exist.
  if not fileExists(path):
    return @[]
  let content = readFile(path)
  let j = parseJson(content)
  return jsonToSnapshot(j)
