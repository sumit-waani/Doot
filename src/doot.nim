## Doot DSL Compiler
## Main entry point for the doot binary.

import doot/lexer
import doot/parser
import doot/ast

proc main() =
  echo "Doot DSL Compiler v0.1.0"
  # Placeholder: parse empty source to verify pipeline works
  let tokens = tokenize("")
  let tree = parse(tokens)
  echo "AST root kind: ", tree.kind

when isMainModule:
  main()
