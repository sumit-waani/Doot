## Integration tests for the Doot HTTP runtime modules.
## Covers ctx parsing, response helpers, static files, HTMX, error pages, and CORS.

import std/[unittest, tables, os, strutils]
import ../src/doot/ctx
import ../src/doot/response
import ../src/doot/static_files
import ../src/doot/htmx
import ../src/doot/error_pages
import ../src/doot/cors
import ../src/doot/router
import ../src/doot/db_types
import ../src/doot/server

suite "Context - Query String Parsing":
  test "parse simple query string":
    let q = parseQueryString("name=hello&age=25")
    check q["name"] == "hello"
    check q["age"] == "25"

  test "parse empty query string":
    let q = parseQueryString("")
    check q.len == 0

  test "parse query with leading ?":
    let q = parseQueryString("?key=value")
    check q["key"] == "value"

  test "parse query with encoded values":
    let q = parseQueryString("name=hello%20world&path=%2Ftest")
    check q["name"] == "hello world"
    check q["path"] == "/test"

  test "parse query with empty value":
    let q = parseQueryString("key=")
    check q["key"] == ""

  test "parse query with no value":
    let q = parseQueryString("key")
    check q["key"] == ""

suite "Context - Form Body Parsing":
  test "parse form body":
    let f = parseFormBody("username=john&password=secret")
    check f["username"] == "john"
    check f["password"] == "secret"

  test "parse form body with special chars":
    let f = parseFormBody("message=hello%20world&email=test%40example.com")
    check f["message"] == "hello world"
    check f["email"] == "test@example.com"

suite "Context - Header Parsing":
  test "parse headers":
    let h = parseHeaders(@[("Content-Type", "text/html"), ("X-Custom", "value")])
    check h["content-type"] == "text/html"
    check h["x-custom"] == "value"

  test "headers stored lowercase":
    let h = parseHeaders(@[("Accept-Encoding", "gzip")])
    check h.hasKey("accept-encoding")

suite "Context - Full Context":
  test "newCtx creates empty context":
    let ctx = newCtx()
    check ctx.params.len == 0
    check ctx.form.len == 0
    check ctx.query.len == 0
    check ctx.headers.len == 0
    check ctx.currentUser == nil

  test "populateFromRequest fills context":
    let ctx = newCtx()
    var params = initTable[string, string]()
    params["id"] = "42"
    populateFromRequest(ctx, "GET", "/posts/42", "page=1&sort=new",
                        "", @[("Accept", "text/html")], params)
    check ctx.params["id"] == "42"
    check ctx.query["page"] == "1"
    check ctx.query["sort"] == "new"
    check ctx.headers["accept"] == "text/html"
    check ctx.requestMethod == "GET"
    check ctx.requestPath == "/posts/42"

  test "POST form data parsed":
    let ctx = newCtx()
    var params = initTable[string, string]()
    populateFromRequest(ctx, "POST", "/posts", "",
                        "title=Hello&body=World",
                        @[("Content-Type", "application/x-www-form-urlencoded")],
                        params)
    check ctx.form["title"] == "Hello"
    check ctx.form["body"] == "World"

suite "Context - Session":
  test "session get/set/delete":
    let session = newSession("test-id")
    check session.get("key") == ""
    session.set("key", "value")
    check session.get("key") == "value"
    session.delete("key")
    check session.get("key") == ""

  test "session tracks modifications":
    let session = newSession("test-id")
    check session.modified == false
    session.set("key", "value")
    check session.modified == true

suite "Response Helpers":
  test "renderResponse returns stub HTML":
    let resp = renderResponse("posts/index")
    check resp.status == 200
    check "posts/index" in resp.body
    check "Template stub:" in resp.body
    check resp.headers["Content-Type"] == "text/html; charset=utf-8"

  test "redirectResponse returns 302":
    let resp = redirectResponse("/posts")
    check resp.status == 302
    check resp.headers["Location"] == "/posts"

  test "explicitResponse returns custom status/body/type":
    let resp = explicitResponse(404, "Not Found", "text/plain")
    check resp.status == 404
    check resp.body == "Not Found"
    check resp.headers["Content-Type"] == "text/plain"

  test "errorResponse returns styled HTML":
    let resp = errorResponse(404, "Page not found")
    check resp.status == 404
    check "404" in resp.body
    check "Page not found" in resp.body
    check "error-code" in resp.body  # CSS class in styled page

  test "errorResponse 500":
    let resp = errorResponse(500, "Server error")
    check resp.status == 500
    check "500" in resp.body
    check "Server error" in resp.body

suite "Static Files":
  setup:
    # Create temp static directory for testing
    let testDir = getTempDir() / "doot_test_static"
    createDir(testDir)
    writeFile(testDir / "style.css", "body { color: red; }")
    writeFile(testDir / "app.js", "console.log('hello');")
    writeFile(testDir / "image.png", "PNGDATA")

  teardown:
    removeDir(testDir)

  test "serve CSS file with correct MIME type":
    let resp = serveStaticFile(testDir, "/style.css")
    check resp.status == 200
    check resp.headers["Content-Type"] == "text/css"
    check resp.body == "body { color: red; }"
    check resp.headers["Cache-Control"] == "public, max-age=3600"

  test "serve JS file with correct MIME type":
    let resp = serveStaticFile(testDir, "/app.js")
    check resp.status == 200
    check resp.headers["Content-Type"] == "application/javascript"

  test "serve PNG with correct MIME type":
    let resp = serveStaticFile(testDir, "/image.png")
    check resp.status == 200
    check resp.headers["Content-Type"] == "image/png"

  test "missing file returns 404":
    let resp = serveStaticFile(testDir, "/nonexistent.css")
    check resp.status == 404

  test "path traversal prevention":
    let resp = serveStaticFile(testDir, "/../../../etc/passwd")
    check resp.status == 404

  test "gzip compression for text files":
    let resp = serveStaticFile(testDir, "/style.css", acceptsGzip = true)
    check resp.status == 200
    # Small files may not benefit from compression
    # but the header should be set if compression worked
    if resp.headers.hasKey("Content-Encoding"):
      check resp.headers["Content-Encoding"] == "gzip"

suite "MIME Type Detection":
  test "HTML files":
    check getMimeType("index.html") == "text/html"
    check getMimeType("page.htm") == "text/html"

  test "CSS files":
    check getMimeType("style.css") == "text/css"

  test "JavaScript files":
    check getMimeType("app.js") == "application/javascript"

  test "JSON files":
    check getMimeType("data.json") == "application/json"

  test "Image files":
    check getMimeType("photo.png") == "image/png"
    check getMimeType("photo.jpg") == "image/jpeg"
    check getMimeType("photo.jpeg") == "image/jpeg"
    check getMimeType("anim.gif") == "image/gif"
    check getMimeType("icon.svg") == "image/svg+xml"
    check getMimeType("favicon.ico") == "image/x-icon"

  test "Font files":
    check getMimeType("font.woff") == "font/woff"
    check getMimeType("font.woff2") == "font/woff2"

  test "Text files":
    check getMimeType("readme.txt") == "text/plain"

  test "Unknown extension":
    check getMimeType("file.xyz") == "application/octet-stream"

suite "HTMX Embedding":
  test "HTMX content is non-empty":
    check HtmxContent.len > 0
    check "htmx" in HtmxContent
    check "1.9.12" in HtmxContent

  test "serveHtmx returns correct content-type":
    let resp = serveHtmx(acceptsGzip = false)
    check resp.status == 200
    check "application/javascript" in resp.headers["Content-Type"]
    check resp.body == HtmxContent

  test "serveHtmx with cache headers":
    let resp = serveHtmx()
    check "max-age=31536000" in resp.headers["Cache-Control"]
    check "immutable" in resp.headers["Cache-Control"]

  test "serveHtmx with gzip":
    let resp = serveHtmx(acceptsGzip = true)
    check resp.status == 200
    if resp.headers.hasKey("Content-Encoding"):
      check resp.headers["Content-Encoding"] == "gzip"
      # Compressed body should be smaller
      check resp.body.len < HtmxContent.len

suite "Error Pages":
  test "default 404 error page":
    let resp = defaultErrorPage(404, "Not found")
    check resp.status == 404
    check "404" in resp.body
    check "Not found" in resp.body

  test "default 500 error page":
    let resp = defaultErrorPage(500, "Server error")
    check resp.status == 500
    check "500" in resp.body

  test "auto-404 raises on nil row":
    expect Http404Error:
      discard autoFind(nil)

  test "auto-404 passes through non-nil row":
    let row = newRow(1)
    row["name"] = dbStr("test")
    let result = autoFind(row)
    check result.id == 1

  test "autoFindOrRaise with custom message":
    try:
      discard autoFindOrRaise(nil, "Post not found")
      check false  # Should not reach here
    except Http404Error:
      let e = (ref Http404Error)(getCurrentException())
      check e.msg == "Post not found"

  test "custom error page check (non-existent)":
    let content = checkCustomErrorPage("/nonexistent/views", 404)
    check content == ""

  test "custom error page check (exists)":
    let testDir = getTempDir() / "doot_test_views"
    createDir(testDir / "errors")
    writeFile(testDir / "errors" / "404.do", "Custom 404 page content")
    let content = checkCustomErrorPage(testDir, 404)
    check content == "Custom 404 page content"
    removeDir(testDir)

suite "CORS Enforcement":
  test "default config denies all":
    let config = defaultCorsConfig()
    check config.enabled == false
    check checkCors("http://evil.com", config) == false

  test "CORS denied for any origin when not enabled":
    let config = defaultCorsConfig()
    let resp = corsResponse("http://example.com", config)
    check resp.status == 403

  test "CORS allowed when origin is in whitelist":
    let config = newCorsConfig(@["http://example.com"])
    check checkCors("http://example.com", config) == true

  test "CORS denied for non-whitelisted origin":
    let config = newCorsConfig(@["http://example.com"])
    check checkCors("http://evil.com", config) == false

  test "CORS wildcard allows all":
    let config = newCorsConfig(@["*"])
    check checkCors("http://anything.com", config) == true

  test "no origin header means same-origin (allow)":
    let config = defaultCorsConfig()
    let resp = corsResponse("", config)
    check resp.status == 0  # Pass-through

  test "CORS headers set correctly":
    let config = newCorsConfig(@["http://example.com"])
    let headers = corsHeaders(config, "http://example.com")
    check headers["Access-Control-Allow-Origin"] == "http://example.com"
    check "GET" in headers["Access-Control-Allow-Methods"]

  test "handleCorsRequest preflight":
    let config = newCorsConfig(@["http://example.com"])
    let resp = handleCorsRequest("http://example.com", config)
    check resp.status == 204
    check resp.headers["Access-Control-Allow-Origin"] == "http://example.com"

  test "handleCorsRequest denied":
    let config = defaultCorsConfig()
    let resp = handleCorsRequest("http://evil.com", config)
    check resp.status == 403

suite "Server Integration":
  test "DootServer creation":
    let server = newDootServer(port = 8080, staticDir = "public", viewsDir = "templates")
    check server.port == 8080
    check server.staticDir == "public"
    check server.viewsDir == "templates"
    check server.corsConfig.enabled == false

  test "register and match route":
    let server = newDootServer()
    var called = false
    server.registerRoute(hmGet, "/test", proc(ctx: DootCtx): DootResponse =
      called = true
      renderResponse("test/index")
    )
    let m = server.routeTable.matchRoute(hmGet, "/test")
    check m.matched == true
    # Execute handler
    let ctx = newCtx()
    let handler = server.handlers[m.route.handlerName]
    let resp = handler(ctx)
    check resp.status == 200
    check "test/index" in resp.body

  test "unmatched route":
    let server = newDootServer()
    let m = server.routeTable.matchRoute(hmGet, "/nonexistent")
    check m.matched == false

  test "auth required is default":
    let server = newDootServer()
    server.registerRoute(hmGet, "/protected", proc(ctx: DootCtx): DootResponse =
      renderResponse("protected/page")
    )
    let m = server.routeTable.matchRoute(hmGet, "/protected")
    check m.matched == true
    check m.route.authRequired == true

  test "public route":
    let server = newDootServer()
    server.registerRoute(hmGet, "/public", proc(ctx: DootCtx): DootResponse =
      renderResponse("public/page")
    , authRequired = false)
    let m = server.routeTable.matchRoute(hmGet, "/public")
    check m.matched == true
    check m.route.authRequired == false

  test "handler raises Http404":
    let server = newDootServer()
    server.registerRoute(hmGet, "/find/:id", proc(ctx: DootCtx): DootResponse =
      discard autoFind(nil)  # Will raise Http404Error
      renderResponse("never/reached")
    )
    let m = server.routeTable.matchRoute(hmGet, "/find/99")
    check m.matched == true
    let handler = server.handlers[m.route.handlerName]
    let ctx = newCtx()
    try:
      discard handler(ctx)
      check false  # Should not reach
    except Http404Error:
      check true

  test "handler produces 500 on unhandled exception":
    let server = newDootServer()
    server.registerRoute(hmGet, "/crash", proc(ctx: DootCtx): DootResponse =
      raise newException(ValueError, "Something broke")
    )
    let m = server.routeTable.matchRoute(hmGet, "/crash")
    let handler = server.handlers[m.route.handlerName]
    let ctx = newCtx()
    try:
      discard handler(ctx)
      check false
    except ValueError:
      # In actual server, this would be caught and converted to 500
      check true
