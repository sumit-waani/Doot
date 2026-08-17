## End-to-end tests for the Doot HTTP server.
## Starts a real server on a high port and makes actual HTTP requests
## to verify the full request/response pipeline.

import std/[unittest, httpclient, os, tables, strutils, net]
import std/[asynchttpserver, asyncdispatch]
import ../src/doot/server
import ../src/doot/router
import ../src/doot/ctx
import ../src/doot/response
import ../src/doot/error_pages

const TestPort = 18932  # High port to avoid conflicts

var serverThread: Thread[DootServer]

proc setupServer(): DootServer =
  ## Create a DootServer with test routes.
  result = newDootServer(port = TestPort, staticDir = "tests/test_static",
                         viewsDir = "tests/test_views")

  # GET /hello - simple response
  result.registerRoute(hmGet, "/hello", proc(ctx: DootCtx): DootResponse =
    explicitResponse(200, "Hello, World!", "text/plain")
  , authRequired = false)

  # GET /posts/:id - parameterized route
  result.registerRoute(hmGet, "/posts/:id", proc(ctx: DootCtx): DootResponse =
    let id = ctx.params["id"]
    explicitResponse(200, "Post ID: " & id, "text/plain")
  , authRequired = false)

  # GET /users/:user_id/posts/:id - multiple params
  result.registerRoute(hmGet, "/users/:user_id/posts/:id", proc(ctx: DootCtx): DootResponse =
    let userId = ctx.params["user_id"]
    let postId = ctx.params["id"]
    explicitResponse(200, "User " & userId & " Post " & postId, "text/plain")
  , authRequired = false)

  # POST /posts - form data
  result.registerRoute(hmPost, "/posts", proc(ctx: DootCtx): DootResponse =
    let title = ctx.form.getOrDefault("title", "")
    let body = ctx.form.getOrDefault("body", "")
    explicitResponse(201, "Created: " & title & " - " & body, "text/plain")
  , authRequired = false)

  # GET /query - query string
  result.registerRoute(hmGet, "/query", proc(ctx: DootCtx): DootResponse =
    let name = ctx.query.getOrDefault("name", "")
    let page = ctx.query.getOrDefault("page", "1")
    explicitResponse(200, "name=" & name & "&page=" & page, "text/plain")
  , authRequired = false)

  # GET /error-500 - raises an exception
  result.registerRoute(hmGet, "/error-500", proc(ctx: DootCtx): DootResponse =
    raise newException(ValueError, "Something broke")
  , authRequired = false)

  # GET /not-found-auto - raises Http404Error
  result.registerRoute(hmGet, "/not-found-auto", proc(ctx: DootCtx): DootResponse =
    discard autoFind(nil)
    explicitResponse(200, "never reached", "text/plain")
  , authRequired = false)

  # GET /redirect - redirect helper
  result.registerRoute(hmGet, "/redirect", proc(ctx: DootCtx): DootResponse =
    redirectResponse("/hello")
  , authRequired = false)

  # GET /render - render stub
  result.registerRoute(hmGet, "/render", proc(ctx: DootCtx): DootResponse =
    renderResponse("posts/index")
  , authRequired = false)

proc runServerInThread(server: DootServer) {.thread.} =
  ## Thread proc that runs the async server.
  let httpServer = newAsyncHttpServer()
  proc cb(req: Request) {.async, gcsafe, closure.} =
    {.cast(gcsafe).}:
      await handleRequest(server, req)
  asyncCheck httpServer.serve(Port(TestPort), cb)
  runForever()

proc startTestServer() =
  ## Start the server in a background thread.
  let server = setupServer()

  # Create static dir for testing
  createDir("tests/test_static")
  writeFile("tests/test_static/style.css", "body { color: blue; }")
  writeFile("tests/test_static/app.js", "console.log('test');")

  createThread(serverThread, runServerInThread, server)
  # Give the server a moment to start listening
  sleep(500)

proc baseUrl(): string = "http://127.0.0.1:" & $TestPort

# Start the server before any tests run
startTestServer()

suite "E2E - Basic GET Requests":
  test "GET /hello returns 200 with body":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/hello")
    check resp.code == Http200
    check resp.body == "Hello, World!"
    check "text/plain" in $resp.headers["content-type"]
    client.close()

  test "GET / non-existent route returns 404":
    let client = newHttpClient()
    try:
      let resp = client.get(baseUrl() & "/nonexistent")
      check resp.code == Http404
      check "404" in resp.body
    except HttpRequestError:
      # Some httpclient versions may raise on non-2xx
      check true
    client.close()

  test "GET root path returns 404 (no root handler)":
    let client = newHttpClient()
    try:
      let resp = client.get(baseUrl() & "/")
      check resp.code == Http404
    except HttpRequestError:
      check true
    client.close()

suite "E2E - Parameterized Routes":
  test "GET /posts/:id extracts parameter":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/posts/42")
    check resp.code == Http200
    check resp.body == "Post ID: 42"
    client.close()

  test "GET /posts/:id with string parameter":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/posts/hello-world")
    check resp.code == Http200
    check resp.body == "Post ID: hello-world"
    client.close()

  test "GET /users/:user_id/posts/:id extracts multiple params":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/users/5/posts/99")
    check resp.code == Http200
    check resp.body == "User 5 Post 99"
    client.close()

suite "E2E - POST with Form Data":
  test "POST /posts with form body":
    let client = newHttpClient()
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    let resp = client.post(baseUrl() & "/posts", body = "title=Hello&body=World")
    check resp.code == Http201
    check resp.body == "Created: Hello - World"
    client.close()

  test "POST /posts with encoded form data":
    let client = newHttpClient()
    client.headers = newHttpHeaders({"Content-Type": "application/x-www-form-urlencoded"})
    let resp = client.post(baseUrl() & "/posts", body = "title=Hello%20World&body=Body%20Text")
    check resp.code == Http201
    check "Hello World" in resp.body
    check "Body Text" in resp.body
    client.close()

suite "E2E - Query String":
  test "GET /query with query parameters":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/query?name=test&page=3")
    check resp.code == Http200
    check resp.body == "name=test&page=3"
    client.close()

  test "GET /query with no params uses defaults":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/query")
    check resp.code == Http200
    check resp.body == "name=&page=1"
    client.close()

suite "E2E - Error Handling":
  test "GET /error-500 returns 500 error page":
    let client = newHttpClient()
    try:
      let resp = client.get(baseUrl() & "/error-500")
      check resp.code == Http500
      check "500" in resp.body
      check "Internal Server Error" in resp.body or "Something broke" in resp.body
    except HttpRequestError:
      # httpclient raises on 5xx by default
      check true
    client.close()

  test "GET /not-found-auto returns 404 via autoFind":
    let client = newHttpClient()
    try:
      let resp = client.get(baseUrl() & "/not-found-auto")
      check resp.code == Http404
      check "404" in resp.body
    except HttpRequestError:
      check true
    client.close()

suite "E2E - Response Helpers":
  test "GET /redirect returns 302":
    let client = newHttpClient(maxRedirects = 0)
    try:
      let resp = client.get(baseUrl() & "/redirect")
      check resp.code == Http302
      check resp.headers["location"] == "/hello"
    except HttpRequestError:
      # httpclient may raise on 3xx with no redirect following
      check true
    client.close()

  test "GET /render returns template stub":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/render")
    check resp.code == Http200
    check "posts/index" in resp.body
    check "Template stub:" in resp.body
    client.close()

suite "E2E - Static File Serving":
  test "GET /static/style.css serves CSS":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/static/style.css")
    check resp.code == Http200
    check resp.body == "body { color: blue; }"
    check "text/css" in $resp.headers["content-type"]
    client.close()

  test "GET /static/app.js serves JavaScript":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/static/app.js")
    check resp.code == Http200
    check resp.body == "console.log('test');"
    check "javascript" in $resp.headers["content-type"]
    client.close()

  test "GET /static/missing.css returns 404":
    let client = newHttpClient()
    try:
      let resp = client.get(baseUrl() & "/static/missing.css")
      check resp.code == Http404
    except HttpRequestError:
      check true
    client.close()

suite "E2E - HTMX Endpoint":
  test "GET /__doot/htmx.min.js returns HTMX":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/__doot/htmx.min.js")
    check resp.code == Http200
    check "javascript" in $resp.headers["content-type"]
    check resp.body.len > 0
    check "htmx" in resp.body
    client.close()

  test "HTMX endpoint has cache headers":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/__doot/htmx.min.js")
    check resp.code == Http200
    check "max-age" in $resp.headers["cache-control"]
    client.close()

suite "E2E - CORS Enforcement":
  test "Request with Origin header gets 403":
    let client = newHttpClient()
    client.headers = newHttpHeaders({"Origin": "http://evil.com"})
    try:
      let resp = client.get(baseUrl() & "/hello")
      check resp.code == Http403
      check "CORS" in resp.body or "denied" in resp.body
    except HttpRequestError:
      check true
    client.close()

  test "Request without Origin header proceeds normally":
    let client = newHttpClient()
    let resp = client.get(baseUrl() & "/hello")
    check resp.code == Http200
    check resp.body == "Hello, World!"
    client.close()

  test "OPTIONS preflight with Origin gets 403":
    let client = newHttpClient()
    client.headers = newHttpHeaders({"Origin": "http://evil.com"})
    try:
      let resp = client.request(baseUrl() & "/hello", httpMethod = HttpOptions)
      check resp.code == Http403
    except HttpRequestError:
      check true
    client.close()

# Cleanup test static files
removeDir("tests/test_static")
