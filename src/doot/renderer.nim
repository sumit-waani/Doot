## Template renderer for the Doot framework.
## Walks the template AST (produced by the parser) and generates HTML output.
## Supports auto-escaping, expression evaluation, control flow,
## template inheritance (extends/blocks), partials, doctype, style-embed,
## and HTMX auto-injection.

import std/[tables, strutils, os]
import ast
import lexer
import parser

export ast

type
  DootValueKind* = enum
    dvString
    dvInt
    dvBool
    dvNil
    dvSeq
    dvObject

  DootValue* = ref object
    case kind*: DootValueKind
    of dvString:
      strVal*: string
    of dvInt:
      intVal*: int
    of dvBool:
      boolVal*: bool
    of dvNil:
      discard
    of dvSeq:
      seqVal*: seq[DootValue]
    of dvObject:
      objFields*: Table[string, DootValue]

  TemplateContext* = object
    locals*: Table[string, DootValue]
    viewsDir*: string
    staticDir*: string
    blocks*: Table[string, seq[DootNode]]
    isLayout*: bool
    partialDepth*: int          ## Current partial nesting depth (guard against recursion)
    inheritanceDepth*: int      ## Current inheritance resolution depth (guard against cycles)

const VoidElements* = [
  "area", "base", "br", "col", "embed", "hr", "img",
  "input", "link", "meta", "source", "track", "wbr"
]

const HtmxScriptTag* = """<script src="/__doot/htmx.min.js"></script>"""

const MaxInheritanceDepth* = 10
const MaxPartialDepth* = 20

# --- DootValue constructors ---

proc newDootString*(s: string): DootValue =
  DootValue(kind: dvString, strVal: s)

proc newDootInt*(i: int): DootValue =
  DootValue(kind: dvInt, intVal: i)

proc newDootBool*(b: bool): DootValue =
  DootValue(kind: dvBool, boolVal: b)

proc newDootNil*(): DootValue =
  DootValue(kind: dvNil)

proc newDootSeq*(s: seq[DootValue] = @[]): DootValue =
  DootValue(kind: dvSeq, seqVal: s)

proc newDootObject*(fields: Table[string, DootValue] = initTable[string, DootValue]()): DootValue =
  DootValue(kind: dvObject, objFields: fields)

# --- DootValue helpers ---

proc toStr*(v: DootValue): string =
  ## Convert a DootValue to its string representation.
  if v.isNil:
    return ""
  case v.kind
  of dvString: return v.strVal
  of dvInt: return $v.intVal
  of dvBool: return $v.boolVal
  of dvNil: return ""
  of dvSeq: return "[seq:" & $v.seqVal.len & "]"
  of dvObject: return "[object]"

proc toBool*(v: DootValue): bool =
  ## Truthiness check for DootValue.
  if v.isNil:
    return false
  case v.kind
  of dvString: return v.strVal.len > 0
  of dvInt: return v.intVal != 0
  of dvBool: return v.boolVal
  of dvNil: return false
  of dvSeq: return v.seqVal.len > 0
  of dvObject: return v.objFields.len > 0

proc isEmptyCollection*(v: DootValue): bool =
  ## Check if value is an empty collection (seq or object with no fields).
  if v.isNil:
    return true
  case v.kind
  of dvSeq: return v.seqVal.len == 0
  of dvObject: return v.objFields.len == 0
  of dvString: return v.strVal.len == 0
  of dvNil: return true
  else: return false

proc count*(v: DootValue): int =
  ## Get the count/length of a collection value.
  if v.isNil:
    return 0
  case v.kind
  of dvSeq: return v.seqVal.len
  of dvString: return v.strVal.len
  of dvObject: return v.objFields.len
  else: return 0

# --- HTML escaping ---

proc escapeHtml*(s: string): string =
  ## Escape HTML special characters for safe output.
  result = ""
  for ch in s:
    case ch
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '&': result.add "&amp;"
    of '"': result.add "&quot;"
    of '\'': result.add "&#x27;"
    else: result.add ch

# --- Path validation ---

proc isPathSafe*(resolvedPath: string, allowedDir: string): bool =
  ## Validate that a resolved file path stays within the allowed directory.
  ## Prevents path traversal attacks using ".." segments.
  let normalResolved = normalizedPath(absolutePath(resolvedPath))
  let normalAllowed = normalizedPath(absolutePath(allowedDir))
  return normalResolved.startsWith(normalAllowed)

# --- Expression evaluation ---

proc evalExpr*(node: DootNode, ctx: TemplateContext): DootValue =
  ## Evaluate an expression AST node against a template context.
  if node.isNil:
    return newDootNil()

  case node.kind
  of nkIdentifier:
    if node.identName in ctx.locals:
      return ctx.locals[node.identName]
    return newDootNil()

  of nkMemberAccess:
    let obj = evalExpr(node.memberObj, ctx)
    if obj.isNil:
      return newDootNil()
    # Handle .empty? method-like access
    if node.memberProp == "empty?":
      return newDootBool(isEmptyCollection(obj))
    if node.memberProp == "count":
      return newDootInt(count(obj))
    # Object field access
    if obj.kind == dvObject:
      if node.memberProp in obj.objFields:
        return obj.objFields[node.memberProp]
    return newDootNil()

  of nkMethodCall:
    let obj = evalExpr(node.callObj, ctx)
    case node.callMethod
    of "empty?":
      return newDootBool(isEmptyCollection(obj))
    of "count":
      return newDootInt(count(obj))
    of "truncate":
      if obj.isNil or obj.kind != dvString:
        return newDootNil()
      let maxLen = if node.callArgs.len > 0:
        let arg = evalExpr(node.callArgs[0], ctx)
        if arg.kind == dvInt: arg.intVal else: 100
      else:
        100
      let s = obj.strVal
      if s.len <= maxLen:
        return newDootString(s)
      return newDootString(s[0..<maxLen] & "...")
    of "upcase", "toUpper":
      if obj.isNil or obj.kind != dvString:
        return newDootNil()
      return newDootString(obj.strVal.toUpperAscii())
    of "downcase", "toLower":
      if obj.isNil or obj.kind != dvString:
        return newDootNil()
      return newDootString(obj.strVal.toLowerAscii())
    of "length", "len":
      return newDootInt(count(obj))
    else:
      return newDootNil()

  of nkStringLit:
    if node.strInterpolations.len > 0:
      # String with interpolations: the strValue has placeholders
      # Interpolations are evaluated in order
      var result_str = node.strValue
      for interp in node.strInterpolations:
        let val = evalExpr(interp, ctx)
        let valStr = toStr(val)
        # Replace the first occurrence of the interpolation placeholder
        let placeholder = "#{}"
        let idx = result_str.find(placeholder)
        if idx >= 0:
          result_str = result_str[0..<idx] & valStr & result_str[idx + placeholder.len..^1]
      return newDootString(result_str)
    return newDootString(node.strValue)

  of nkIntLit:
    return newDootInt(node.intValue)

  of nkBoolLit:
    return newDootBool(node.boolValue)

  of nkNil:
    return newDootNil()

  of nkBinaryOp:
    case node.binOp
    of "||":
      let left = evalExpr(node.binLeft, ctx)
      if toBool(left):
        return left
      return evalExpr(node.binRight, ctx)
    of "&&":
      let left = evalExpr(node.binLeft, ctx)
      if not toBool(left):
        return left
      return evalExpr(node.binRight, ctx)
    of "==":
      let left = evalExpr(node.binLeft, ctx)
      let right = evalExpr(node.binRight, ctx)
      if left.isNil and right.isNil:
        return newDootBool(true)
      if left.isNil or right.isNil:
        return newDootBool(false)
      if left.kind != right.kind:
        return newDootBool(false)
      case left.kind
      of dvString: return newDootBool(left.strVal == right.strVal)
      of dvInt: return newDootBool(left.intVal == right.intVal)
      of dvBool: return newDootBool(left.boolVal == right.boolVal)
      of dvNil: return newDootBool(true)
      else: return newDootBool(false)
    of "!=":
      let left = evalExpr(node.binLeft, ctx)
      let right = evalExpr(node.binRight, ctx)
      if left.isNil and right.isNil:
        return newDootBool(false)
      if left.isNil or right.isNil:
        return newDootBool(true)
      if left.kind != right.kind:
        return newDootBool(true)
      case left.kind
      of dvString: return newDootBool(left.strVal != right.strVal)
      of dvInt: return newDootBool(left.intVal != right.intVal)
      of dvBool: return newDootBool(left.boolVal != right.boolVal)
      of dvNil: return newDootBool(false)
      else: return newDootBool(true)
    of "+":
      let left = evalExpr(node.binLeft, ctx)
      let right = evalExpr(node.binRight, ctx)
      if left.kind == dvInt and right.kind == dvInt:
        return newDootInt(left.intVal + right.intVal)
      return newDootString(toStr(left) & toStr(right))
    of "-":
      let left = evalExpr(node.binLeft, ctx)
      let right = evalExpr(node.binRight, ctx)
      if left.kind == dvInt and right.kind == dvInt:
        return newDootInt(left.intVal - right.intVal)
      return newDootNil()
    else:
      return newDootNil()

  of nkUnaryOp:
    case node.unaryOp
    of "!":
      let val = evalExpr(node.unaryOperand, ctx)
      return newDootBool(not toBool(val))
    of "-":
      let val = evalExpr(node.unaryOperand, ctx)
      if val.kind == dvInt:
        return newDootInt(-val.intVal)
      return newDootNil()
    else:
      return newDootNil()

  of nkArrayLit:
    var items: seq[DootValue] = @[]
    for elem in node.arrayElements:
      items.add(evalExpr(elem, ctx))
    return newDootSeq(items)

  else:
    return newDootNil()

# --- Forward declarations ---

{.push gcsafe.}

proc renderNodes*(nodes: seq[DootNode], ctx: TemplateContext): string
proc renderNode*(node: DootNode, ctx: TemplateContext): string
proc interpolateString*(s: string, ctx: TemplateContext): string

# --- Attribute value evaluation ---

proc evalAttrValue*(node: DootNode, ctx: TemplateContext): string =
  ## Evaluate an expression node and return its string value for use in attributes.
  let val = evalExpr(node, ctx)
  return toStr(val)

proc evalInterpolationExpr*(exprStr: string, ctx: TemplateContext): string =
  ## Evaluate a simple expression string from #{...} interpolation.
  ## Handles: identifier, member.access, and member.access.chain
  let parts = exprStr.split('.')
  if parts.len == 0:
    return ""
  # Look up the first identifier
  let firstPart = parts[0].strip()
  if firstPart notin ctx.locals:
    return ""
  var current = ctx.locals[firstPart]
  for i in 1..<parts.len:
    let prop = parts[i].strip()
    if current.isNil:
      return ""
    if current.kind == dvObject and prop in current.objFields:
      current = current.objFields[prop]
    else:
      return ""
  return toStr(current)

proc interpolateString*(s: string, ctx: TemplateContext): string =
  ## Interpolate #{expr} placeholders in a string using the context.
  ## This handles the raw string format where strValue contains literal text
  ## with #{varname} markers.
  result = ""
  var i = 0
  while i < s.len:
    if i + 1 < s.len and s[i] == '#' and s[i+1] == '{':
      # Find the closing brace
      let start = i + 2
      var depth = 1
      var j = start
      while j < s.len and depth > 0:
        if s[j] == '{': inc depth
        elif s[j] == '}': dec depth
        inc j
      let exprStr = s[start..<(j-1)]
      # Parse and evaluate the expression within the interpolation
      let val = evalInterpolationExpr(exprStr, ctx)
      result.add val
      i = j
    else:
      result.add s[i]
      inc i

# --- Node rendering ---

proc renderElement*(node: DootNode, ctx: TemplateContext): string =
  ## Render an element node to HTML.
  let tag = node.elemTag

  # Handle doctype special case
  if tag == "doctype":
    let text = node.elemText.strip()
    if text == "html" or text == "":
      return "<!DOCTYPE html>\n"
    return "<!DOCTYPE " & text & ">\n"

  # Handle style-embed directive
  if tag == "style-embed":
    let cssFile = node.elemText.strip().strip(chars = {'"', '\''})
    let cssPath = ctx.staticDir / cssFile
    if not isPathSafe(cssPath, ctx.staticDir):
      return "<style>/* path traversal blocked: " & escapeHtml(cssFile) & " */</style>\n"
    if fileExists(cssPath):
      let cssContent = readFile(cssPath)
      return "<style>" & cssContent & "</style>\n"
    else:
      return "<style>/* File not found: " & cssFile & " */</style>\n"

  # Build opening tag
  var html = "<" & tag

  # Add ID attribute
  if node.elemId.len > 0:
    html.add " id=\"" & node.elemId & "\""

  # Add class attribute from class shorthand
  if node.elemClasses.len > 0:
    html.add " class=\"" & node.elemClasses.join(" ") & "\""

  # Add explicit attributes
  for attr in node.elemAttrs:
    html.add " " & attr.key & "=\""
    if attr.value != nil:
      let val = evalAttrValue(attr.value, ctx)
      html.add val
    html.add "\""

  # Check if void element
  let isVoid = tag in VoidElements

  if isVoid:
    html.add ">"
    return html

  html.add ">"

  # Content: expression output, text, or children
  var hasContent = false

  if node.elemExprOutput != nil:
    let val = evalExpr(node.elemExprOutput, ctx)
    let valStr = toStr(val)
    if node.elemEscaped:
      html.add escapeHtml(valStr)
    else:
      html.add valStr
    hasContent = true
  elif node.elemText.len > 0:
    # Interpolate text content
    let interpolated = interpolateString(node.elemText, ctx)
    html.add interpolated
    hasContent = true

  # Render children
  if node.elemChildren.len > 0:
    html.add "\n"
    for child in node.elemChildren:
      html.add renderNode(child, ctx)
    hasContent = true

  # Check for HTMX injection in head element (layouts and standalone templates)
  if tag == "head":
    html.add HtmxScriptTag & "\n"

  html.add "</" & tag & ">"
  if not hasContent or node.elemChildren.len > 0:
    html.add "\n"

  return html

proc renderExprOutput*(node: DootNode, ctx: TemplateContext): string =
  ## Render an expression output node.
  let val = evalExpr(node.exprOutExpr, ctx)
  let valStr = toStr(val)
  if node.exprOutEscaped:
    return escapeHtml(valStr)
  else:
    return valStr

proc renderText*(node: DootNode, ctx: TemplateContext): string =
  ## Render a text node.
  return interpolateString(node.textContent, ctx)

proc renderTemplateIf*(node: DootNode, ctx: TemplateContext): string =
  ## Render a conditional (if/else) node.
  let condVal = evalExpr(node.tmplIfCondition, ctx)
  if toBool(condVal):
    return renderNodes(node.tmplIfThen, ctx)
  else:
    return renderNodes(node.tmplIfElse, ctx)

proc renderTemplateEach*(node: DootNode, ctx: TemplateContext): string =
  ## Render an each loop node.
  let collection = evalExpr(node.tmplEachCollection, ctx)
  if collection.isNil or collection.kind != dvSeq:
    return ""
  result = ""
  for item in collection.seqVal:
    var loopCtx = ctx
    loopCtx.locals = ctx.locals  # Copy the table
    loopCtx.locals[node.tmplEachVar] = item
    result.add renderNodes(node.tmplEachBody, loopCtx)

proc renderPartial*(node: DootNode, ctx: TemplateContext): string =
  ## Render a partial template with its own locals.
  ## Includes depth guard to prevent infinite recursion from self-referencing partials.
  if ctx.partialDepth >= MaxPartialDepth:
    return "<!-- partial recursion limit reached: " & node.partialPath & " -->"

  let partialPath = node.partialPath

  # Build locals for the partial
  var partialLocals = initTable[string, DootValue]()
  for kv in node.partialLocals:
    partialLocals[kv.key] = evalExpr(kv.value, ctx)

  # Resolve partial file path
  # Try: views/path.do, views/_path.do, views/path/_partial.do
  var resolvedPath = ""
  let basePath = ctx.viewsDir / partialPath
  if fileExists(basePath & ".do"):
    resolvedPath = basePath & ".do"
  else:
    # Try underscore prefix convention
    let dir = parentDir(basePath)
    let filename = extractFilename(basePath)
    let underscorePath = dir / ("_" & filename & ".do")
    if fileExists(underscorePath):
      resolvedPath = underscorePath
    elif fileExists(basePath & ".do"):
      resolvedPath = basePath & ".do"

  if resolvedPath == "":
    return "<!-- partial not found: " & partialPath & " -->"

  # Validate path stays within viewsDir (prevent path traversal)
  if not isPathSafe(resolvedPath, ctx.viewsDir):
    return "<!-- partial path traversal blocked: " & escapeHtml(partialPath) & " -->"

  # Parse and render the partial
  let source = readFile(resolvedPath)
  var tmplAst: DootNode
  {.cast(gcsafe).}:
    let tokens = tokenize(source, resolvedPath, Template)
    tmplAst = parseTemplateTokens(tokens, resolvedPath)

  var partialCtx = TemplateContext(
    locals: partialLocals,
    viewsDir: ctx.viewsDir,
    staticDir: ctx.staticDir,
    blocks: initTable[string, seq[DootNode]](),
    isLayout: false,
    partialDepth: ctx.partialDepth + 1,
    inheritanceDepth: 0
  )

  return renderNodes(tmplAst.tmplBody, partialCtx)

proc renderBlockDef*(node: DootNode, ctx: TemplateContext): string =
  ## Render a block definition. If the block was overridden (from child template),
  ## render the override. Otherwise render the default content.
  if node.blockName in ctx.blocks:
    return renderNodes(ctx.blocks[node.blockName], ctx)
  else:
    return renderNodes(node.blockContent, ctx)

proc renderNode*(node: DootNode, ctx: TemplateContext): string =
  ## Render a single AST node to HTML.
  if node.isNil:
    return ""
  case node.kind
  of nkElement:
    return renderElement(node, ctx)
  of nkExprOutput:
    return renderExprOutput(node, ctx)
  of nkText:
    return renderText(node, ctx)
  of nkTemplateIf:
    return renderTemplateIf(node, ctx)
  of nkTemplateEach:
    return renderTemplateEach(node, ctx)
  of nkPartial:
    return renderPartial(node, ctx)
  of nkBlockDef:
    return renderBlockDef(node, ctx)
  else:
    return ""

proc renderNodes*(nodes: seq[DootNode], ctx: TemplateContext): string =
  ## Render a sequence of nodes.
  result = ""
  for node in nodes:
    result.add renderNode(node, ctx)

# --- Template inheritance ---

proc collectBlocks*(nodes: seq[DootNode]): Table[string, seq[DootNode]] =
  ## Collect block definitions from template body nodes.
  result = initTable[string, seq[DootNode]]()
  for node in nodes:
    if node.kind == nkBlockDef:
      result[node.blockName] = node.blockContent

proc resolveInheritance*(tmplAst: DootNode, ctx: TemplateContext): string =
  ## Resolve template inheritance and render the final output.
  ## If the template extends a layout, load the layout, pass blocks to it,
  ## and render the layout with the child's block overrides.
  ## Includes depth guard to prevent infinite recursion on cyclic extends.
  if ctx.inheritanceDepth >= MaxInheritanceDepth:
    return "<!-- inheritance cycle detected (max depth " & $MaxInheritanceDepth & " exceeded) -->"

  if tmplAst.tmplExtends.len > 0:
    # Collect blocks from the child template
    var childBlocks = collectBlocks(tmplAst.tmplBlocks)
    # Also collect from body in case blocks are there
    let bodyBlocks = collectBlocks(tmplAst.tmplBody)
    for name, content in bodyBlocks:
      childBlocks[name] = content

    # If we already have blocks from a deeper child (passed via ctx.blocks),
    # those take priority over our own blocks (deep inheritance support)
    for name, content in ctx.blocks:
      childBlocks[name] = content

    # Load the parent/layout template
    let layoutPath = ctx.viewsDir / tmplAst.tmplExtends & ".do"
    if not fileExists(layoutPath):
      return "<!-- layout not found: " & tmplAst.tmplExtends & " -->"

    let layoutSource = readFile(layoutPath)
    var layoutAst: DootNode
    {.cast(gcsafe).}:
      let layoutTokens = tokenize(layoutSource, layoutPath, Template)
      layoutAst = parseTemplateTokens(layoutTokens, layoutPath)

    # Merge blocks: child blocks override parent blocks
    var mergedBlocks = childBlocks

    # Set up context for layout rendering
    var layoutCtx = ctx
    layoutCtx.blocks = mergedBlocks
    layoutCtx.isLayout = true
    layoutCtx.inheritanceDepth = ctx.inheritanceDepth + 1

    # Check for deep inheritance (layout extends another layout)
    if layoutAst.tmplExtends.len > 0:
      # Collect the layout's own blocks as defaults
      let layoutBlocks = collectBlocks(layoutAst.tmplBlocks)
      let layoutBodyBlocks = collectBlocks(layoutAst.tmplBody)
      # For blocks not overridden by child, use layout defaults
      for name, content in layoutBlocks:
        if name notin mergedBlocks:
          mergedBlocks[name] = content
      for name, content in layoutBodyBlocks:
        if name notin mergedBlocks:
          mergedBlocks[name] = content
      layoutCtx.blocks = mergedBlocks
      return resolveInheritance(layoutAst, layoutCtx)

    # Render layout body with block substitution
    return renderNodes(layoutAst.tmplBody, layoutCtx)
  else:
    # No inheritance, render directly
    return renderNodes(tmplAst.tmplBody, ctx)

# --- Main render entry point ---

proc renderTemplate*(templatePath: string, locals: Table[string, DootValue],
                     viewsDir: string = "views",
                     staticDir: string = "static"): string =
  ## Render a template file to HTML string.
  ## templatePath is relative to viewsDir (without .do extension).
  let fullPath = viewsDir / templatePath & ".do"

  if not fileExists(fullPath):
    return ""

  let source = readFile(fullPath)
  var tmplAst: DootNode
  {.cast(gcsafe).}:
    let tokens = tokenize(source, fullPath, Template)
    tmplAst = parseTemplateTokens(tokens, fullPath)

  var ctx = TemplateContext(
    locals: locals,
    viewsDir: viewsDir,
    staticDir: staticDir,
    blocks: initTable[string, seq[DootNode]](),
    isLayout: false
  )

  return resolveInheritance(tmplAst, ctx)

proc renderTemplateFromSource*(source: string, locals: Table[string, DootValue],
                               viewsDir: string = "views",
                               staticDir: string = "static",
                               filename: string = "<input>"): string =
  ## Render a template from source string (useful for testing).
  var tmplAst: DootNode
  {.cast(gcsafe).}:
    let tokens = tokenize(source, filename, Template)
    tmplAst = parseTemplateTokens(tokens, filename)

  var ctx = TemplateContext(
    locals: locals,
    viewsDir: viewsDir,
    staticDir: staticDir,
    blocks: initTable[string, seq[DootNode]](),
    isLayout: false
  )

  return resolveInheritance(tmplAst, ctx)
