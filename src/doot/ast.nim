## AST node types for the Doot DSL compiler.
## Uses Nim object variants with a NodeKind enum discriminator.
## Every node carries position info (file, line, col) for error reporting.

type
  NodeKind* = enum
    # Top-level / Application
    nkApp
    nkConfig
    nkConfigDirective
    nkSchema
    nkTable
    nkField
    nkAuth
    nkMount

    # Route / Handler
    nkRoute
    nkGroup
    nkHandlerBody
    nkRender
    nkRedirect
    nkDbQuery
    nkAssignment
    nkIf
    nkEach
    nkNativeBlock

    # Template
    nkTemplate
    nkExtends
    nkBlockDef
    nkElement
    nkExprOutput
    nkText
    nkPartial
    nkTemplateIf
    nkTemplateEach

    # Jobs / Scheduler
    nkJob
    nkSchedule
    nkEnqueue

    # Expressions
    nkStringLit
    nkIntLit
    nkBoolLit
    nkNil
    nkIdentifier
    nkMemberAccess
    nkMethodCall
    nkIndexAccess
    nkBinaryOp
    nkUnaryOp
    nkArrayLit
    nkEnvCall

  Constraint* = object
    key*: string
    value*: DootNode

  KeyValuePair* = object
    key*: string
    value*: DootNode

  DootNode* = ref object
    file*: string
    line*: int
    col*: int
    case kind*: NodeKind
    of nkApp:
      appConfig*: DootNode          # nkConfig or nil
      appSchema*: DootNode          # nkSchema or nil
      appMounts*: seq[DootNode]     # seq of nkMount
      appRoutes*: seq[DootNode]     # seq of nkRoute or nkGroup

    of nkConfig:
      configDirectives*: seq[DootNode]  # seq of nkConfigDirective

    of nkConfigDirective:
      directiveKey*: string
      directiveValue*: DootNode     # expression node

    of nkSchema:
      schemaTables*: seq[DootNode]  # seq of nkTable
      schemaAuth*: DootNode         # nkAuth or nil

    of nkTable:
      tableName*: string
      tableFields*: seq[DootNode]   # seq of nkField
      hasTimestamps*: bool

    of nkField:
      fieldName*: string
      fieldType*: string            # "string", "text", "integer", etc.
      fieldConstraints*: seq[Constraint]

    of nkAuth:
      authModel*: string
      authRoles*: seq[string]
      emailVerification*: bool

    of nkMount:
      mountPath*: string

    of nkRoute:
      httpMethod*: string           # "GET", "POST", etc.
      routePath*: string
      routeAuth*: string            # "public", "required", "" (none specified)
      routeRole*: string            # role requirement or ""
      routeParam*: string           # handler parameter name, e.g. "ctx"
      routeBody*: seq[DootNode]     # handler statements

    of nkGroup:
      groupAuth*: string
      groupRole*: string
      groupChildren*: seq[DootNode] # seq of nkRoute

    of nkHandlerBody:
      bodyStatements*: seq[DootNode]

    of nkRender:
      renderPath*: string
      renderLocals*: seq[KeyValuePair]

    of nkRedirect:
      redirectExpr*: DootNode       # expression for the path

    of nkDbQuery:
      dbTable*: string
      dbMethod*: string
      dbArgs*: seq[DootNode]        # expression arguments

    of nkAssignment:
      assignName*: string
      assignValue*: DootNode        # expression

    of nkIf:
      ifCondition*: DootNode        # expression
      ifThen*: seq[DootNode]        # then-branch statements
      ifElse*: seq[DootNode]        # else-branch statements (empty if no else)

    of nkEach:
      eachVar*: string
      eachCollection*: DootNode     # expression
      eachBody*: seq[DootNode]      # body statements

    of nkNativeBlock:
      nativeContent*: string

    of nkJob:
      jobName*: string
      jobParam*: string
      jobBody*: seq[DootNode]

    of nkSchedule:
      scheduleName*: string
      scheduleInterval*: string
      scheduleBody*: seq[DootNode]

    of nkEnqueue:
      enqueueName*: string
      enqueueArgs*: seq[KeyValuePair]

    of nkTemplate:
      tmplExtends*: string          # extends path or "" if none
      tmplBlocks*: seq[DootNode]    # seq of nkBlockDef
      tmplBody*: seq[DootNode]      # body elements

    of nkExtends:
      extendsPath*: string

    of nkBlockDef:
      blockName*: string
      blockContent*: seq[DootNode]  # content nodes

    of nkElement:
      elemTag*: string
      elemClasses*: seq[string]
      elemId*: string
      elemAttrs*: seq[KeyValuePair]
      elemChildren*: seq[DootNode]
      elemText*: string             # text content or ""
      elemExprOutput*: DootNode     # expression output or nil
      elemEscaped*: bool            # true for =, false for !=

    of nkExprOutput:
      exprOutExpr*: DootNode        # expression
      exprOutEscaped*: bool         # true = escaped (=), false = unescaped (!=)

    of nkText:
      textContent*: string

    of nkPartial:
      partialPath*: string
      partialLocals*: seq[KeyValuePair]

    of nkTemplateIf:
      tmplIfCondition*: DootNode
      tmplIfThen*: seq[DootNode]
      tmplIfElse*: seq[DootNode]

    of nkTemplateEach:
      tmplEachVar*: string
      tmplEachCollection*: DootNode
      tmplEachBody*: seq[DootNode]

    # Expressions
    of nkStringLit:
      strValue*: string
      strInterpolations*: seq[DootNode]  # interpolation expression parts

    of nkIntLit:
      intValue*: int

    of nkBoolLit:
      boolValue*: bool

    of nkNil:
      discard

    of nkIdentifier:
      identName*: string

    of nkMemberAccess:
      memberObj*: DootNode
      memberProp*: string

    of nkMethodCall:
      callObj*: DootNode
      callMethod*: string
      callArgs*: seq[DootNode]

    of nkIndexAccess:
      indexObj*: DootNode
      indexExpr*: DootNode

    of nkBinaryOp:
      binLeft*: DootNode
      binOp*: string
      binRight*: DootNode

    of nkUnaryOp:
      unaryOp*: string
      unaryOperand*: DootNode

    of nkArrayLit:
      arrayElements*: seq[DootNode]

    of nkEnvCall:
      envArg*: string

# Constructors

proc newAppNode*(file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkApp, file: file, line: line, col: col,
           appConfig: nil, appSchema: nil, appMounts: @[], appRoutes: @[])

proc newConfigNode*(file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkConfig, file: file, line: line, col: col, configDirectives: @[])

proc newConfigDirectiveNode*(key: string, value: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkConfigDirective, file: file, line: line, col: col,
           directiveKey: key, directiveValue: value)

proc newSchemaNode*(file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkSchema, file: file, line: line, col: col,
           schemaTables: @[], schemaAuth: nil)

proc newTableNode*(name: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkTable, file: file, line: line, col: col,
           tableName: name, tableFields: @[], hasTimestamps: false)

proc newFieldNode*(name: string, fieldType: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkField, file: file, line: line, col: col,
           fieldName: name, fieldType: fieldType, fieldConstraints: @[])

proc newAuthNode*(model: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkAuth, file: file, line: line, col: col,
           authModel: model, authRoles: @[], emailVerification: false)

proc newMountNode*(path: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkMount, file: file, line: line, col: col, mountPath: path)

proc newRouteNode*(httpMethod: string, path: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkRoute, file: file, line: line, col: col,
           httpMethod: httpMethod, routePath: path, routeAuth: "", routeRole: "",
           routeParam: "", routeBody: @[])

proc newGroupNode*(file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkGroup, file: file, line: line, col: col,
           groupAuth: "", groupRole: "", groupChildren: @[])

proc newHandlerBodyNode*(file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkHandlerBody, file: file, line: line, col: col, bodyStatements: @[])

proc newRenderNode*(path: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkRender, file: file, line: line, col: col,
           renderPath: path, renderLocals: @[])

proc newRedirectNode*(expr: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkRedirect, file: file, line: line, col: col, redirectExpr: expr)

proc newDbQueryNode*(table: string, meth: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkDbQuery, file: file, line: line, col: col,
           dbTable: table, dbMethod: meth, dbArgs: @[])

proc newAssignmentNode*(name: string, value: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkAssignment, file: file, line: line, col: col,
           assignName: name, assignValue: value)

proc newIfNode*(cond: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkIf, file: file, line: line, col: col,
           ifCondition: cond, ifThen: @[], ifElse: @[])

proc newEachNode*(varName: string, collection: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkEach, file: file, line: line, col: col,
           eachVar: varName, eachCollection: collection, eachBody: @[])

proc newNativeBlockNode*(content: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkNativeBlock, file: file, line: line, col: col, nativeContent: content)

proc newJobNode*(name: string, param: string, body: seq[DootNode] = @[], file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkJob, file: file, line: line, col: col,
           jobName: name, jobParam: param, jobBody: body)

proc newScheduleNode*(name: string, interval: string, body: seq[DootNode] = @[], file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkSchedule, file: file, line: line, col: col,
           scheduleName: name, scheduleInterval: interval, scheduleBody: body)

proc newEnqueueNode*(name: string, args: seq[KeyValuePair] = @[], file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkEnqueue, file: file, line: line, col: col,
           enqueueName: name, enqueueArgs: args)

proc newTemplateNode*(file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkTemplate, file: file, line: line, col: col,
           tmplExtends: "", tmplBlocks: @[], tmplBody: @[])

proc newExtendsNode*(path: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkExtends, file: file, line: line, col: col, extendsPath: path)

proc newBlockDefNode*(name: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkBlockDef, file: file, line: line, col: col,
           blockName: name, blockContent: @[])

proc newElementNode*(tag: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkElement, file: file, line: line, col: col,
           elemTag: tag, elemClasses: @[], elemId: "", elemAttrs: @[],
           elemChildren: @[], elemText: "", elemExprOutput: nil, elemEscaped: true)

proc newExprOutputNode*(expr: DootNode, escaped: bool = true, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkExprOutput, file: file, line: line, col: col,
           exprOutExpr: expr, exprOutEscaped: escaped)

proc newTextNode*(content: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkText, file: file, line: line, col: col, textContent: content)

proc newPartialNode*(path: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkPartial, file: file, line: line, col: col,
           partialPath: path, partialLocals: @[])

proc newTemplateIfNode*(cond: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkTemplateIf, file: file, line: line, col: col,
           tmplIfCondition: cond, tmplIfThen: @[], tmplIfElse: @[])

proc newTemplateEachNode*(varName: string, collection: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkTemplateEach, file: file, line: line, col: col,
           tmplEachVar: varName, tmplEachCollection: collection, tmplEachBody: @[])

proc newStringLitNode*(value: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkStringLit, file: file, line: line, col: col,
           strValue: value, strInterpolations: @[])

proc newIntLitNode*(value: int, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkIntLit, file: file, line: line, col: col, intValue: value)

proc newBoolLitNode*(value: bool, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkBoolLit, file: file, line: line, col: col, boolValue: value)

proc newNilNode*(file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkNil, file: file, line: line, col: col)

proc newIdentifierNode*(name: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkIdentifier, file: file, line: line, col: col, identName: name)

proc newMemberAccessNode*(obj: DootNode, prop: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkMemberAccess, file: file, line: line, col: col,
           memberObj: obj, memberProp: prop)

proc newMethodCallNode*(obj: DootNode, meth: string, args: seq[DootNode] = @[], file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkMethodCall, file: file, line: line, col: col,
           callObj: obj, callMethod: meth, callArgs: args)

proc newIndexAccessNode*(obj: DootNode, idx: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkIndexAccess, file: file, line: line, col: col,
           indexObj: obj, indexExpr: idx)

proc newBinaryOpNode*(left: DootNode, op: string, right: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkBinaryOp, file: file, line: line, col: col,
           binLeft: left, binOp: op, binRight: right)

proc newUnaryOpNode*(op: string, operand: DootNode, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkUnaryOp, file: file, line: line, col: col,
           unaryOp: op, unaryOperand: operand)

proc newArrayLitNode*(elements: seq[DootNode] = @[], file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkArrayLit, file: file, line: line, col: col, arrayElements: elements)

proc newEnvCallNode*(arg: string, file: string = "", line: int = 0, col: int = 0): DootNode =
  DootNode(kind: nkEnvCall, file: file, line: line, col: col, envArg: arg)
