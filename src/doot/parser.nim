## Recursive-descent parser for the Doot DSL compiler.
## Transforms a token sequence into a well-typed AST.
## Supports route/schema mode, template mode, and native blocks.
## Implements error recovery and actionable suggestions.

import std/strutils
import tokens
import ast

export ast

type
  ParseError* = object
    file*: string
    line*: int
    col*: int
    message*: string
    suggestion*: string

  Parser* = object
    tokens*: seq[Token]
    pos*: int
    currentFile*: string
    errors*: seq[ParseError]

const
  RecoveryTokens = {tkRoute, tkGroup, tkConfig, tkSchema, tkMount, tkEnd, tkNative, tkEof}
  DootKeywords = ["route", "schema", "table", "field", "group", "do", "end",
                   "if", "else", "each", "in", "config", "mount", "native",
                   "render", "redirect", "job", "schedule", "auth",
                   "extends", "block", "partial"]

# ------------------------------------------------------------------
# Levenshtein distance for typo suggestions
# ------------------------------------------------------------------

proc levenshteinDistance(a, b: string): int =
  let lenA = a.len
  let lenB = b.len
  var matrix = newSeq[seq[int]](lenA + 1)
  for i in 0..lenA:
    matrix[i] = newSeq[int](lenB + 1)
    matrix[i][0] = i
  for j in 0..lenB:
    matrix[0][j] = j
  for i in 1..lenA:
    for j in 1..lenB:
      let cost = if a[i-1] == b[j-1]: 0 else: 1
      matrix[i][j] = min(min(matrix[i-1][j] + 1, matrix[i][j-1] + 1), matrix[i-1][j-1] + cost)
  result = matrix[lenA][lenB]

proc suggestKeyword(word: string): string =
  ## Returns a suggestion if the word is close to a known keyword.
  var bestMatch = ""
  var bestDist = 3  # only suggest if distance <= 2
  for kw in DootKeywords:
    let dist = levenshteinDistance(word.toLowerAscii, kw)
    if dist < bestDist:
      bestDist = dist
      bestMatch = kw
  if bestMatch != "":
    result = "Did you mean '" & bestMatch & "'?"
  else:
    result = ""

# ------------------------------------------------------------------
# Core parser infrastructure
# ------------------------------------------------------------------

proc newParser*(tokens: seq[Token], filename: string = "<input>"): Parser =
  Parser(tokens: tokens, pos: 0, currentFile: filename, errors: @[])

proc current*(p: Parser): Token =
  if p.pos < p.tokens.len:
    p.tokens[p.pos]
  else:
    Token(kind: tkEof, value: "", file: p.currentFile, line: 0, col: 0)

proc peek*(p: Parser, offset: int = 1): Token =
  let idx = p.pos + offset
  if idx < p.tokens.len:
    p.tokens[idx]
  else:
    Token(kind: tkEof, value: "", file: p.currentFile, line: 0, col: 0)

proc atEnd*(p: Parser): bool =
  p.pos >= p.tokens.len or p.current.kind == tkEof

proc advance*(p: var Parser): Token =
  result = p.current
  if p.pos < p.tokens.len:
    p.pos += 1

proc addError*(p: var Parser, msg: string, suggestion: string = "") =
  let tok = p.current
  p.errors.add(ParseError(
    file: tok.file,
    line: tok.line,
    col: tok.col,
    message: msg,
    suggestion: suggestion
  ))

proc addErrorAt*(p: var Parser, file: string, line: int, col: int, msg: string, suggestion: string = "") =
  p.errors.add(ParseError(
    file: file,
    line: line,
    col: col,
    message: msg,
    suggestion: suggestion
  ))

proc expect*(p: var Parser, kind: TokenKind): Token =
  if p.current.kind == kind:
    result = p.advance()
  else:
    let tok = p.current
    let msg = "Expected " & $kind & ", got " & $tok.kind & " '" & tok.value & "'"
    var suggestion = ""
    if tok.kind == tkIdentifier:
      suggestion = suggestKeyword(tok.value)
    p.addError(msg, suggestion)
    # Return a dummy token so parsing can continue
    result = Token(kind: kind, value: "", file: tok.file, line: tok.line, col: tok.col)

proc match*(p: var Parser, kind: TokenKind): bool =
  if p.current.kind == kind:
    discard p.advance()
    result = true
  else:
    result = false

proc skipNewlines*(p: var Parser) =
  while p.current.kind == tkNewline:
    discard p.advance()

proc recover*(p: var Parser) =
  ## Skip tokens until we reach a recovery point.
  while not p.atEnd and p.current.kind notin RecoveryTokens and p.current.kind != tkNewline:
    discard p.advance()
  # Skip the newline if that's where we stopped
  if p.current.kind == tkNewline:
    discard p.advance()

proc recoverToEnd*(p: var Parser) =
  ## Skip tokens until we reach 'end' or EOF.
  while not p.atEnd and p.current.kind != tkEnd:
    discard p.advance()
  if p.current.kind == tkEnd:
    discard p.advance()

# ------------------------------------------------------------------
# Forward declarations
# ------------------------------------------------------------------

proc parseExpression*(p: var Parser): DootNode
proc parseHandlerBody*(p: var Parser): seq[DootNode]
proc parseTemplateBody*(p: var Parser): seq[DootNode]
proc parseTemplateElement*(p: var Parser): DootNode

# ------------------------------------------------------------------
# Expression parsing with operator precedence
# ------------------------------------------------------------------

proc parsePrimaryExpr*(p: var Parser): DootNode =
  let tok = p.current
  case tok.kind
  of tkStringLit:
    discard p.advance()
    # Check for interpolation (InterpolStart follows immediately after a StringLit)
    var parts: seq[DootNode] = @[]
    var baseStr = tok.value
    while p.current.kind == tkInterpolStart:
      discard p.advance()  # consume #{
      let expr = p.parseExpression()
      parts.add(expr)
      if p.current.kind == tkInterpolEnd:
        discard p.advance()  # consume }
      # After interpolation there may be another StringLit
      if p.current.kind == tkStringLit:
        discard p.advance()
    result = newStringLitNode(baseStr, tok.file, tok.line, tok.col)
    result.strInterpolations = parts
  of tkIntLit:
    discard p.advance()
    result = newIntLitNode(parseInt(tok.value), tok.file, tok.line, tok.col)
  of tkBoolTrue:
    discard p.advance()
    result = newBoolLitNode(true, tok.file, tok.line, tok.col)
  of tkBoolFalse:
    discard p.advance()
    result = newBoolLitNode(false, tok.file, tok.line, tok.col)
  of tkNilLit:
    discard p.advance()
    result = newNilNode(tok.file, tok.line, tok.col)
  of tkIdentifier:
    discard p.advance()
    # Check for function call syntax: ident(args)
    if tok.value == "env" and p.current.kind == tkLParen:
      discard p.advance()  # consume (
      var envArg = ""
      if p.current.kind == tkStringLit:
        envArg = p.current.value
        discard p.advance()
      discard p.expect(tkRParen)
      result = newEnvCallNode(envArg, tok.file, tok.line, tok.col)
    else:
      result = newIdentifierNode(tok.value, tok.file, tok.line, tok.col)
  of tkNot:
    discard p.advance()
    let operand = p.parsePrimaryExpr()
    result = newUnaryOpNode("!", operand, tok.file, tok.line, tok.col)
  of tkLParen:
    discard p.advance()
    result = p.parseExpression()
    discard p.expect(tkRParen)
  of tkLBracket:
    discard p.advance()
    var elements: seq[DootNode] = @[]
    while p.current.kind != tkRBracket and not p.atEnd:
      elements.add(p.parseExpression())
      if p.current.kind == tkComma:
        discard p.advance()
    discard p.expect(tkRBracket)
    result = newArrayLitNode(elements, tok.file, tok.line, tok.col)
  else:
    p.addError("Expected expression, got " & $tok.kind & " '" & tok.value & "'")
    discard p.advance()
    result = newNilNode(tok.file, tok.line, tok.col)

proc parsePostfix*(p: var Parser, left: DootNode): DootNode =
  result = left
  while true:
    case p.current.kind
    of tkDot:
      discard p.advance()
      let propTok = p.current
      var propName: string
      if propTok.kind == tkIdentifier:
        propName = propTok.value
        discard p.advance()
      elif propTok.kind in {tkRoute, tkSchema, tkTable, tkField, tkGroup,
                            tkDo, tkEnd, tkIf, tkElse, tkEach, tkIn,
                            tkConfig, tkMount, tkNative, tkRender,
                            tkRedirect, tkJob, tkSchedule, tkAuth,
                            tkExtends, tkBlock, tkPartial}:
        # Allow keywords as property names after dot
        propName = propTok.value
        discard p.advance()
      else:
        p.addError("Expected property name after '.', got " & $propTok.kind)
        propName = ""
      # Check if method call
      if p.current.kind == tkLParen:
        discard p.advance()  # consume (
        var args: seq[DootNode] = @[]
        while p.current.kind != tkRParen and not p.atEnd:
          # Check for keyword arguments: key: value
          if p.current.kind == tkIdentifier and p.peek.kind == tkColon:
            # keyword argument - parse as key-value (treat the whole key: value as expr)
            let keyTok = p.advance()
            discard p.advance()  # consume :
            let val = p.parseExpression()
            # Wrap as a binary op with ":" for now, or just pass as a plain expression
            # We'll use a special convention: the assignment node can represent this
            let kvNode = newAssignmentNode(keyTok.value, val, keyTok.file, keyTok.line, keyTok.col)
            args.add(kvNode)
          else:
            args.add(p.parseExpression())
          if p.current.kind == tkComma:
            discard p.advance()
        discard p.expect(tkRParen)
        result = newMethodCallNode(result, propName, args, left.file, left.line, left.col)
      else:
        result = newMemberAccessNode(result, propName, left.file, left.line, left.col)
      # Check for ? suffix on method/property name
      if p.current.kind == tkIdentifier and p.current.value == "?":
        # Actually ? is part of identChar in the lexer, so it's already included in propName
        discard
    of tkLBracket:
      discard p.advance()
      let idx = p.parseExpression()
      discard p.expect(tkRBracket)
      result = newIndexAccessNode(result, idx, left.file, left.line, left.col)
    else:
      break

proc parseUnaryExpr*(p: var Parser): DootNode =
  let primary = p.parsePrimaryExpr()
  result = p.parsePostfix(primary)

proc parseComparisonExpr*(p: var Parser): DootNode =
  result = p.parseUnaryExpr()
  while p.current.kind in {tkEq, tkNotEq, tkGt, tkLt, tkGtEq, tkLtEq}:
    let opTok = p.advance()
    let right = p.parseUnaryExpr()
    result = newBinaryOpNode(result, opTok.value, right, opTok.file, opTok.line, opTok.col)

proc parseAndExpr*(p: var Parser): DootNode =
  result = p.parseComparisonExpr()
  while p.current.kind == tkAnd:
    let opTok = p.advance()
    let right = p.parseComparisonExpr()
    result = newBinaryOpNode(result, "&&", right, opTok.file, opTok.line, opTok.col)

proc parseOrExpr*(p: var Parser): DootNode =
  result = p.parseAndExpr()
  while p.current.kind == tkOr:
    let opTok = p.advance()
    let right = p.parseAndExpr()
    result = newBinaryOpNode(result, "||", right, opTok.file, opTok.line, opTok.col)

proc parseExpression*(p: var Parser): DootNode =
  result = p.parseOrExpr()

# ------------------------------------------------------------------
# Config parsing
# ------------------------------------------------------------------

proc parseConfig*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'config'
  p.skipNewlines()
  discard p.expect(tkDo)
  p.skipNewlines()

  result = newConfigNode(tok.file, tok.line, tok.col)

  while p.current.kind != tkEnd and not p.atEnd:
    p.skipNewlines()
    if p.current.kind == tkEnd:
      break
    if p.current.kind == tkIdentifier:
      let keyTok = p.advance()
      let value = p.parseExpression()
      let directive = newConfigDirectiveNode(keyTok.value, value, keyTok.file, keyTok.line, keyTok.col)
      result.configDirectives.add(directive)
    else:
      p.addError("Expected config directive name, got " & $p.current.kind)
      p.recover()
    p.skipNewlines()

  discard p.expect(tkEnd)

# ------------------------------------------------------------------
# Schema parsing
# ------------------------------------------------------------------

proc parseField*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'field'

  # Expect field name (string literal)
  let nameTok = p.expect(tkStringLit)

  # Expect comma before type
  discard p.expect(tkComma)

  # Expect type annotation
  var fieldType = ""
  if p.current.kind in {tkTypeString, tkTypeText, tkTypeInteger,
                         tkTypeBoolean, tkTypeFloat, tkTypeDatetime}:
    let typeTok = p.advance()
    # The value includes the colon prefix, e.g. ":string"
    fieldType = typeTok.value.strip(chars = {':'})
  else:
    p.addError("Expected type annotation (:string, :text, :integer, :boolean, :float, :datetime), got " & $p.current.kind & " '" & p.current.value & "'",
               "Valid types are: :string, :text, :integer, :boolean, :float, :datetime")
    discard p.advance()

  result = newFieldNode(nameTok.value, fieldType, tok.file, tok.line, tok.col)

  # Parse optional constraints (comma-separated key: value pairs)
  while p.current.kind == tkComma:
    discard p.advance()  # consume comma
    if p.current.kind == tkIdentifier:
      let constraintKey = p.advance()
      discard p.expect(tkColon)
      let constraintVal = p.parseExpression()
      result.fieldConstraints.add(Constraint(key: constraintKey.value, value: constraintVal))
    else:
      break

proc parseAuth*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'auth'

  # Expect model name - could be :identifier (type token) or identifier
  var modelName = ""
  if p.current.kind == tkColon:
    discard p.advance()
    if p.current.kind == tkIdentifier:
      modelName = p.current.value
      discard p.advance()
  elif p.current.kind == tkIdentifier:
    modelName = p.current.value
    discard p.advance()
  elif p.current.kind in {tkTypeString, tkTypeText, tkTypeInteger,
                           tkTypeBoolean, tkTypeFloat, tkTypeDatetime}:
    # The lexer might have parsed :users as a type, so handle gracefully
    modelName = p.current.value.strip(chars = {':'})
    discard p.advance()
  else:
    # The lexer might interpret :users as tkColon + tkIdentifier
    p.addError("Expected auth model name")

  p.skipNewlines()
  discard p.expect(tkDo)
  p.skipNewlines()

  result = newAuthNode(modelName, tok.file, tok.line, tok.col)

  while p.current.kind != tkEnd and not p.atEnd:
    p.skipNewlines()
    if p.current.kind == tkEnd:
      break
    if p.current.kind == tkIdentifier:
      let keyTok = p.advance()
      case keyTok.value
      of "roles":
        # Expect array literal
        if p.current.kind == tkLBracket:
          discard p.advance()
          while p.current.kind != tkRBracket and not p.atEnd:
            if p.current.kind == tkStringLit:
              result.authRoles.add(p.current.value)
              discard p.advance()
            if p.current.kind == tkComma:
              discard p.advance()
          discard p.expect(tkRBracket)
      of "email_verification":
        if p.current.kind == tkBoolTrue:
          result.emailVerification = true
          discard p.advance()
        elif p.current.kind == tkBoolFalse:
          result.emailVerification = false
          discard p.advance()
      else:
        discard p.parseExpression()
    else:
      p.addError("Expected auth directive, got " & $p.current.kind)
      p.recover()
    p.skipNewlines()

  discard p.expect(tkEnd)

proc parseTable*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'table'

  # Expect table name (string literal)
  let nameTok = p.expect(tkStringLit)

  p.skipNewlines()
  discard p.expect(tkDo)
  p.skipNewlines()

  result = newTableNode(nameTok.value, tok.file, tok.line, tok.col)

  while p.current.kind != tkEnd and not p.atEnd:
    p.skipNewlines()
    if p.current.kind == tkEnd:
      break
    case p.current.kind
    of tkField:
      result.tableFields.add(p.parseField())
    of tkIdentifier:
      if p.current.value == "timestamps":
        result.hasTimestamps = true
        discard p.advance()
      else:
        p.addError("Unexpected identifier '" & p.current.value & "' in table block")
        p.recover()
    else:
      p.addError("Expected 'field' or 'timestamps' in table block, got " & $p.current.kind)
      p.recover()
    p.skipNewlines()

  discard p.expect(tkEnd)

proc parseSchema*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'schema'
  p.skipNewlines()
  discard p.expect(tkDo)
  p.skipNewlines()

  result = newSchemaNode(tok.file, tok.line, tok.col)

  while p.current.kind != tkEnd and not p.atEnd:
    p.skipNewlines()
    if p.current.kind == tkEnd:
      break
    case p.current.kind
    of tkTable:
      result.schemaTables.add(p.parseTable())
    of tkAuth:
      result.schemaAuth = p.parseAuth()
    else:
      p.addError("Expected 'table' or 'auth' in schema block, got " & $p.current.kind & " '" & p.current.value & "'")
      p.recover()
    p.skipNewlines()

  discard p.expect(tkEnd)

# ------------------------------------------------------------------
# Mount parsing
# ------------------------------------------------------------------

proc parseMount*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'mount'
  let pathTok = p.expect(tkStringLit)
  result = newMountNode(pathTok.value, tok.file, tok.line, tok.col)

# ------------------------------------------------------------------
# Handler statement parsing
# ------------------------------------------------------------------

proc parseIf*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'if'

  let condition = p.parseExpression()
  p.skipNewlines()

  result = newIfNode(condition, tok.file, tok.line, tok.col)

  # Parse then-branch statements until 'else' or 'end'
  while p.current.kind notin {tkElse, tkEnd, tkEof}:
    p.skipNewlines()
    if p.current.kind in {tkElse, tkEnd, tkEof}:
      break
    let stmts = p.parseHandlerBody()
    result.ifThen = stmts
    break

  # If there's no body parsed yet, parse statement by statement
  if result.ifThen.len == 0:
    while p.current.kind notin {tkElse, tkEnd, tkEof}:
      p.skipNewlines()
      if p.current.kind in {tkElse, tkEnd, tkEof}:
        break
      discard p.advance()

  # Parse optional else branch
  if p.current.kind == tkElse:
    discard p.advance()
    p.skipNewlines()
    result.ifElse = p.parseHandlerBody()

  discard p.expect(tkEnd)

proc parseEach*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'each'

  let varTok = p.expect(tkIdentifier)
  discard p.expect(tkIn)
  let collection = p.parseExpression()
  p.skipNewlines()

  result = newEachNode(varTok.value, collection, tok.file, tok.line, tok.col)
  result.eachBody = p.parseHandlerBody()
  discard p.expect(tkEnd)

proc parseRender*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'render'

  let pathTok = p.expect(tkStringLit)
  result = newRenderNode(pathTok.value, tok.file, tok.line, tok.col)

  # Parse optional locals (comma-separated key: value pairs)
  while p.current.kind == tkComma:
    discard p.advance()  # consume comma
    if p.current.kind == tkIdentifier:
      let keyTok = p.advance()
      discard p.expect(tkColon)
      let value = p.parseExpression()
      result.renderLocals.add(KeyValuePair(key: keyTok.value, value: value))
    else:
      break

proc parseRedirect*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'redirect'
  let expr = p.parseExpression()
  result = newRedirectNode(expr, tok.file, tok.line, tok.col)

proc parseNativeBlock*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'native'
  p.skipNewlines()
  discard p.expect(tkDo)
  p.skipNewlines()

  # The lexer in native mode captures content as a StringLit token followed by tkEnd.
  # If the lexer was NOT in native mode, we get regular tokens until tkEnd.
  var content = ""
  if p.current.kind == tkStringLit:
    # Native mode was active: content is a single StringLit
    content = p.current.value
    discard p.advance()
    p.skipNewlines()
  else:
    # Fallback: skip tokens until 'end', collecting their values
    while p.current.kind != tkEnd and not p.atEnd:
      if p.current.kind == tkNewline:
        content.add("\n")
      else:
        content.add(p.current.value)
        content.add(" ")
      discard p.advance()

  if p.current.kind == tkEnd:
    discard p.advance()

  result = newNativeBlockNode(content.strip(), tok.file, tok.line, tok.col)

proc parseStatementStartingWithIdent*(p: var Parser): DootNode =
  ## Parse a statement that starts with an identifier.
  ## Could be: assignment (x = expr), db query (db.table.method(...)), or expression.
  let identTok = p.current
  discard p.advance()

  # Check for assignment: ident = expr
  if p.current.kind == tkAssign:
    discard p.advance()  # consume =
    let value = p.parseExpression()
    result = newAssignmentNode(identTok.value, value, identTok.file, identTok.line, identTok.col)
  else:
    # It's an expression starting with this identifier - rewind and parse as expression
    p.pos -= 1  # put the identifier back
    let expr = p.parseExpression()
    # Wrap standalone expression in an assignment with empty name (expression statement)
    # Or just return the expression itself as a statement
    result = expr

proc parseHandlerBody*(p: var Parser): seq[DootNode] =
  ## Parse handler body statements until 'end', 'else', or EOF.
  result = @[]
  while p.current.kind notin {tkEnd, tkElse, tkEof}:
    p.skipNewlines()
    if p.current.kind in {tkEnd, tkElse, tkEof}:
      break
    case p.current.kind
    of tkIf:
      result.add(p.parseIf())
    of tkEach:
      result.add(p.parseEach())
    of tkRender:
      result.add(p.parseRender())
    of tkRedirect:
      result.add(p.parseRedirect())
    of tkNative:
      result.add(p.parseNativeBlock())
    of tkIdentifier:
      result.add(p.parseStatementStartingWithIdent())
    of tkNewline:
      discard p.advance()
    else:
      p.addError("Unexpected token in handler body: " & $p.current.kind & " '" & p.current.value & "'")
      discard p.advance()
    p.skipNewlines()

# ------------------------------------------------------------------
# Route / Group parsing
# ------------------------------------------------------------------

proc parseRouteOptions*(p: var Parser, route: DootNode) =
  ## Parse route options like auth: public, role: admin before 'do'
  while p.current.kind == tkComma or p.current.kind == tkIdentifier or p.current.kind == tkAuth:
    if p.current.kind == tkComma:
      discard p.advance()
    if p.current.kind == tkAuth:
      discard p.advance()  # consume 'auth'
      discard p.expect(tkColon)
      if p.current.kind == tkIdentifier:
        route.routeAuth = p.current.value
        discard p.advance()
      elif p.current.kind in {tkTypeString, tkTypeText, tkTypeInteger,
                               tkTypeBoolean, tkTypeFloat, tkTypeDatetime}:
        route.routeAuth = p.current.value.strip(chars = {':'})
        discard p.advance()
    elif p.current.kind == tkIdentifier:
      let optKey = p.current.value
      if optKey == "auth":
        discard p.advance()
        discard p.expect(tkColon)
        if p.current.kind == tkIdentifier:
          route.routeAuth = p.current.value
          discard p.advance()
      elif optKey == "role":
        discard p.advance()
        discard p.expect(tkColon)
        if p.current.kind == tkIdentifier:
          route.routeRole = p.current.value
          discard p.advance()
      else:
        break
    else:
      break

proc parseRoute*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'route'

  # Expect HTTP method
  var httpMethod = ""
  if p.current.kind in {tkGet, tkPost, tkPut, tkDelete, tkPatch}:
    httpMethod = p.current.value
    discard p.advance()
  else:
    p.addError("Expected HTTP method (GET, POST, PUT, DELETE, PATCH), got " & $p.current.kind)

  # Expect path string
  let pathTok = p.expect(tkStringLit)

  result = newRouteNode(httpMethod, pathTok.value, tok.file, tok.line, tok.col)

  # Parse options before 'do'
  p.parseRouteOptions(result)

  p.skipNewlines()
  discard p.expect(tkDo)

  # Check for |ctx| parameter
  if p.current.kind == tkPipe:
    discard p.advance()  # consume |
    if p.current.kind == tkIdentifier:
      result.routeParam = p.current.value
      discard p.advance()
    discard p.expect(tkPipe)

  p.skipNewlines()

  # Parse handler body
  result.routeBody = p.parseHandlerBody()

  discard p.expect(tkEnd)

proc parseGroupOptions*(p: var Parser, group: DootNode) =
  ## Parse group options like auth: required, role: admin
  while p.current.kind in {tkIdentifier, tkAuth, tkComma}:
    if p.current.kind == tkComma:
      discard p.advance()
    if p.current.kind == tkAuth:
      discard p.advance()
      discard p.expect(tkColon)
      if p.current.kind == tkIdentifier:
        group.groupAuth = p.current.value
        discard p.advance()
    elif p.current.kind == tkIdentifier:
      let optKey = p.current.value
      if optKey == "auth":
        discard p.advance()
        discard p.expect(tkColon)
        if p.current.kind == tkIdentifier:
          group.groupAuth = p.current.value
          discard p.advance()
      elif optKey == "role":
        discard p.advance()
        discard p.expect(tkColon)
        if p.current.kind == tkIdentifier:
          group.groupRole = p.current.value
          discard p.advance()
      else:
        break
    else:
      break

proc parseGroup*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'group'

  result = newGroupNode(tok.file, tok.line, tok.col)

  # Parse group options
  p.parseGroupOptions(result)

  p.skipNewlines()
  discard p.expect(tkDo)
  p.skipNewlines()

  # Parse routes inside the group
  while p.current.kind != tkEnd and not p.atEnd:
    p.skipNewlines()
    if p.current.kind == tkEnd:
      break
    if p.current.kind == tkRoute:
      result.groupChildren.add(p.parseRoute())
    else:
      p.addError("Expected 'route' inside group block, got " & $p.current.kind & " '" & p.current.value & "'")
      p.recover()
    p.skipNewlines()

  discard p.expect(tkEnd)

# ------------------------------------------------------------------
# Template parsing
# ------------------------------------------------------------------

proc parseTemplateIf*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'if'
  let condition = p.parseExpression()

  result = newTemplateIfNode(condition, tok.file, tok.line, tok.col)

  # In template mode, children are indented
  if p.current.kind == tkNewline:
    discard p.advance()

  # Parse then-body (indented content)
  if p.current.kind == tkIndent:
    discard p.advance()
    while p.current.kind != tkDedent and p.current.kind != tkEof:
      if p.current.kind == tkNewline:
        discard p.advance()
        continue
      result.tmplIfThen.add(p.parseTemplateElement())
    if p.current.kind == tkDedent:
      discard p.advance()

  # Parse else
  if p.current.kind == tkElse:
    discard p.advance()
    if p.current.kind == tkNewline:
      discard p.advance()
    if p.current.kind == tkIndent:
      discard p.advance()
      while p.current.kind != tkDedent and p.current.kind != tkEof:
        if p.current.kind == tkNewline:
          discard p.advance()
          continue
        result.tmplIfElse.add(p.parseTemplateElement())
      if p.current.kind == tkDedent:
        discard p.advance()

proc parseTemplateEach*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'each'

  let varTok = p.expect(tkIdentifier)
  discard p.expect(tkIn)
  let collection = p.parseExpression()

  result = newTemplateEachNode(varTok.value, collection, tok.file, tok.line, tok.col)

  if p.current.kind == tkNewline:
    discard p.advance()

  # Parse indented body
  if p.current.kind == tkIndent:
    discard p.advance()
    while p.current.kind != tkDedent and p.current.kind != tkEof:
      if p.current.kind == tkNewline:
        discard p.advance()
        continue
      result.tmplEachBody.add(p.parseTemplateElement())
    if p.current.kind == tkDedent:
      discard p.advance()

proc parsePartial*(p: var Parser): DootNode =
  let tok = p.current
  discard p.advance()  # consume 'partial'

  let pathTok = p.expect(tkStringLit)
  result = newPartialNode(pathTok.value, tok.file, tok.line, tok.col)

  # Parse optional locals
  while p.current.kind == tkComma:
    discard p.advance()
    if p.current.kind == tkIdentifier:
      let keyTok = p.advance()
      discard p.expect(tkColon)
      let value = p.parseExpression()
      result.partialLocals.add(KeyValuePair(key: keyTok.value, value: value))
    else:
      break

proc parseElementShorthand*(p: var Parser): DootNode =
  ## Parse element with class/id shorthand: tag.class1.class2#id
  let tok = p.current
  var tagName = ""

  if p.current.kind == tkIdentifier:
    tagName = p.current.value
    discard p.advance()
  else:
    tagName = "div"  # default tag

  result = newElementNode(tagName, tok.file, tok.line, tok.col)

  # Parse .class and #id shorthand
  # After the tag name, we might have dots for classes
  # The lexer tokenizes . as tkDot and # as comment starter, so we need
  # to handle the case where the class/id is already part of the identifier
  # from template mode lexing. Actually the lexer will tokenize div.card#main
  # based on template mode behavior. Let's handle the common case.

  # In template mode, the lexer might have already included .class in the ident
  # Actually looking at the lexer, . is always tkDot. So:
  # "div.card#main" would be tokenized as: tkIdentifier("div"), tkDot, tkIdentifier("card#main")
  # or more likely as: tkIdentifier("div"), tkDot, tkIdentifier("card"), ...
  # Since # starts a comment in route mode but in template mode it might be different.
  # For now, handle dot-separated class names

  while p.current.kind == tkDot:
    discard p.advance()  # consume .
    if p.current.kind == tkIdentifier:
      let className = p.current.value
      discard p.advance()
      result.elemClasses.add(className)
    else:
      break

  # Parse attributes: key=value or key="value"
  while p.current.kind == tkIdentifier and p.peek.kind == tkAssign:
    let attrKey = p.advance()
    discard p.advance()  # consume =
    let attrVal = p.parseExpression()
    result.elemAttrs.add(KeyValuePair(key: attrKey.value, value: attrVal))

  # Check for expression output (= or !=)
  if p.current.kind == tkAssign:
    discard p.advance()
    let expr = p.parseExpression()
    result.elemExprOutput = expr
    result.elemEscaped = true
  elif p.current.kind == tkNotEq:
    # != means unescaped output
    discard p.advance()
    let expr = p.parseExpression()
    result.elemExprOutput = expr
    result.elemEscaped = false

  # Check for inline text content (string literal)
  if p.current.kind == tkStringLit and result.elemExprOutput == nil:
    result.elemText = p.current.value
    discard p.advance()

  # Parse children (indented)
  if p.current.kind == tkNewline:
    discard p.advance()
  if p.current.kind == tkIndent:
    discard p.advance()
    while p.current.kind != tkDedent and p.current.kind != tkEof:
      if p.current.kind == tkNewline:
        discard p.advance()
        continue
      result.elemChildren.add(p.parseTemplateElement())
    if p.current.kind == tkDedent:
      discard p.advance()

proc parseTemplateElement*(p: var Parser): DootNode =
  ## Parse a single template element/node.
  case p.current.kind
  of tkIf:
    result = p.parseTemplateIf()
  of tkEach:
    result = p.parseTemplateEach()
  of tkPartial:
    result = p.parsePartial()
  of tkBlock:
    let tok = p.current
    discard p.advance()  # consume 'block'
    let nameTok = p.expect(tkIdentifier)
    result = newBlockDefNode(nameTok.value, tok.file, tok.line, tok.col)
    if p.current.kind == tkNewline:
      discard p.advance()
    # Parse indented content
    if p.current.kind == tkIndent:
      discard p.advance()
      while p.current.kind != tkDedent and p.current.kind != tkEof:
        if p.current.kind == tkNewline:
          discard p.advance()
          continue
        result.blockContent.add(p.parseTemplateElement())
      if p.current.kind == tkDedent:
        discard p.advance()
  of tkAssign:
    # Expression output: = expr
    let tok = p.current
    discard p.advance()
    let expr = p.parseExpression()
    result = newExprOutputNode(expr, true, tok.file, tok.line, tok.col)
  of tkNotEq:
    # Unescaped expression output: != expr
    let tok = p.current
    discard p.advance()
    let expr = p.parseExpression()
    result = newExprOutputNode(expr, false, tok.file, tok.line, tok.col)
  of tkStringLit:
    let tok = p.current
    discard p.advance()
    result = newTextNode(tok.value, tok.file, tok.line, tok.col)
  of tkIdentifier:
    result = p.parseElementShorthand()
  of tkPipe:
    # Text node: | text content
    let tok = p.current
    discard p.advance()
    var text = ""
    if p.current.kind == tkStringLit:
      text = p.current.value
      discard p.advance()
    elif p.current.kind == tkIdentifier:
      text = p.current.value
      discard p.advance()
    result = newTextNode(text, tok.file, tok.line, tok.col)
  else:
    let tok = p.current
    p.addError("Unexpected token in template: " & $tok.kind & " '" & tok.value & "'")
    discard p.advance()
    result = newTextNode("", tok.file, tok.line, tok.col)

proc parseTemplateBody*(p: var Parser): seq[DootNode] =
  result = @[]
  while not p.atEnd:
    p.skipNewlines()
    if p.atEnd:
      break
    result.add(p.parseTemplateElement())

proc parseTemplate*(p: var Parser): DootNode =
  ## Parse a template file (uses indentation-based structure).
  let tok = p.current
  result = newTemplateNode(tok.file, tok.line, tok.col)

  # Check for extends
  if p.current.kind == tkExtends:
    discard p.advance()
    let pathTok = p.expect(tkStringLit)
    result.tmplExtends = pathTok.value
    p.skipNewlines()

  # Parse the rest of the template
  while not p.atEnd:
    p.skipNewlines()
    if p.atEnd:
      break
    case p.current.kind
    of tkBlock:
      let blockTok = p.current
      discard p.advance()
      let nameTok = p.expect(tkIdentifier)
      let blockNode = newBlockDefNode(nameTok.value, blockTok.file, blockTok.line, blockTok.col)
      if p.current.kind == tkNewline:
        discard p.advance()
      # Parse indented content
      if p.current.kind == tkIndent:
        discard p.advance()
        while p.current.kind != tkDedent and p.current.kind != tkEof:
          if p.current.kind == tkNewline:
            discard p.advance()
            continue
          blockNode.blockContent.add(p.parseTemplateElement())
        if p.current.kind == tkDedent:
          discard p.advance()
      result.tmplBlocks.add(blockNode)
    else:
      result.tmplBody.add(p.parseTemplateElement())

# ------------------------------------------------------------------
# Top-level parsing
# ------------------------------------------------------------------

proc parseApp*(p: var Parser): DootNode =
  ## Parse a complete application file (route/schema mode).
  let tok = p.current
  result = newAppNode(tok.file, tok.line, tok.col)

  while not p.atEnd:
    p.skipNewlines()
    if p.atEnd:
      break
    case p.current.kind
    of tkConfig:
      result.appConfig = p.parseConfig()
    of tkSchema:
      result.appSchema = p.parseSchema()
    of tkMount:
      result.appMounts.add(p.parseMount())
    of tkRoute:
      result.appRoutes.add(p.parseRoute())
    of tkGroup:
      result.appRoutes.add(p.parseGroup())
    of tkNative:
      result.appRoutes.add(p.parseNativeBlock())
    of tkEof:
      break
    of tkNewline:
      discard p.advance()
    of tkEnd:
      # Stray 'end' token (possibly from error recovery) - skip it
      discard p.advance()
    of tkIdentifier:
      let suggestion = suggestKeyword(p.current.value)
      p.addError("Unexpected identifier '" & p.current.value & "' at top level", suggestion)
      p.recover()
    else:
      p.addError("Unexpected token at top level: " & $p.current.kind & " '" & p.current.value & "'")
      discard p.advance()  # Always make progress

# ------------------------------------------------------------------
# Public API
# ------------------------------------------------------------------

proc parse*(tokens: seq[Token], filename: string = "<input>"): DootNode =
  ## Parse tokens from a route/schema mode file into an AST.
  var p = newParser(tokens, filename)
  result = p.parseApp()

proc parseWithErrors*(tokens: seq[Token], filename: string = "<input>"): (DootNode, seq[ParseError]) =
  ## Parse tokens and return both the AST and any errors encountered.
  var p = newParser(tokens, filename)
  let ast = p.parseApp()
  result = (ast, p.errors)

proc parseTemplateTokens*(tokens: seq[Token], filename: string = "<input>"): DootNode =
  ## Parse tokens from a template mode file into a template AST.
  var p = newParser(tokens, filename)
  result = p.parseTemplate()

proc parseTemplateWithErrors*(tokens: seq[Token], filename: string = "<input>"): (DootNode, seq[ParseError]) =
  ## Parse template tokens and return both the AST and any errors.
  var p = newParser(tokens, filename)
  let ast = p.parseTemplate()
  result = (ast, p.errors)
