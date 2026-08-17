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

  test "a with href attribute and text":
    let source = "a href=\"/posts\" \"All Posts\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<a href=\"/posts\">All Posts</a>" in html

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

suite "Template Renderer - String Interpolation":
  test "string interpolation in text":
    let source = "a href=\"/posts/#{post.slug}\" \"View Post\"\n"
    var postFields = {"slug": newDootString("my-post")}.toTable
    let locals = {"post": newDootObject(postFields)}.toTable
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "/posts/my-post" in html

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

suite "Template Renderer - Doctype":
  test "doctype html renders as <!DOCTYPE html>":
    let source = "doctype html\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<!DOCTYPE html>" in html

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

suite "Template Renderer - HTMX Injection":
  test "HTMX script injected in head of layout":
    writeFile("tests/test_views/layouts/htmx_layout.do", "doctype html\nhtml\n  head\n    title \"App\"\n  body\n    block content\n")
    writeFile("tests/test_views/pages/htmx_child.do", "extends \"layouts/htmx_layout\"\n\nblock content\n  p \"Content\"\n")
    let locals = initTable[string, DootValue]()
    let html = renderTemplate("pages/htmx_child", locals, "tests/test_views", "tests/test_static")
    check "/__doot/htmx.min.js" in html
    check "<script" in html

suite "Template Renderer - HTMX Attributes":
  test "HTMX attributes render correctly":
    let source = "button hx-post=\"/vote\" hx-target=\"#count\" \"Vote\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "hx-post=\"/vote\"" in html
    check "hx-target=\"#count\"" in html
    check "Vote" in html

suite "Template Renderer - Standalone Template (no extends)":
  test "renders body directly without inheritance":
    let source = "h1 \"Hello\"\np \"World\"\n"
    let locals = initTable[string, DootValue]()
    let html = renderTemplateFromSource(source, locals, "tests/test_views", "tests/test_static")
    check "<h1>Hello</h1>" in html
    check "<p>World</p>" in html

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

# Cleanup
cleanupTestViews()
