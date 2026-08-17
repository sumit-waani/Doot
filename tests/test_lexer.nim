import unittest
import std/strutils
import ../src/doot/lexer

suite "Lexer - Keywords":
  test "all 22 keywords tokenize correctly":
    let keywords = @[
      ("route", tkRoute), ("schema", tkSchema), ("table", tkTable),
      ("field", tkField), ("group", tkGroup), ("do", tkDo),
      ("end", tkEnd), ("if", tkIf), ("else", tkElse),
      ("each", tkEach), ("in", tkIn), ("config", tkConfig),
      ("mount", tkMount), ("native", tkNative), ("render", tkRender),
      ("redirect", tkRedirect), ("job", tkJob), ("schedule", tkSchedule),
      ("auth", tkAuth), ("extends", tkExtends), ("block", tkBlock),
      ("partial", tkPartial),
    ]
    for (word, expectedKind) in keywords:
      let tokens = tokenize(word)
      check tokens[0].kind == expectedKind
      check tokens[0].value == word

suite "Lexer - HTTP Methods":
  test "all 5 HTTP methods tokenize correctly":
    let methods = @[
      ("GET", tkGet), ("POST", tkPost), ("PUT", tkPut),
      ("DELETE", tkDelete), ("PATCH", tkPatch),
    ]
    for (word, expectedKind) in methods:
      let tokens = tokenize(word)
      check tokens[0].kind == expectedKind
      check tokens[0].value == word

suite "Lexer - Type Tokens":
  test "all 6 type annotations tokenize correctly":
    let types = @[
      (":string", tkTypeString), (":text", tkTypeText),
      (":integer", tkTypeInteger), (":boolean", tkTypeBoolean),
      (":float", tkTypeFloat), (":datetime", tkTypeDatetime),
    ]
    for (word, expectedKind) in types:
      let tokens = tokenize(word)
      check tokens[0].kind == expectedKind
      check tokens[0].value == word

  test "colon followed by non-type is colon + identifier":
    let tokens = tokenize(":unknown")
    check tokens[0].kind == tkColon
    check tokens[1].kind == tkIdentifier
    check tokens[1].value == "unknown"

  test "standalone colon":
    let tokens = tokenize(":")
    check tokens[0].kind == tkColon

suite "Lexer - String Literals":
  test "simple string literal":
    let tokens = tokenize("\"hello world\"")
    check tokens[0].kind == tkStringLit
    check tokens[0].value == "hello world"

  test "empty string literal":
    let tokens = tokenize("\"\"")
    check tokens[0].kind == tkStringLit
    check tokens[0].value == ""

  test "string with escape sequences":
    let tokens = tokenize("\"hello\\nworld\"")
    check tokens[0].kind == tkStringLit
    check tokens[0].value == "hello\nworld"

  test "string with interpolation":
    let tokens = tokenize("\"hello #{name} world\"")
    check tokens.len == 6  # StringLit + InterpolStart + Ident + InterpolEnd + StringLit + EOF
    check tokens[0].kind == tkStringLit
    check tokens[0].value == "hello "
    check tokens[1].kind == tkInterpolStart
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "name"
    check tokens[3].kind == tkInterpolEnd
    check tokens[4].kind == tkStringLit
    check tokens[4].value == " world"

  test "string with interpolation at start":
    let tokens = tokenize("\"#{name} world\"")
    check tokens[0].kind == tkStringLit
    check tokens[0].value == ""
    check tokens[1].kind == tkInterpolStart
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "name"
    check tokens[3].kind == tkInterpolEnd
    check tokens[4].kind == tkStringLit
    check tokens[4].value == " world"

  test "string with interpolation at end":
    let tokens = tokenize("\"hello #{name}\"")
    check tokens[0].kind == tkStringLit
    check tokens[0].value == "hello "
    check tokens[1].kind == tkInterpolStart
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "name"
    check tokens[3].kind == tkInterpolEnd
    check tokens[4].kind == tkStringLit
    check tokens[4].value == ""

  test "string with expression in interpolation":
    let tokens = tokenize("\"count: #{items.length}\"")
    check tokens[0].kind == tkStringLit
    check tokens[0].value == "count: "
    check tokens[1].kind == tkInterpolStart
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "items"
    check tokens[3].kind == tkDot
    check tokens[4].kind == tkIdentifier
    check tokens[4].value == "length"
    check tokens[5].kind == tkInterpolEnd
    check tokens[6].kind == tkStringLit
    check tokens[6].value == ""

  test "string without interpolation - no hash without brace":
    let tokens = tokenize("\"hello # world\"")
    check tokens[0].kind == tkStringLit
    # The '#' without '{' is treated as a comment char inside string? No, it's literal
    # Actually in the string scanner, '#' alone is just added to value
    # Let me check - the scanner checks peek == '#' and peekAt(1) == '{'
    # So '#' alone stays as literal
    check tokens[0].value == "hello # world"

suite "Lexer - Integer Literals":
  test "single digit":
    let tokens = tokenize("5")
    check tokens[0].kind == tkIntLit
    check tokens[0].value == "5"

  test "multi-digit":
    let tokens = tokenize("3000")
    check tokens[0].kind == tkIntLit
    check tokens[0].value == "3000"

  test "zero":
    let tokens = tokenize("0")
    check tokens[0].kind == tkIntLit
    check tokens[0].value == "0"

suite "Lexer - Boolean Literals":
  test "true":
    let tokens = tokenize("true")
    check tokens[0].kind == tkBoolTrue
    check tokens[0].value == "true"

  test "false":
    let tokens = tokenize("false")
    check tokens[0].kind == tkBoolFalse
    check tokens[0].value == "false"

suite "Lexer - Nil Literal":
  test "nil":
    let tokens = tokenize("nil")
    check tokens[0].kind == tkNilLit
    check tokens[0].value == "nil"

suite "Lexer - Operators":
  test "assign operator":
    let tokens = tokenize("=")
    check tokens[0].kind == tkAssign
    check tokens[0].value == "="

  test "equality operator":
    let tokens = tokenize("==")
    check tokens[0].kind == tkEq
    check tokens[0].value == "=="

  test "not-equal operator":
    let tokens = tokenize("!=")
    check tokens[0].kind == tkNotEq
    check tokens[0].value == "!="

  test "greater-than operator":
    let tokens = tokenize(">")
    check tokens[0].kind == tkGt
    check tokens[0].value == ">"

  test "less-than operator":
    let tokens = tokenize("<")
    check tokens[0].kind == tkLt
    check tokens[0].value == "<"

  test "greater-than-or-equal operator":
    let tokens = tokenize(">=")
    check tokens[0].kind == tkGtEq
    check tokens[0].value == ">="

  test "less-than-or-equal operator":
    let tokens = tokenize("<=")
    check tokens[0].kind == tkLtEq
    check tokens[0].value == "<="

  test "and operator":
    let tokens = tokenize("&&")
    check tokens[0].kind == tkAnd
    check tokens[0].value == "&&"

  test "or operator":
    let tokens = tokenize("||")
    check tokens[0].kind == tkOr
    check tokens[0].value == "||"

  test "not operator":
    let tokens = tokenize("!")
    check tokens[0].kind == tkNot
    check tokens[0].value == "!"

suite "Lexer - Delimiters":
  test "parentheses":
    let tokens = tokenize("()")
    check tokens[0].kind == tkLParen
    check tokens[1].kind == tkRParen

  test "brackets":
    let tokens = tokenize("[]")
    check tokens[0].kind == tkLBracket
    check tokens[1].kind == tkRBracket

  test "comma":
    let tokens = tokenize(",")
    check tokens[0].kind == tkComma

  test "colon":
    let tokens = tokenize(":")
    check tokens[0].kind == tkColon

  test "pipe":
    let tokens = tokenize("| ")
    # Need a space after | to distinguish from ||
    check tokens[0].kind == tkPipe

  test "dot":
    let tokens = tokenize(".")
    check tokens[0].kind == tkDot

suite "Lexer - Identifiers":
  test "simple identifier":
    let tokens = tokenize("hello")
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "hello"

  test "identifier with underscore":
    let tokens = tokenize("session_secret")
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "session_secret"

  test "identifier with question mark":
    let tokens = tokenize("admin?")
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "admin?"

  test "identifier with numbers":
    let tokens = tokenize("post123")
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "post123"

  test "identifier starting with underscore":
    let tokens = tokenize("_private")
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "_private"

suite "Lexer - Newlines in RouteSchema Mode":
  test "newlines produce newline tokens":
    let tokens = tokenize("a\nb")
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "a"
    check tokens[1].kind == tkNewline
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "b"

  test "multiple newlines":
    let tokens = tokenize("a\n\nb")
    check tokens[0].kind == tkIdentifier
    check tokens[1].kind == tkNewline
    check tokens[2].kind == tkNewline
    check tokens[3].kind == tkIdentifier

suite "Lexer - Template Mode Indentation":
  test "basic indent":
    let tokens = tokenize("a\n  b", mode = Template)
    # a, then newline is not emitted in template mode, then indent, then b
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "a"
    check tokens[1].kind == tkIndent
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "b"

  test "indent and dedent":
    let tokens = tokenize("a\n  b\nc", mode = Template)
    check tokens[0].kind == tkIdentifier  # a
    check tokens[0].value == "a"
    check tokens[1].kind == tkIndent      # indent to 2
    check tokens[2].kind == tkIdentifier  # b
    check tokens[2].value == "b"
    check tokens[3].kind == tkDedent      # dedent back to 0
    check tokens[4].kind == tkIdentifier  # c
    check tokens[4].value == "c"

  test "multiple indent levels":
    let tokens = tokenize("a\n  b\n    c\nd", mode = Template)
    check tokens[0].kind == tkIdentifier  # a
    check tokens[1].kind == tkIndent      # 0 -> 2
    check tokens[2].kind == tkIdentifier  # b
    check tokens[3].kind == tkIndent      # 2 -> 4
    check tokens[4].kind == tkIdentifier  # c
    check tokens[5].kind == tkDedent      # 4 -> 0
    check tokens[6].kind == tkDedent      # (second dedent)
    check tokens[7].kind == tkIdentifier  # d

  test "dedents emitted at EOF":
    let tokens = tokenize("a\n  b\n    c", mode = Template)
    # Should end with dedent tokens back to 0
    var dedentCount = 0
    for tok in tokens:
      if tok.kind == tkDedent:
        dedentCount += 1
    check dedentCount == 2

  test "tab rejection in template mode":
    let (_, errors) = tokenizeWithErrors("\ta", mode = Template)
    check errors.len > 0
    check errors[0].contains("Tabs are not allowed")

suite "Lexer - Position Tracking":
  test "first token position":
    let tokens = tokenize("hello", "test.do")
    check tokens[0].line == 1
    check tokens[0].col == 1
    check tokens[0].file == "test.do"

  test "second line position":
    let tokens = tokenize("a\nhello", "test.do")
    # a at line 1 col 1, newline, hello at line 2 col 1
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "hello"
    check tokens[2].line == 2
    check tokens[2].col == 1

  test "column tracking within a line":
    let tokens = tokenize("a b c")
    check tokens[0].col == 1  # a
    check tokens[1].col == 3  # b
    check tokens[2].col == 5  # c

  test "string literal position":
    let tokens = tokenize("x \"hello\"")
    check tokens[0].col == 1  # x
    check tokens[1].col == 3  # "hello"

  test "EOF token has correct position":
    let tokens = tokenize("ab", "f.do")
    let eof = tokens[^1]
    check eof.kind == tkEof
    check eof.file == "f.do"

suite "Lexer - Error Handling":
  test "unexpected character produces error":
    let (tokens, errors) = tokenizeWithErrors("a @ b")
    check errors.len > 0
    check errors[0].contains("@")
    # Should still tokenize the rest
    var identCount = 0
    for tok in tokens:
      if tok.kind == tkIdentifier:
        identCount += 1
    check identCount == 2

  test "multiple errors in one pass":
    let (_, errors) = tokenizeWithErrors("a @ b ~ c")
    check errors.len == 2

  test "error includes file and position":
    let (_, errors) = tokenizeWithErrors("@", "app.do")
    check errors[0].contains("app.do")
    check errors[0].contains("1")

suite "Lexer - Native Block Mode":
  test "native mode captures raw content":
    var lex = newLexer("  puts 'hello'\n  x = 1\nend", "<input>", Native)
    lex.nativeIndent = 0
    lex.atLineStart = true
    lex.tokenizeAll()
    # Should have a string lit with raw content, then end, then EOF
    check lex.tokens[0].kind == tkStringLit
    check lex.tokens[0].value.contains("puts 'hello'")
    check lex.tokens[1].kind == tkEnd
    check lex.tokens[2].kind == tkEof

  test "native mode respects indentation for end":
    var lex = newLexer("  code here\n  more code\nend", "<input>", Native)
    lex.nativeIndent = 0
    lex.atLineStart = true
    lex.tokenizeAll()
    check lex.tokens[0].kind == tkStringLit
    check lex.tokens[1].kind == tkEnd

suite "Lexer - Route/Schema Mode Examples":
  test "config block":
    let source = "config do\n  port 3000\nend"
    let tokens = tokenize(source)
    check tokens[0].kind == tkConfig
    check tokens[0].value == "config"
    check tokens[1].kind == tkDo
    check tokens[2].kind == tkNewline
    check tokens[3].kind == tkIdentifier
    check tokens[3].value == "port"
    check tokens[4].kind == tkIntLit
    check tokens[4].value == "3000"
    check tokens[5].kind == tkNewline
    check tokens[6].kind == tkEnd

  test "route declaration":
    let source = "route GET \"/posts\" do"
    let tokens = tokenize(source)
    check tokens[0].kind == tkRoute
    check tokens[1].kind == tkGet
    check tokens[2].kind == tkStringLit
    check tokens[2].value == "/posts"
    check tokens[3].kind == tkDo

  test "route with pipe parameter":
    let source = "route GET \"/posts/:id\" do |ctx|"
    let tokens = tokenize(source)
    check tokens[0].kind == tkRoute
    check tokens[1].kind == tkGet
    check tokens[2].kind == tkStringLit
    # /posts/:id - the :id is inside a string so it's literal
    check tokens[2].value == "/posts/:id"
    check tokens[3].kind == tkDo
    check tokens[4].kind == tkPipe
    check tokens[5].kind == tkIdentifier
    check tokens[5].value == "ctx"
    check tokens[6].kind == tkPipe

  test "assignment expression":
    let source = "x = 5"
    let tokens = tokenize(source)
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "x"
    check tokens[1].kind == tkAssign
    check tokens[2].kind == tkIntLit
    check tokens[2].value == "5"

  test "method call with dot":
    let source = "db.posts.find(id)"
    let tokens = tokenize(source)
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "db"
    check tokens[1].kind == tkDot
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "posts"
    check tokens[3].kind == tkDot
    check tokens[4].kind == tkIdentifier
    check tokens[4].value == "find"
    check tokens[5].kind == tkLParen
    check tokens[6].kind == tkIdentifier
    check tokens[6].value == "id"
    check tokens[7].kind == tkRParen

suite "Lexer - Template Mode Examples":
  test "extends and block":
    let source = "extends \"layouts/base\"\n\nblock content\n  h1 \"All Posts\""
    let tokens = tokenize(source, mode = Template)
    check tokens[0].kind == tkExtends
    check tokens[1].kind == tkStringLit
    check tokens[1].value == "layouts/base"
    # After blank line and "block content"
    var foundBlock = false
    for tok in tokens:
      if tok.kind == tkBlock:
        foundBlock = true
        break
    check foundBlock

  test "nested indentation with template elements":
    let source = "div\n  h1 \"Title\"\n  p \"text\""
    let tokens = tokenize(source, mode = Template)
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "div"
    check tokens[1].kind == tkIndent
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "h1"
    check tokens[3].kind == tkStringLit
    check tokens[3].value == "Title"

  test "each loop in template":
    let source = "each post in posts\n  div\n    h2 \"title\""
    let tokens = tokenize(source, mode = Template)
    check tokens[0].kind == tkEach
    check tokens[1].kind == tkIdentifier
    check tokens[1].value == "post"
    check tokens[2].kind == tkIn
    check tokens[3].kind == tkIdentifier
    check tokens[3].value == "posts"

suite "Lexer - Comments":
  test "comment skips to end of line":
    let tokens = tokenize("a # this is a comment\nb")
    check tokens[0].kind == tkIdentifier
    check tokens[0].value == "a"
    check tokens[1].kind == tkNewline
    check tokens[2].kind == tkIdentifier
    check tokens[2].value == "b"

  test "line starting with comment":
    let tokens = tokenize("# comment\na")
    check tokens[0].kind == tkNewline
    check tokens[1].kind == tkIdentifier
    check tokens[1].value == "a"

suite "Lexer - Empty and Edge Cases":
  test "empty source produces EOF token":
    let tokens = tokenize("")
    check tokens.len == 1
    check tokens[0].kind == tkEof

  test "whitespace only source":
    let tokens = tokenize("   ")
    check tokens.len == 1
    check tokens[0].kind == tkEof

  test "single newline":
    let tokens = tokenize("\n")
    check tokens[0].kind == tkNewline
    check tokens[1].kind == tkEof
