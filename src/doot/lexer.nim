## Lexer for the Doot DSL compiler.
## Transforms source text into a sequence of tokens.

type
  TokenKind* = enum
    tkEof
    tkIdentifier
    tkString
    tkNumber
    tkKeyword
    tkSymbol
    tkNewline
    tkIndent
    tkDedent

  Token* = object
    kind*: TokenKind
    value*: string
    line*: int
    col*: int

proc newToken*(kind: TokenKind, value: string = "", line: int = 0, col: int = 0): Token =
  Token(kind: kind, value: value, line: line, col: col)

proc tokenize*(source: string): seq[Token] =
  ## Placeholder tokenizer - returns an EOF token.
  result = @[newToken(tkEof, "", 1, 1)]
