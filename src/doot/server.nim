## Main HTTP server module for the Doot runtime.
## Ties together routing, context, static files, HTMX, CORS, sessions,
## authentication enforcement, and error handling using std/asynchttpserver
## + std/asyncdispatch.

import std/[asynchttpserver, asyncdispatch, tables, strutils, uri]
import db_connector/db_sqlite except Row
import ./router
import ./ctx
import ./response
import ./static_files
import ./htmx
import ./error_pages
import ./cors
import ./session
import ./auth
import ./db_types

type
  HandlerProc* = proc(ctx: DootCtx): DootResponse {.gcsafe.}

  RegisteredRoute* = object
    route*: Route
    handler*: HandlerProc

  DootServer* = ref object
    routeTable*: RouteTable
    handlers*: Table[string, HandlerProc]  # handlerName -> proc
    staticDir*: string
    viewsDir*: string
    port*: int
    corsConfig*: CorsConfig
    sessionStore*: SessionStore
    db*: DbConn
    authConfig*: AuthConfig
    authEnabled*: bool

proc newDootServer*(port: int = 3000, staticDir: string = "static",
                    viewsDir: string = "views"): DootServer =
  DootServer(
    routeTable: newRouteTable(),
    handlers: initTable[string, HandlerProc](),
    staticDir: staticDir,
    viewsDir: viewsDir,
    port: port,
    corsConfig: defaultCorsConfig(),
    sessionStore: nil,
    db: nil,
    authConfig: newAuthConfig(),
    authEnabled: false
  )

proc registerRoute*(server: DootServer, httpMethod: DootHttpMethod, pattern: string,
                    handler: HandlerProc, authRequired: bool = true,
                    roleName: string = "") =
  ## Register a route with its handler.
  let handlerName = $httpMethod & ":" & pattern
  server.routeTable.addRoute(httpMethod, pattern, handlerName, authRequired, roleName)
  server.handlers[handlerName] = handler

proc registerAuthRoutes*(server: DootServer, db: DbConn, config: AuthConfig) =
  ## Register built-in auth routes (signup, login, logout) on the server.
  ## These routes are public (no auth required).
  ## Automatically enables auth enforcement on the server.
  server.authEnabled = true
  let store = server.sessionStore
  let authCtx = AuthHandlerContext(db: db, store: store, config: config)

  server.registerRoute(hmPost, "/signup", proc(ctx: DootCtx): DootResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      handleSignup(authCtx, ctx)
  , authRequired = false)

  server.registerRoute(hmPost, "/login", proc(ctx: DootCtx): DootResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      handleLogin(authCtx, ctx)
  , authRequired = false)

  server.registerRoute(hmPost, "/logout", proc(ctx: DootCtx): DootResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      handleLogout(authCtx, ctx)
  , authRequired = false)

proc buildCtx(server: DootServer, req: Request,
              params: Table[string, string]): DootCtx =
  ## Build a DootCtx from an incoming request.
  let ctx = newCtx()
  let parsedUrl = parseUri($req.url)
  let path = parsedUrl.path
  let queryStr = parsedUrl.query

  var rawHeaders: seq[(string, string)] = @[]
  for key, val in req.headers.pairs:
    rawHeaders.add((key, val))

  populateFromRequest(ctx, $req.reqMethod, path, queryStr, req.body,
                      rawHeaders, params)
  return ctx

proc sendResponse(req: Request, resp: DootResponse) {.async.} =
  ## Send a DootResponse back to the client.
  var headers = newHttpHeaders()
  for key, value in resp.headers.pairs:
    headers.add(key, value)
  await req.respond(HttpCode(resp.status), resp.body, headers)

proc handleRequest*(server: DootServer, req: Request) {.async.} =
  ## Main request handler: routes the request through the pipeline.
  let parsedUrl = parseUri($req.url)
  let path = parsedUrl.path
  let httpMethodStr = $req.reqMethod

  # Check for HTMX route
  if path == "/__doot/htmx.min.js":
    let acceptsGzip = "gzip" in req.headers.getOrDefault("accept-encoding")
    let resp = serveHtmx(acceptsGzip)
    await sendResponse(req, resp)
    return

  # Check for static files
  if path.startsWith("/static/"):
    let staticPath = path[7..^1]  # Strip "/static" prefix
    let acceptsGzip = "gzip" in req.headers.getOrDefault("accept-encoding")
    let resp = serveStaticFile(server.staticDir, staticPath, acceptsGzip)
    await sendResponse(req, resp)
    return

  # Check CORS
  let origin = req.headers.getOrDefault("origin")
  if origin.len > 0:
    # Handle OPTIONS preflight
    if httpMethodStr == "OPTIONS":
      let corsResp = handleCorsRequest(origin, server.corsConfig)
      await sendResponse(req, corsResp)
      return
    # Check CORS for regular requests
    let corsCheck = corsResponse(origin, server.corsConfig)
    if corsCheck.status == 403:
      await sendResponse(req, corsCheck)
      return

  # Match route
  let httpMethod = parseHttpMethod(httpMethodStr)
  let routeMatch = server.routeTable.matchRoute(httpMethod, path)

  if not routeMatch.matched:
    let resp = handleError(server.viewsDir, 404, "Page not found")
    await sendResponse(req, resp)
    return

  # Auth enforcement: populate ctx.currentUser and enforce auth/role requirements
  var currentUser: Row = nil
  if server.authEnabled and server.sessionStore != nil and server.db != nil:
    let cookieHeader = req.headers.getOrDefault("cookie")
    let cookieValue = parseCookieHeader(cookieHeader, "doot_session")
    if cookieValue.len > 0:
      currentUser = loadUserFromCookie(server.db, server.sessionStore,
                                       cookieValue, server.authConfig.sessionSecret)

  if server.authEnabled and routeMatch.route.authRequired:
    if currentUser == nil:
      let resp = errorResponse(401, "Authentication required")
      await sendResponse(req, resp)
      return
    if routeMatch.route.roleName.len > 0:
      let userRole = if currentUser != nil: currentUser.getString("role") else: ""
      if userRole != routeMatch.route.roleName:
        let resp = errorResponse(403, "Insufficient permissions")
        await sendResponse(req, resp)
        return

  # Build context and execute handler
  let ctx = buildCtx(server, req, routeMatch.params)
  ctx.currentUser = currentUser
  let handlerName = routeMatch.route.handlerName

  if not server.handlers.hasKey(handlerName):
    let resp = handleError(server.viewsDir, 500, "Handler not found: " & handlerName)
    await sendResponse(req, resp)
    return

  let handler = server.handlers[handlerName]

  try:
    var resp = handler(ctx)
    # Add CORS headers to response if origin is allowed
    if origin.len > 0:
      let corsCheck = corsResponse(origin, server.corsConfig)
      if corsCheck.status == 0:
        for key, value in corsCheck.headers.pairs:
          resp.headers[key] = value
    await sendResponse(req, resp)
  except Http404Error:
    let e = (ref Http404Error)(getCurrentException())
    let resp = handleError(server.viewsDir, 404, e.msg)
    await sendResponse(req, resp)
  except Http500Error:
    let e = (ref Http500Error)(getCurrentException())
    let resp = handleError(server.viewsDir, 500, e.msg)
    await sendResponse(req, resp)
  except CatchableError:
    let e = getCurrentException()
    let resp = handleError(server.viewsDir, 500, "Internal server error: " & e.msg)
    await sendResponse(req, resp)

proc startServer*(server: DootServer) {.async.} =
  ## Start the HTTP server on the configured port.
  let httpServer = newAsyncHttpServer()
  echo "Doot server starting on port " & $server.port
  proc cb(req: Request) {.async, gcsafe.} =
    await handleRequest(server, req)
  httpServer.listen(Port(server.port))
  while true:
    if httpServer.shouldAcceptRequest():
      await httpServer.acceptRequest(cb)
    else:
      await sleepAsync(500)

proc runServer*(server: DootServer) =
  ## Run the server (blocking). Use this as the main entry point.
  waitFor startServer(server)
