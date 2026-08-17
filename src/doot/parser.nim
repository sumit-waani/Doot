## Parser for the Doot DSL compiler.
## Transforms a token sequence into an AST.

import lexer
import ast

proc parse*(tokens: seq[Token]): Node =
  ## Placeholder parser - returns an empty root node.
  result = newNode(nkRoot)
