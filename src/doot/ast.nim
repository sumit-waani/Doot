## AST node types for the Doot DSL compiler.

type
  NodeKind* = enum
    nkRoot
    nkRoute
    nkTemplate
    nkExpression

  Node* = ref object
    kind*: NodeKind
    children*: seq[Node]
    value*: string

proc newNode*(kind: NodeKind, value: string = ""): Node =
  Node(kind: kind, children: @[], value: value)
