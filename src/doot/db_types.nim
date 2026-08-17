## Database types for the Doot query interface.
## Defines DbValue (variant for column values), Row (typed record),
## DbResult (operation result with validation errors), and TableSchema
## (runtime schema representation for validation and query generation).

import std/tables

type
  DbValueKind* = enum
    dvNull
    dvString
    dvInt
    dvFloat
    dvBool
    dvDatetime

  DbValue* = object
    case kind*: DbValueKind
    of dvNull:
      discard
    of dvString:
      strVal*: string
    of dvInt:
      intVal*: int64
    of dvFloat:
      floatVal*: float
    of dvBool:
      boolVal*: bool
    of dvDatetime:
      datetimeVal*: string

  Row* = ref object
    fields*: OrderedTable[string, DbValue]
    id*: int64

  DbResult* = object
    ok*: bool
    errors*: seq[string]
    record*: Row

  FieldSchema* = object
    name*: string
    fieldType*: string        # "string", "text", "integer", "boolean", "float", "datetime"
    sqlType*: string          # "TEXT", "INTEGER", "REAL", etc.
    required*: bool
    maxLength*: int           # 0 means no limit
    defaultValue*: DbValue

  TableSchema* = object
    name*: string
    fields*: seq[FieldSchema]
    hasTimestamps*: bool

# DbValue constructors

proc dbNull*(): DbValue =
  DbValue(kind: dvNull)

proc dbStr*(v: string): DbValue =
  DbValue(kind: dvString, strVal: v)

proc dbInt*(v: int64): DbValue =
  DbValue(kind: dvInt, intVal: v)

proc dbFloat*(v: float): DbValue =
  DbValue(kind: dvFloat, floatVal: v)

proc dbBool*(v: bool): DbValue =
  DbValue(kind: dvBool, boolVal: v)

proc dbDatetime*(v: string): DbValue =
  DbValue(kind: dvDatetime, datetimeVal: v)

# Row helpers

proc newRow*(id: int64 = 0): Row =
  Row(id: id, fields: initOrderedTable[string, DbValue]())

proc `[]`*(row: Row, field: string): DbValue =
  row.fields[field]

proc `[]=`*(row: Row, field: string, value: DbValue) =
  row.fields[field] = value

proc getString*(row: Row, field: string): string =
  let v = row.fields[field]
  case v.kind
  of dvString: v.strVal
  of dvDatetime: v.datetimeVal
  else: ""

proc getInt*(row: Row, field: string): int64 =
  let v = row.fields[field]
  case v.kind
  of dvInt: v.intVal
  of dvBool:
    if v.boolVal: 1'i64 else: 0'i64
  else: 0'i64

proc getFloat*(row: Row, field: string): float =
  let v = row.fields[field]
  case v.kind
  of dvFloat: v.floatVal
  of dvInt: float(v.intVal)
  else: 0.0

proc getBool*(row: Row, field: string): bool =
  let v = row.fields[field]
  case v.kind
  of dvBool: v.boolVal
  of dvInt: v.intVal != 0
  else: false

proc isNull*(v: DbValue): bool =
  v.kind == dvNull

# DbResult helpers

proc okResult*(record: Row): DbResult =
  DbResult(ok: true, errors: @[], record: record)

proc errResult*(errors: seq[string]): DbResult =
  DbResult(ok: false, errors: errors, record: nil)
