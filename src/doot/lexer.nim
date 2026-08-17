## Lexer for the Doot DSL compiler.
## Transforms source text into a sequence of tokens.
## Supports three parse modes: RouteSchema, Template, and Native.

import std/strutils
import std/tables
import tokens

export tokens

type
  Lexer* = object
    source*: string
    filename*: string
    pos*: int
    line*: int
    col*: int
    mode*: LexMode
    indentStack*: seq[int]
    tokens*: seq[Token]
    errors*: seq[string]
    atLineStart*: bool
    nativeIndent*: int  # indentation level when native block started

const
  Keywords = {
    "route": tkRoute,
    "schema": tkSchema,
    "table": tkTable,
    "field": tkField,
    "group": tkGroup,
    "do": tkDo,
    "end": tkEnd,
    "if": tkIf,
    "else": tkElse,
    "each": tkEach,
    "in": tkIn,
    "config": tkConfig,
    "mount": tkMount,
    "native": tkNative,
    "render": tkRender,
    "redirect": tkRedirect,
    "job": tkJob,
    "schedule": tkSchedule,
    "auth": tkAuth,
    "extends": tkExtends,
    "block": tkBlock,
    "partial": tkPartial,
  }.toTable

  HttpMethods = {
    "GET": tkGet,
    "POST": tkPost,
    "PUT": tkPut,
    "DELETE": tkDelete,
    "PATCH": tkPatch,
  }.toTable

  TypeKeywords = {
    "string": tkTypeString,
    "text": tkTypeText,
    "integer": tkTypeInteger,
    "boolean": tkTypeBoolean,
    "float": tkTypeFloat,
    "datetime": tkTypeDatetime,
  }.toTable

proc newLexer*(source: string, filename: string = "<input>", mode: LexMode = RouteSchema): Lexer =
  Lexer(
    source: source,
    filename: filename,
    pos: 0,
    line: 1,
    col: 1,
    mode: mode,
    indentStack: @[0],
    tokens: @[],
    errors: @[],
    atLineStart: true,
    nativeIndent: 0,
  )

proc peek(lex: Lexer): char =
  if lex.pos < lex.source.len:
    lex.source[lex.pos]
  else:
    '\0'

proc peekAt(lex: Lexer, offset: int): char =
  let idx = lex.pos + offset
  if idx < lex.source.len:
    lex.source[idx]
  else:
    '\0'

proc advance(lex: var Lexer): char =
  result = lex.source[lex.pos]
  lex.pos += 1
  if result == '\n':
    lex.line += 1
    lex.col = 1
  else:
    lex.col += 1

proc isAtEnd(lex: Lexer): bool =
  lex.pos >= lex.source.len

proc addToken(lex: var Lexer, kind: TokenKind, value: string, line: int, col: int) =
  lex.tokens.add(newToken(kind, value, lex.filename, line, col))

proc addError(lex: var Lexer, msg: string) =
  lex.errors.add(lex.filename & ":" & $lex.line & ":" & $lex.col & " " & msg)

proc isIdentChar(c: char): bool =
  c.isAlphaNumeric or c == '_' or c == '?'

proc isIdentStartChar(c: char): bool =
  c.isAlphaAscii or c == '_'

proc skipSpaces(lex: var Lexer) =
  ## Skip spaces and tabs (but NOT newlines).
  while not lex.isAtEnd and lex.peek in {' ', '\t'}:
    discard lex.advance()

proc countIndent(lex: var Lexer): int =
  ## Count leading spaces at line start. Returns the indent level.
  result = 0
  while not lex.isAtEnd and lex.peek == ' ':
    result += 1
    discard lex.advance()

proc handleTemplateIndent(lex: var Lexer) =
  ## Handle indentation changes in template mode.
  # Check for tabs first
  if not lex.isAtEnd and lex.peek == '\t':
    lex.addError("Tabs are not allowed in template mode; use 2 spaces for indentation")
    # Skip all tabs
    while not lex.isAtEnd and lex.peek == '\t':
      discard lex.advance()
    return

  let startCol = lex.col
  let indent = lex.countIndent()
  let currentIndent = lex.indentStack[^1]

  if indent > currentIndent:
    lex.indentStack.add(indent)
    lex.addToken(tkIndent, "", lex.line, startCol)
  elif indent < currentIndent:
    while lex.indentStack.len > 1 and lex.indentStack[^1] > indent:
      discard lex.indentStack.pop()
      lex.addToken(tkDedent, "", lex.line, startCol)

proc readString(lex: var Lexer) =
  ## Read a string literal, handling #{} interpolation.
  let startLine = lex.line
  let startCol = lex.col
  discard lex.advance()  # consume opening "

  var value = ""
  while not lex.isAtEnd and lex.peek != '"':
    if lex.peek == '#' and lex.peekAt(1) == '{':
      # Emit the string part accumulated so far
      lex.addToken(tkStringLit, value, startLine, startCol)
      value = ""
      # Emit InterpolStart
      let interpolLine = lex.line
      let interpolCol = lex.col
      discard lex.advance()  # #
      discard lex.advance()  # {
      lex.addToken(tkInterpolStart, "#{", interpolLine, interpolCol)
      # Tokenize expression inside interpolation
      var braceDepth = 1
      while not lex.isAtEnd and braceDepth > 0:
        let c = lex.peek
        if c == '}':
          braceDepth -= 1
          if braceDepth == 0:
            let endLine = lex.line
            let endCol = lex.col
            discard lex.advance()
            lex.addToken(tkInterpolEnd, "}", endLine, endCol)
          else:
            discard lex.advance()
        elif c == '{':
          braceDepth += 1
          discard lex.advance()
        elif c == '"':
          # Nested string inside interpolation
          lex.readString()
        elif c == ' ' or c == '\t':
          discard lex.advance()
        elif c.isIdentStartChar:
          let idLine = lex.line
          let idCol = lex.col
          var ident = ""
          while not lex.isAtEnd and lex.peek.isIdentChar:
            ident.add(lex.advance())
          # Check if keyword/method/etc
          if ident in Keywords:
            lex.addToken(Keywords[ident], ident, idLine, idCol)
          elif ident in HttpMethods:
            lex.addToken(HttpMethods[ident], ident, idLine, idCol)
          elif ident == "true":
            lex.addToken(tkBoolTrue, "true", idLine, idCol)
          elif ident == "false":
            lex.addToken(tkBoolFalse, "false", idLine, idCol)
          elif ident == "nil":
            lex.addToken(tkNilLit, "nil", idLine, idCol)
          else:
            lex.addToken(tkIdentifier, ident, idLine, idCol)
        elif c.isDigit:
          let numLine = lex.line
          let numCol = lex.col
          var num = ""
          while not lex.isAtEnd and lex.peek.isDigit:
            num.add(lex.advance())
          lex.addToken(tkIntLit, num, numLine, numCol)
        elif c == '(':
          lex.addToken(tkLParen, "(", lex.line, lex.col)
          discard lex.advance()
        elif c == ')':
          lex.addToken(tkRParen, ")", lex.line, lex.col)
          discard lex.advance()
        elif c == '[':
          lex.addToken(tkLBracket, "[", lex.line, lex.col)
          discard lex.advance()
        elif c == ']':
          lex.addToken(tkRBracket, "]", lex.line, lex.col)
          discard lex.advance()
        elif c == '.':
          lex.addToken(tkDot, ".", lex.line, lex.col)
          discard lex.advance()
        elif c == ',':
          lex.addToken(tkComma, ",", lex.line, lex.col)
          discard lex.advance()
        elif c == '=':
          if lex.peekAt(1) == '=':
            lex.addToken(tkEq, "==", lex.line, lex.col)
            discard lex.advance()
            discard lex.advance()
          else:
            lex.addToken(tkAssign, "=", lex.line, lex.col)
            discard lex.advance()
        elif c == '!':
          if lex.peekAt(1) == '=':
            lex.addToken(tkNotEq, "!=", lex.line, lex.col)
            discard lex.advance()
            discard lex.advance()
          else:
            lex.addToken(tkNot, "!", lex.line, lex.col)
            discard lex.advance()
        elif c == '+' or c == '-' or c == '*' or c == '/':
          discard lex.advance()
        else:
          lex.addError("Unexpected character in interpolation: '" & $c & "'")
          discard lex.advance()
      # After interpolation, the rest of the string uses its own position
    elif lex.peek == '\\':
      # Escape sequences
      discard lex.advance()
      if not lex.isAtEnd:
        let escaped = lex.advance()
        case escaped
        of 'n': value.add('\n')
        of 't': value.add('\t')
        of '\\': value.add('\\')
        of '"': value.add('"')
        of '#': value.add('#')
        else: value.add('\\'); value.add(escaped)
    elif lex.peek == '\n':
      # Multi-line string - include the newline
      value.add(lex.advance())
    else:
      value.add(lex.advance())

  if not lex.isAtEnd:
    discard lex.advance()  # consume closing "

  # Emit remaining string content (or the full string if no interpolation)
  lex.addToken(tkStringLit, value, startLine, startCol)

proc readNumber(lex: var Lexer) =
  let startLine = lex.line
  let startCol = lex.col
  var num = ""
  while not lex.isAtEnd and lex.peek.isDigit:
    num.add(lex.advance())
  lex.addToken(tkIntLit, num, startLine, startCol)

proc readIdentifierOrKeyword(lex: var Lexer) =
  let startLine = lex.line
  let startCol = lex.col
  var ident = ""
  while not lex.isAtEnd and lex.peek.isIdentChar:
    ident.add(lex.advance())

  # Check for HTTP methods
  if ident in HttpMethods:
    lex.addToken(HttpMethods[ident], ident, startLine, startCol)
  elif ident in Keywords:
    lex.addToken(Keywords[ident], ident, startLine, startCol)
  elif ident == "true":
    lex.addToken(tkBoolTrue, "true", startLine, startCol)
  elif ident == "false":
    lex.addToken(tkBoolFalse, "false", startLine, startCol)
  elif ident == "nil":
    lex.addToken(tkNilLit, "nil", startLine, startCol)
  else:
    lex.addToken(tkIdentifier, ident, startLine, startCol)

proc readType(lex: var Lexer) =
  ## Read a type annotation like :string, :text, etc.
  let startLine = lex.line
  let startCol = lex.col
  discard lex.advance()  # consume the ':'

  # Check if followed by an identifier-like type name
  if not lex.isAtEnd and lex.peek.isIdentStartChar:
    var typeName = ""
    while not lex.isAtEnd and lex.peek.isIdentChar:
      typeName.add(lex.advance())
    if typeName in TypeKeywords:
      lex.addToken(TypeKeywords[typeName], ":" & typeName, startLine, startCol)
    else:
      # It's a colon followed by an identifier, emit as colon + identifier
      lex.addToken(tkColon, ":", startLine, startCol)
      lex.addToken(tkIdentifier, typeName, startLine, startCol + 1)
  else:
    lex.addToken(tkColon, ":", startLine, startCol)

proc readOperator(lex: var Lexer) =
  let startLine = lex.line
  let startCol = lex.col
  let c = lex.peek

  case c
  of '=':
    discard lex.advance()
    if not lex.isAtEnd and lex.peek == '=':
      discard lex.advance()
      lex.addToken(tkEq, "==", startLine, startCol)
    else:
      lex.addToken(tkAssign, "=", startLine, startCol)
  of '!':
    discard lex.advance()
    if not lex.isAtEnd and lex.peek == '=':
      discard lex.advance()
      lex.addToken(tkNotEq, "!=", startLine, startCol)
    else:
      lex.addToken(tkNot, "!", startLine, startCol)
  of '>':
    discard lex.advance()
    if not lex.isAtEnd and lex.peek == '=':
      discard lex.advance()
      lex.addToken(tkGtEq, ">=", startLine, startCol)
    else:
      lex.addToken(tkGt, ">", startLine, startCol)
  of '<':
    discard lex.advance()
    if not lex.isAtEnd and lex.peek == '=':
      discard lex.advance()
      lex.addToken(tkLtEq, "<=", startLine, startCol)
    else:
      lex.addToken(tkLt, "<", startLine, startCol)
  of '&':
    discard lex.advance()
    if not lex.isAtEnd and lex.peek == '&':
      discard lex.advance()
      lex.addToken(tkAnd, "&&", startLine, startCol)
    else:
      lex.addError("Unexpected character: '&' (did you mean '&&'?)")
  of '|':
    discard lex.advance()
    if not lex.isAtEnd and lex.peek == '|':
      discard lex.advance()
      lex.addToken(tkOr, "||", startLine, startCol)
    else:
      lex.addToken(tkPipe, "|", startLine, startCol)
  else:
    discard

proc scanNativeMode(lex: var Lexer) =
  ## In native mode, capture everything as raw text until 'end' at same/lesser indent.
  let startLine = lex.line
  let startCol = lex.col
  var content = ""

  while not lex.isAtEnd:
    # At line start, check for 'end' at appropriate indentation
    if lex.atLineStart or (content.len > 0 and content[^1] == '\n'):
      # Count indentation
      var indent = 0
      let savedPos = lex.pos
      while not lex.isAtEnd and lex.peek == ' ':
        indent += 1
        discard lex.advance()
      # Skip tabs too
      while not lex.isAtEnd and lex.peek == '\t':
        indent += 2
        discard lex.advance()

      # Check if we see 'end' at same or lesser indentation
      if indent <= lex.nativeIndent and not lex.isAtEnd:
        var lookahead = ""
        var tempPos = lex.pos
        while tempPos < lex.source.len and lex.source[tempPos].isAlphaAscii:
          lookahead.add(lex.source[tempPos])
          tempPos += 1
        if lookahead == "end":
          # Check that 'end' is followed by non-ident char or end of input
          if tempPos >= lex.source.len or not lex.source[tempPos].isIdentChar:
            # Found end at appropriate indentation - emit content and end token
            # Strip trailing newline from content if present
            if content.len > 0 and content[^1] == '\n':
              content = content[0..^2]
            lex.addToken(tkStringLit, content, startLine, startCol)
            # Now consume 'end'
            let endLine = lex.line
            let endCol = lex.col
            for i in 0..<3:
              discard lex.advance()
            lex.addToken(tkEnd, "end", endLine, endCol)
            lex.mode = RouteSchema
            return

      # Not end - restore to include the indentation in content
      # We already advanced past spaces, so add them to content
      let spacesConsumed = lex.pos - savedPos
      for i in 0..<spacesConsumed:
        content.add(' ')

    # Regular character - add to content
    if not lex.isAtEnd:
      let c = lex.advance()
      content.add(c)
      if c == '\n':
        lex.atLineStart = true
      else:
        lex.atLineStart = false

  # End of input - emit what we have
  lex.addToken(tkStringLit, content, startLine, startCol)

proc scanToken(lex: var Lexer) =
  ## Scan a single token in RouteSchema or Template mode.
  let c = lex.peek

  case c
  of '\n':
    let startLine = lex.line
    let startCol = lex.col
    discard lex.advance()
    if lex.mode == RouteSchema:
      lex.addToken(tkNewline, "\\n", startLine, startCol)
    lex.atLineStart = true
  of ' ', '\t':
    if lex.mode == Template and lex.atLineStart:
      # Handle indentation
      lex.handleTemplateIndent()
      lex.atLineStart = false
    else:
      # Skip whitespace
      lex.skipSpaces()
  of '#':
    if lex.peekAt(1) == '{':
      let startLine = lex.line
      let startCol = lex.col
      discard lex.advance()  # #
      discard lex.advance()  # {
      lex.addToken(tkInterpolStart, "#{", startLine, startCol)
    elif lex.mode == Template and not lex.atLineStart:
      # In template mode, # after an element tag/class is the ID shorthand marker
      let startLine = lex.line
      let startCol = lex.col
      discard lex.advance()  # consume #
      lex.addToken(tkHash, "#", startLine, startCol)
    else:
      # Comment - skip to end of line
      while not lex.isAtEnd and lex.peek != '\n':
        discard lex.advance()
  of '"':
    lex.atLineStart = false
    lex.readString()
  of ':':
    lex.atLineStart = false
    lex.readType()
  of '(':
    lex.atLineStart = false
    lex.addToken(tkLParen, "(", lex.line, lex.col)
    discard lex.advance()
  of ')':
    lex.atLineStart = false
    lex.addToken(tkRParen, ")", lex.line, lex.col)
    discard lex.advance()
  of '[':
    lex.atLineStart = false
    lex.addToken(tkLBracket, "[", lex.line, lex.col)
    discard lex.advance()
  of ']':
    lex.atLineStart = false
    lex.addToken(tkRBracket, "]", lex.line, lex.col)
    discard lex.advance()
  of ',':
    lex.atLineStart = false
    lex.addToken(tkComma, ",", lex.line, lex.col)
    discard lex.advance()
  of '.':
    lex.atLineStart = false
    lex.addToken(tkDot, ".", lex.line, lex.col)
    discard lex.advance()
  of '}':
    lex.atLineStart = false
    lex.addToken(tkInterpolEnd, "}", lex.line, lex.col)
    discard lex.advance()
  of '=', '!', '>', '<', '&':
    lex.atLineStart = false
    lex.readOperator()
  of '|':
    lex.atLineStart = false
    lex.readOperator()
  else:
    if c.isDigit:
      lex.atLineStart = false
      lex.readNumber()
    elif c.isIdentStartChar:
      lex.atLineStart = false
      lex.readIdentifierOrKeyword()
    else:
      lex.addError("Unexpected character: '" & $c & "'")
      discard lex.advance()

proc tokenizeAll*(lex: var Lexer) =
  ## Run the lexer to completion, populating lex.tokens and lex.errors.
  while not lex.isAtEnd:
    if lex.mode == Native:
      lex.scanNativeMode()
    else:
      # At the start of a new line in template mode, handle indent
      if lex.mode == Template and lex.atLineStart and lex.peek != '\n' and lex.peek != '#':
        lex.handleTemplateIndent()
        lex.atLineStart = false
      else:
        lex.scanToken()

  # Emit remaining DEDENTs in template mode
  if lex.mode == Template:
    while lex.indentStack.len > 1:
      discard lex.indentStack.pop()
      lex.addToken(tkDedent, "", lex.line, lex.col)

  lex.addToken(tkEof, "", lex.line, lex.col)

proc tokenize*(source: string, filename: string = "<input>", mode: LexMode = RouteSchema): seq[Token] =
  ## Convenience proc: tokenize a source string and return the tokens.
  var lex = newLexer(source, filename, mode)
  lex.tokenizeAll()
  result = lex.tokens

proc tokenizeWithErrors*(source: string, filename: string = "<input>", mode: LexMode = RouteSchema): (seq[Token], seq[string]) =
  ## Tokenize and also return errors.
  var lex = newLexer(source, filename, mode)
  lex.tokenizeAll()
  result = (lex.tokens, lex.errors)

proc enterNativeMode*(lex: var Lexer, indent: int) =
  ## Switch to native block mode at the given indentation level.
  lex.mode = Native
  lex.nativeIndent = indent
  lex.atLineStart = true
