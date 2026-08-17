## Tests for the Doot template renderer.
## Verifies expression evaluation, HTML rendering, escaping, control flow,
## inheritance, partials, style-embed, HTMX injection, and all acceptance criteria.

import std/[unittest, tables, os, strutils]
import ../src/doot/renderer
import ../src/doot/response

# Helper to create test views directory structure
proc setupTestViews() =
  createDir("tests/test_views/layouts")
  createDir("tests/test_views/partials")
  createDir("tests/test_views/posts")
  createDir("tests/test_views/pages")
  createDir("tests/test_views/comments")
  createDir("tests/test_static")

proc cleanupTestViews() =
  removeDir("tests/test_views")
  removeDir("tests/test_static")

# Setup before tests
setupTestViews()

suite "Template Renderer - HTML Escaping":
  test "escapeHtml escapes all special characters":
    check escapeHtml("<script>") == "&lt;script&gt;"
    check escapeHtml("a & b") == "a &amp; b"
    check escapeHtml("\"hello\"") == "&quot;hello&quot;"
    check escapeHtml("it's") == "it&#x27;s"
    check escapeHtml("<b>A & 'B' \"C\"</b>") == "&lt;b&gt;A &amp; &#x27;B&#x27; &quot;C&quot;&lt;/b&gt;"

  test "escapeHtml with no special chars":
    check escapeHtml("hello world") == "hello world"
    check escapeHtml("") == ""

  test "escapeHtml with all five special chars combined":
    check escapeHtml("<>&\"'") == "&lt;&gt;&amp;&quot;&#x27;"

suite "Template Renderer - DootValue":
  test "DootValue constructors":
    let s = newDootString("hello")
    check s.kind == dvString
    check s.strVal == "hello"

    let i = newDootInt(42)
    check i.kind == dvInt
    check i.intVal == 42

    let b = newDootBool(true)
    check b.kind == dvBool
    check b.boolVal == true

    let n = newDootNil()
    check n.kind == dvNil

  test "DootValue toStr":
    check toStr(newDootString("hi")) == "hi"
    check toStr(newDootInt(99)) == "99"
    check toStr(newDootBool(true)) == "true"
    check toStr(newDootNil()) == ""

  test "DootValue toBool - truthiness":
    check toBool(newDootString("x")) == true
    check toBool(newDootString("")) == false
    check toBool(newDootInt(1)) == true
    check toBool(newDootInt(0)) == false
    check toBool(newDootBool(true)) == true
    check toBool(newDootBool(false)) == false
    check toBool(newDootNil()) == false
    check toBool(newDootSeq(@[newDootString("a")])) == true
    check toBool(newDootSeq(@[])) == false

  test "DootValue isEmptyCollection":
    check isEmptyCollection(newDootSeq(@[])) == true
    check isEmptyCollection(newDootSeq(@[newDootInt(1)])) == false
    check isEmptyCollection(newDootNil()) == true

  test "DootValue count":
    check count(newDootSeq(@[newDootInt(1), newDootInt(2)])) == 2
    check count(newDootSeq(@[])) == 0
    check count(newDootString("hello")) == 5
    check count(newDootNil()) == 0

suite "Template Renderer - Expression Evaluation":
  test "identifier lookup":
    var ctx = TemplateContext(
      locals: {"name": newDootString("Alice")}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newIdentifierNode("name")
    let result = evalExpr(node, ctx)
    check result.kind == dvString
    check result.strVal == "Alice"

  test "identifier missing returns nil":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newIdentifierNode("unknown")
    let result = evalExpr(node, ctx)
    check result.kind == dvNil

  test "member access on object":
    var postFields = {"title": newDootString("Hello World")}.toTable
    var ctx = TemplateContext(
      locals: {"post": newDootObject(postFields)}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let memberNode = newMemberAccessNode(newIdentifierNode("post"), "title")
    let result = evalExpr(memberNode, ctx)
    check result.kind == dvString
    check result.strVal == "Hello World"

  test "member access .empty? on empty seq":
    var ctx = TemplateContext(
      locals: {"posts": newDootSeq(@[])}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let memberNode = newMemberAccessNode(newIdentifierNode("posts"), "empty?")
    let result = evalExpr(memberNode, ctx)
    check result.kind == dvBool
    check result.boolVal == true

  test "member access .empty? on non-empty seq":
    var ctx = TemplateContext(
      locals: {"posts": newDootSeq(@[newDootString("a")])}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let memberNode = newMemberAccessNode(newIdentifierNode("posts"), "empty?")
    let result = evalExpr(memberNode, ctx)
    check result.kind == dvBool
    check result.boolVal == false

  test "member access .count":
    var ctx = TemplateContext(
      locals: {"items": newDootSeq(@[newDootInt(1), newDootInt(2), newDootInt(3)])}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let memberNode = newMemberAccessNode(newIdentifierNode("items"), "count")
    let result = evalExpr(memberNode, ctx)
    check result.kind == dvInt
    check result.intVal == 3

  test "binary op || (or)":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newBinaryOpNode(newNilNode(), "||", newStringLitNode("default"))
    let result = evalExpr(node, ctx)
    check result.kind == dvString
    check result.strVal == "default"

  test "binary op || returns left when truthy":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newBinaryOpNode(newStringLitNode("present"), "||", newStringLitNode("fallback"))
    let result = evalExpr(node, ctx)
    check result.kind == dvString
    check result.strVal == "present"

  test "binary op == equality":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newBinaryOpNode(newIntLitNode(5), "==", newIntLitNode(5))
    let result = evalExpr(node, ctx)
    check result.kind == dvBool
    check result.boolVal == true

  test "binary op != inequality":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newBinaryOpNode(newIntLitNode(5), "!=", newIntLitNode(3))
    let result = evalExpr(node, ctx)
    check result.kind == dvBool
    check result.boolVal == true

  test "binary op + on integers":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newBinaryOpNode(newIntLitNode(3), "+", newIntLitNode(7))
    let result = evalExpr(node, ctx)
    check result.kind == dvInt
    check result.intVal == 10

  test "binary op && (and) short-circuit":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    # false && anything => false (short circuit)
    let node = newBinaryOpNode(newBoolLitNode(false), "&&", newStringLitNode("x"))
    let result = evalExpr(node, ctx)
    check toBool(result) == false

  test "unary op ! negation":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newUnaryOpNode("!", newBoolLitNode(false))
    let result = evalExpr(node, ctx)
    check result.kind == dvBool
    check result.boolVal == true

  test "method call .truncate()":
    var ctx = TemplateContext(
      locals: {"text": newDootString("Hello World, this is a long string")}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newMethodCallNode(
      newIdentifierNode("text"),
      "truncate",
      @[newIntLitNode(11)]
    )
    let result = evalExpr(node, ctx)
    check result.kind == dvString
    check result.strVal == "Hello World..."

  test "method call .truncate() with short string":
    var ctx = TemplateContext(
      locals: {"text": newDootString("Short")}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newMethodCallNode(
      newIdentifierNode("text"),
      "truncate",
      @[newIntLitNode(100)]
    )
    let result = evalExpr(node, ctx)
    check result.kind == dvString
    check result.strVal == "Short"

  test "method call .upcase":
    var ctx = TemplateContext(
      locals: {"text": newDootString("hello")}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newMethodCallNode(newIdentifierNode("text"), "upcase")
    let result = evalExpr(node, ctx)
    check result.kind == dvString
    check result.strVal == "HELLO"

  test "method call .downcase":
    var ctx = TemplateContext(
      locals: {"text": newDootString("HELLO")}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newMethodCallNode(newIdentifierNode("text"), "downcase")
    let result = evalExpr(node, ctx)
    check result.kind == dvString
    check result.strVal == "hello"

  test "method call .length":
    var ctx = TemplateContext(
      locals: {"items": newDootSeq(@[newDootInt(1), newDootInt(2)])}.toTable,
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newMethodCallNode(newIdentifierNode("items"), "length")
    let result = evalExpr(node, ctx)
    check result.kind == dvInt
    check result.intVal == 2

  test "array literal evaluation":
    var ctx = TemplateContext(
      locals: initTable[string, DootValue](),
      viewsDir: "tests/test_views",
      staticDir: "tests/test_static",
      blocks: initTable[string, seq[DootNode]](),
      isLayout: false
    )
    let node = newArrayLitNode(@[newIntLitNode(1), newIntLitNode(2), newIntLitNode(3)])
    let result = evalExpr(node, ctx)
    check result.kind == dvSeq
    check result.seqVal.len == 3
    check result.seqVal[0].intVal == 1

suite "Template Renderer - Element Rendering":
  test "div.post-card renders as <div class=\"post-card\"></div>":
    let source = "div.post-card\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<div class=\"post-card\"></div>" in html

  test "input#email renders as <input id=\"email\">":
    let source = "input#email\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<input id=\"email\">" in html

  test "div.card.highlighted renders with multiple classes":
    let source = "div.card.highlighted\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<div class=\"card highlighted\"></div>" in html

  test "div#sidebar.panel.dark renders with both ID and classes":
    let source = "div#sidebar.panel.dark\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "id=\"sidebar\"" in html
    check "class=\"panel dark\"" in html

  test "a with href attribute and text":
    let source = "a href=\"/posts\" \"All Posts\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<a href=\"/posts\">All Posts</a>" in html

  test "element with both classes and attributes":
    let source = "a.btn.primary href=\"/submit\" \"Go\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "class=\"btn primary\"" in html
    check "href=\"/submit\"" in html
    check "Go</a>" in html

  test "void elements self-close":
    let source = "br\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<br>" in html
    check "</br>" notin html

  test "img with attributes":
    let source = "img src=\"/logo.png\" alt=\"Logo\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<img src=\"/logo.png\" alt=\"Logo\">" in html

  test "nested elements":
    let source = "div\n  p \"Hello\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<div>" in html
    check "<p>Hello</p>" in html
    check "</div>" in html

  test "input with boolean-like attribute (checked)":
    let source = "input type=\"checkbox\" checked=\"\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "checked=\"\"" in html
    check "type=\"checkbox\"" in html

  test "meta void element with attributes":
    let source = "meta charset=\"utf-8\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<meta charset=\"utf-8\">" in html
    check "</meta>" notin html

  test "hr renders as void element":
    let source = "hr\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<hr>" in html
    check "</hr>" notin html

  test "link void element with rel and href":
    let source = "link rel=\"stylesheet\" href=\"/app.css\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<link" in html
    check "rel=\"stylesheet\"" in html
    check "href=\"/app.css\"" in html
    check "</link>" notin html

suite "Template Renderer - Expression Output":
  test "h1= post.title renders escaped":
    let source = "h1= post.title\n"
    var postFields = {"title": newDootString("<script>alert('xss')</script>")}.toTable
    let locals = {"post": newDootObject(postFields)}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "&lt;script&gt;" in html
    check "<script>" notin html

  test "div!= raw_html renders unescaped":
    let source = "div!= raw_html\n"
    let locals = {"raw_html": newDootString("<b>Bold</b>")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<b>Bold</b>" in html

  test "simple text in element":
    let source = "p \"Hello World\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<p>Hello World</p>" in html

  test "escaped output escapes quotes and ampersands":
    let source = "span= content\n"
    let locals = {"content": newDootString("A & B \"quoted\" <tag>")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "&amp;" in html
    check "&quot;" in html
    check "&lt;tag&gt;" in html
    check "<tag>" notin html

  test "raw output bypasses all escaping":
    let source = "div!= raw\n"
    let locals = {"raw": newDootString("<em>A & B \"C\"</em>")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<em>A & B \"C\"</em>" in html

  test "expression output with integer value":
    let source = "span= count\n"
    let locals = {"count": newDootInt(42)}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "42" in html

  test "expression output with nil value renders empty":
    let source = "span= missing\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<span></span>" in html

suite "Template Renderer - Auto-Escaping":
  test "auto-escaping in = output escapes < > & quote single-quote":
    let source = "p= text\n"
    let locals = {"text": newDootString("<b>He said \"hi\" & she said 'bye'</b>")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "&lt;b&gt;" in html
    check "&quot;hi&quot;" in html
    check "&amp;" in html
    check "&#x27;bye&#x27;" in html
    check "<b>" notin html

  test "auto-escaping in interpolation within attributes":
    let source = "a href=\"/search?q=#{query}\" \"Search\"\n"
    let locals = {"query": newDootString("a&b")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    # Interpolation in attributes uses the raw value from eval
    check "a&b" in html or "a&amp;b" in html

  test "!= completely bypasses escaping for HTML content":
    let source = "div!= html_content\n"
    let locals = {"html_content": newDootString("<div class=\"rich\"><p>Hello & <em>World</em></p></div>")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<div class=\"rich\">" in html
    check "<em>World</em>" in html
    check "&lt;" notin html

suite "Template Renderer - String Interpolation":
  test "string interpolation in text":
    let source = "a href=\"/posts/#{post.slug}\" \"View Post\"\n"
    var postFields = {"slug": newDootString("my-post")}.toTable
    let locals = {"post": newDootObject(postFields)}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "/posts/my-post" in html

  test "string interpolation with nested member access":
    let source = "p \"Welcome, #{user.name}\"\n"
    var userFields = {"name": newDootString("Alice")}.toTable
    let locals = {"user": newDootObject(userFields)}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Welcome, Alice" in html

  test "multiple interpolations in single string":
    let source = "p \"#{greeting} #{name}\"\n"
    let locals = {"greeting": newDootString("Hello"), "name": newDootString("World")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Hello World" in html

  test "interpolation with missing variable renders empty":
    let source = "p \"Value: #{missing}\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Value: " in html

suite "Template Renderer - Control Flow":
  test "if condition true renders then branch":
    let source = "if show\n  p \"Visible\"\n"
    let locals = {"show": newDootBool(true)}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<p>Visible</p>" in html

  test "if condition false renders else branch":
    let source = "if show\n  p \"Yes\"\nelse\n  p \"No\"\n"
    let locals = {"show": newDootBool(false)}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<p>No</p>" in html
    check "<p>Yes</p>" notin html

  test "if posts.empty? renders empty state":
    let source = "if posts.empty?\n  p \"No posts yet.\"\nelse\n  p \"Has posts\"\n"
    let locals = {"posts": newDootSeq(@[])}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "No posts yet." in html

  test "if with non-empty collection renders else (not empty)":
    let source = "if posts.empty?\n  p \"Empty\"\nelse\n  p \"Has data\"\n"
    let locals = {"posts": newDootSeq(@[newDootString("item")])}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Has data" in html
    check "Empty" notin html

  test "each loop iterates":
    let source = "each item in items\n  p= item\n"
    let items = newDootSeq(@[newDootString("one"), newDootString("two"), newDootString("three")])
    let locals = {"items": items}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "one" in html
    check "two" in html
    check "three" in html

  test "each loop with object items":
    let source = "each post in posts\n  h2= post.title\n"
    let post1 = newDootObject({"title": newDootString("First")}.toTable)
    let post2 = newDootObject({"title": newDootString("Second")}.toTable)
    let posts = newDootSeq(@[post1, post2])
    let locals = {"posts": posts}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "First" in html
    check "Second" in html

  test "each loop on empty collection renders nothing":
    let source = "each item in items\n  p= item\n"
    let locals = {"items": newDootSeq(@[])}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<p>" notin html

  test "nested control flow - if inside each":
    let source = "each post in posts\n  if post.published\n    h2= post.title\n  else\n    span \"Draft\"\n"
    let published = newDootObject({"title": newDootString("Public"), "published": newDootBool(true)}.toTable)
    let draft = newDootObject({"title": newDootString("Secret"), "published": newDootBool(false)}.toTable)
    let posts = newDootSeq(@[published, draft])
    let locals = {"posts": posts}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Public" in html
    check "Draft" in html
    check "Secret" notin html

  test "if condition with string truthiness":
    let source = "if name\n  p= name\nelse\n  p \"Anonymous\"\n"
    let locals = {"name": newDootString("Alice")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Alice" in html
    check "Anonymous" notin html

  test "if condition with empty string is falsy":
    let source = "if name\n  p= name\nelse\n  p \"Anonymous\"\n"
    let locals = {"name": newDootString("")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Anonymous" in html

suite "Template Renderer - Doctype":
  test "doctype html renders as <!DOCTYPE html>":
    let source = "doctype html\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<!DOCTYPE html>" in html

  test "doctype at start of full page":
    let source = "doctype html\nhtml\n  head\n    title \"Test\"\n  body\n    p \"Content\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check html.startsWith("<!DOCTYPE html>")
    check "<html>" in html
    check "<title>Test</title>" in html
    check "<p>Content</p>" in html

suite "Template Renderer - Style Embed":
  test "style-embed inlines CSS file":
    writeFile("tests/test_static/app.css", "body { color: red; }")
    let source = "style-embed \"app.css\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<style>body { color: red; }</style>" in html

  test "style-embed with missing file":
    let source = "style-embed \"missing.css\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<style>" in html
    check "File not found" in html

  test "style-embed with multi-line CSS":
    writeFile("tests/test_static/multi.css", ".card {\n  padding: 1rem;\n  margin: 0.5rem;\n}")
    let source = "style-embed \"multi.css\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<style>.card {" in html
    check "padding: 1rem;" in html
    check "}</style>" in html

suite "Template Renderer - Inheritance":
  test "extends renders child blocks in layout":
    # Create a layout
    writeFile("tests/test_views/layouts/simple.do", "doctype html\nhtml\n  head\n    title \"Default Title\"\n  body\n    block content\n")
    # Create a child template
    writeFile("tests/test_views/pages/home.do", "extends \"layouts/simple\"\n\nblock content\n  h1 \"Welcome Home\"\n  p \"This is the home page.\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/home", locals, "tests/test_views", "tests/test_static")
    check "<!DOCTYPE html>" in html
    check "<html>" in html
    check "Welcome Home" in html
    check "This is the home page." in html

  test "multiple named blocks resolve correctly":
    writeFile("tests/test_views/layouts/multi.do", "doctype html\nhtml\n  head\n    block head\n  body\n    block content\n    block footer\n")
    writeFile("tests/test_views/pages/multi_child.do", "extends \"layouts/multi\"\n\nblock head\n  title \"Custom Title\"\n\nblock content\n  p \"Main content\"\n\nblock footer\n  p \"Custom footer\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/multi_child", locals, "tests/test_views", "tests/test_static")
    check "Custom Title" in html
    check "Main content" in html
    check "Custom footer" in html

  test "default block value used when child does not override":
    writeFile("tests/test_views/layouts/defaults.do", "doctype html\nhtml\n  head\n    title \"Default App\"\n  body\n    block content\n      p \"No content provided\"\n")
    writeFile("tests/test_views/pages/no_override.do", "extends \"layouts/defaults\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/no_override", locals, "tests/test_views", "tests/test_static")
    check "No content provided" in html

  test "child overrides only one block, others use defaults":
    writeFile("tests/test_views/layouts/partial_override.do", "doctype html\nhtml\n  head\n    block title\n      title \"Default Title\"\n  body\n    block content\n      p \"Default content\"\n    block sidebar\n      aside \"Default sidebar\"\n")
    writeFile("tests/test_views/pages/partial_child.do", "extends \"layouts/partial_override\"\n\nblock content\n  p \"Custom content only\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/partial_child", locals, "tests/test_views", "tests/test_static")
    check "Custom content only" in html
    check "Default Title" in html
    check "Default sidebar" in html

  test "deep inheritance chain (child extends parent extends grandparent)":
    # Grandparent layout
    writeFile("tests/test_views/layouts/grandparent.do", "doctype html\nhtml\n  head\n    block head\n      title \"Grand App\"\n  body\n    block body\n      p \"Grand body\"\n")
    # Parent layout extends grandparent
    writeFile("tests/test_views/layouts/parent.do", "extends \"layouts/grandparent\"\n\nblock body\n  div.container\n    block content\n      p \"Parent default content\"\n")
    # Child extends parent
    writeFile("tests/test_views/pages/deep_child.do", "extends \"layouts/parent\"\n\nblock head\n  title \"Deep Child Title\"\n\nblock content\n  h1 \"Deep child content\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/deep_child", locals, "tests/test_views", "tests/test_static")
    check "<!DOCTYPE html>" in html
    check "Deep Child Title" in html
    check "Deep child content" in html

  test "block override completely replaces parent block content":
    writeFile("tests/test_views/layouts/replace.do", "html\n  body\n    block content\n      p \"Original\"\n      p \"Also original\"\n")
    writeFile("tests/test_views/pages/replace_child.do", "extends \"layouts/replace\"\n\nblock content\n  p \"Replacement\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/replace_child", locals, "tests/test_views", "tests/test_static")
    check "Replacement" in html
    check "Original" notin html
    check "Also original" notin html

  test "layout not found renders error comment":
    writeFile("tests/test_views/pages/bad_extends.do", "extends \"layouts/nonexistent\"\n\nblock content\n  p \"Hello\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/bad_extends", locals, "tests/test_views", "tests/test_static")
    check "layout not found" in html

suite "Template Renderer - Partials":
  test "partial renders with passed locals":
    writeFile("tests/test_views/partials/greeting.do", "p \"Hello\"\nspan= name\n")
    let source = "partial \"partials/greeting\", name: user_name\n"
    let locals = {"user_name": newDootString("Bob")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Hello" in html
    check "Bob" in html

  test "partial with underscore convention":
    writeFile("tests/test_views/comments/_form.do", "form\n  button \"Submit\"\n")
    let source = "partial \"comments/form\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<form>" in html
    check "Submit" in html

  test "partial not found shows comment":
    let source = "partial \"nonexistent/thing\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "partial not found" in html

  test "recursive partials (a partial includes another partial)":
    writeFile("tests/test_views/partials/outer.do", "div.outer\n  partial \"partials/inner\", msg: msg\n")
    writeFile("tests/test_views/partials/inner.do", "span.inner= msg\n")
    let source = "partial \"partials/outer\", msg: greeting\n"
    let locals = {"greeting": newDootString("Hi there")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "class=\"outer\"" in html
    check "class=\"inner\"" in html
    check "Hi there" in html

  test "partial locals isolation - parent scope NOT accessible":
    writeFile("tests/test_views/partials/isolated.do", "p= secret\np= passed\n")
    let source = "partial \"partials/isolated\", passed: visible\n"
    let locals = {"secret": newDootString("HIDDEN"), "visible": newDootString("SHOWN")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    # The partial should see 'passed' but NOT 'secret' from parent scope
    check "SHOWN" in html
    check "HIDDEN" notin html

  test "partial with multiple locals":
    writeFile("tests/test_views/partials/multi_local.do", "p= title\nspan= subtitle\n")
    let source = "partial \"partials/multi_local\", title: t, subtitle: s\n"
    let locals = {"t": newDootString("Main Title"), "s": newDootString("Sub Title")}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "Main Title" in html
    check "Sub Title" in html

suite "Template Renderer - HTMX Injection":
  test "HTMX script injected in head of layout":
    writeFile("tests/test_views/layouts/htmx_layout.do", "doctype html\nhtml\n  head\n    title \"App\"\n  body\n    block content\n")
    writeFile("tests/test_views/pages/htmx_child.do", "extends \"layouts/htmx_layout\"\n\nblock content\n  p \"Content\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/htmx_child", locals, "tests/test_views", "tests/test_static")
    check "/__doot/htmx.min.js" in html
    check "<script" in html

  test "HTMX available without any user configuration":
    # The script tag should be auto-injected in any layout with head
    writeFile("tests/test_views/layouts/auto_htmx.do", "html\n  head\n    title \"Auto\"\n  body\n    block main\n")
    writeFile("tests/test_views/pages/htmx_auto.do", "extends \"layouts/auto_htmx\"\n\nblock main\n  button hx-get=\"/data\" \"Load\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/htmx_auto", locals, "tests/test_views", "tests/test_static")
    check "/__doot/htmx.min.js" in html
    check "hx-get=\"/data\"" in html

suite "Template Renderer - HTMX Attributes":
  test "HTMX attributes render correctly":
    let source = "button hx-post=\"/vote\" hx-target=\"#count\" \"Vote\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "hx-post=\"/vote\"" in html
    check "hx-target=\"#count\"" in html
    check "Vote" in html

  test "HTMX hx-swap attribute":
    let source = "div hx-get=\"/content\" hx-swap=\"outerHTML\" \"Loading...\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "hx-get=\"/content\"" in html
    check "hx-swap=\"outerHTML\"" in html

  test "HTMX hx-trigger attribute":
    let source = "input hx-get=\"/search\" hx-trigger=\"keyup changed delay:500ms\" name=\"q\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "hx-get=\"/search\"" in html
    check "hx-trigger=" in html

suite "Template Renderer - Standalone Template (no extends)":
  test "renders body directly without inheritance":
    let source = "h1 \"Hello\"\np \"World\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<h1>Hello</h1>" in html
    check "<p>World</p>" in html

  test "full standalone page structure":
    let source = "doctype html\nhtml\n  head\n    title \"Standalone\"\n  body\n    h1 \"Page\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<!DOCTYPE html>" in html
    check "<html>" in html
    check "<title>Standalone</title>" in html
    check "<h1>Page</h1>" in html

suite "Template Renderer - Response Integration":
  test "renderResponse with missing template returns stub":
    let resp = renderResponse("nonexistent/template")
    check resp.status == 200
    check "nonexistent/template" in resp.body
    check "Template stub:" in resp.body

  test "renderResponse with Table[string, string] overload":
    var locals = initTable[string, string]()
    locals["key"] = "value"
    let resp = renderResponse("also/missing", locals)
    check resp.status == 200
    check "also/missing" in resp.body

  test "renderResponse produces correct Content-Type header":
    let resp = renderResponse("nonexistent/x")
    check resp.headers["Content-Type"] == "text/html; charset=utf-8"

  test "renderResponse with real template produces full HTML":
    writeFile("tests/test_views/layouts/resp_layout.do", "doctype html\nhtml\n  head\n    title \"Response Test\"\n  body\n    block content\n")
    writeFile("tests/test_views/pages/resp_page.do", "extends \"layouts/resp_layout\"\n\nblock content\n  h1 \"Response Works\"\n")
    let locals = initTable[string, DootValue]()
    let resp = renderResponse("pages/resp_page", locals, "tests/test_views", "tests/test_static")
    check resp.status == 200
    check "<!DOCTYPE html>" in resp.body
    check "Response Works" in resp.body
    check "Response Test" in resp.body

suite "Template Renderer - End-to-End Integration":
  test "full handler render scenario with layout inheritance, escaped content, control flow":
    # Simulate a full handler render:
    # - Layout with head, body, blocks
    # - Child template with each loop, if/else, escaped output
    # - Passed locals (list of posts)
    writeFile("tests/test_views/layouts/blog.do",
      "doctype html\nhtml\n  head\n    title \"Blog\"\n  body\n    block content\n")
    writeFile("tests/test_views/posts/index.do",
      "extends \"layouts/blog\"\n\nblock content\n  h1 \"All Posts\"\n  if posts.empty?\n    p \"No posts yet.\"\n  else\n    each post in posts\n      div.post-card\n        h2= post.title\n        p= post.excerpt\n")

    let post1 = newDootObject({
      "title": newDootString("First <Post>"),
      "excerpt": newDootString("A & B intro")
    }.toTable)
    let post2 = newDootObject({
      "title": newDootString("Second Post"),
      "excerpt": newDootString("More content")
    }.toTable)
    let posts = newDootSeq(@[post1, post2])
    let locals = {"posts": posts}.toTable

    let resp = renderResponse("posts/index", locals, "tests/test_views", "tests/test_static")

    # Verify response basics
    check resp.status == 200
    check resp.headers["Content-Type"] == "text/html; charset=utf-8"

    # Verify layout structure
    check "<!DOCTYPE html>" in resp.body
    check "<html>" in resp.body
    check "<title>Blog</title>" in resp.body

    # Verify content block rendered
    check "All Posts" in resp.body

    # Verify the posts are NOT in empty state
    check "No posts yet." notin resp.body

    # Verify each loop rendered both posts
    check "First &lt;Post&gt;" in resp.body  # Escaped output
    check "A &amp; B intro" in resp.body      # Escaped output
    check "Second Post" in resp.body
    check "More content" in resp.body

    # Verify auto-escaping worked (no raw HTML)
    check "<Post>" notin resp.body

    # Verify element classes
    check "class=\"post-card\"" in resp.body

    # Verify HTMX injection
    check "/__doot/htmx.min.js" in resp.body

  test "end-to-end with empty collection shows empty state":
    writeFile("tests/test_views/posts/empty_index.do",
      "extends \"layouts/blog\"\n\nblock content\n  if posts.empty?\n    div.empty-state\n      p \"No posts yet. Create your first post!\"\n  else\n    each post in posts\n      h2= post.title\n")

    let locals = {"posts": newDootSeq(@[])}.toTable
    let resp = renderResponse("posts/empty_index", locals, "tests/test_views", "tests/test_static")

    check resp.status == 200
    check "No posts yet. Create your first post!" in resp.body
    check "class=\"empty-state\"" in resp.body

  test "end-to-end render with partials and inheritance":
    writeFile("tests/test_views/layouts/with_partial.do",
      "doctype html\nhtml\n  head\n    title \"App\"\n  body\n    block content\n")
    writeFile("tests/test_views/partials/card.do",
      "div.card\n  h3= title\n  p= body\n")
    writeFile("tests/test_views/pages/with_partials.do",
      "extends \"layouts/with_partial\"\n\nblock content\n  h1 \"Cards Page\"\n  partial \"partials/card\", title: card_title, body: card_body\n")

    let locals = {
      "card_title": newDootString("My Card"),
      "card_body": newDootString("Card description here")
    }.toTable
    let resp = renderResponse("pages/with_partials", locals, "tests/test_views", "tests/test_static")

    check resp.status == 200
    check "<!DOCTYPE html>" in resp.body
    check "Cards Page" in resp.body
    check "My Card" in resp.body
    check "Card description here" in resp.body
    check "class=\"card\"" in resp.body

# Cleanup
cleanupTestViews()
