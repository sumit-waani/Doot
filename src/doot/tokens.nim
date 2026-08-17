## Token types for the Doot DSL compiler.
## Defines all token kinds and the Token object used throughout the lexer and parser.

type
  TokenKind* = enum
    # Keywords
    tkRoute
    tkSchema
    tkTable
    tkField
    tkGroup
    tkDo
    tkEnd
    tkIf
    tkElse
    tkEach
    tkIn
    tkConfig
    tkMount
    tkNative
    tkRender
    tkRedirect
    tkJob
    tkSchedule
    tkAuth
    tkExtends
    tkBlock
    tkPartial

    # HTTP Methods
    tkGet
    tkPost
    tkPut
    tkDelete
    tkPatch

    # Type annotations
    tkTypeString
    tkTypeText
    tkTypeInteger
    tkTypeBoolean
    tkTypeFloat
    tkTypeDatetime

    # Literals
    tkStringLit
    tkIntLit
    tkBoolTrue
    tkBoolFalse
    tkNilLit

    # Operators
    tkAssign      # =
    tkEq          # ==
    tkNotEq       # !=
    tkGt          # >
    tkLt          # <
    tkGtEq        # >=
    tkLtEq        # <=
    tkAnd         # &&
    tkOr          # ||
    tkNot         # !

    # Delimiters
    tkLParen      # (
    tkRParen      # )
    tkLBracket    # [
    tkRBracket    # ]
    tkComma       # ,
    tkColon       # :
    tkPipe        # |
    tkDot         # .
    tkInterpolStart  # #{
    tkInterpolEnd    # }

    # Structural
    tkIdentifier
    tkIndent
    tkDedent
    tkNewline
    tkEof

  Token* = object
    kind*: TokenKind
    value*: string
    file*: string
    line*: int
    col*: int

  LexMode* = enum
    RouteSchema
    Template
    Native

proc newToken*(kind: TokenKind, value: string, file: string, line: int, col: int): Token =
  Token(kind: kind, value: value, file: file, line: line, col: col)
