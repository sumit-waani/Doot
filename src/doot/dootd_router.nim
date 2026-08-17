## Host-header based reverse proxy router for the dootd production daemon.
## Routes incoming HTTP requests to the correct child app based on Host header.

import std/[asynchttpserver, asyncdispatch, httpclient, strutils, tables]

type
  ProxyRoute* = object
    hostname*: string
    internalPort*: int
    appId*: int64

  HostRouter* = object
    routes*: seq[ProxyRoute]
    dashboardPort*: int
    routerPort*: int

proc newHostRouter*(routerPort: int = 80, dashboardPort: int = 8080): HostRouter =
  ## Create a new host-based router.
  HostRouter(
    routes: @[],
    dashboardPort: dashboardPort,
    routerPort: routerPort
  )

proc addRoute*(router: var HostRouter, hostname: string, internalPort: int,
               appId: int64) =
  ## Add a route mapping hostname to an internal port.
  ## If a route for this appId already exists, update it.
  for i in 0..<router.routes.len:
    if router.routes[i].appId == appId:
      router.routes[i].hostname = hostname
      router.routes[i].internalPort = internalPort
      return
  router.routes.add(ProxyRoute(
    hostname: hostname,
    internalPort: internalPort,
    appId: appId
  ))

proc removeRoute*(router: var HostRouter, appId: int64) =
  ## Remove a route by app ID.
  var i = 0
  while i < router.routes.len:
    if router.routes[i].appId == appId:
      router.routes.delete(i)
    else:
      inc i

proc findRoute*(router: HostRouter, hostname: string): ptr ProxyRoute =
  ## Find a route matching the given hostname.
  ## Returns nil if no route matches.
  ## The hostname comparison is case-insensitive and strips port if present.
  let cleanHost = hostname.split(':')[0].toLowerAscii().strip()
  for i in 0..<router.routes.len:
    if router.routes[i].hostname.toLowerAscii() == cleanHost:
      return unsafeAddr router.routes[i]
  return nil

proc forwardRequest*(targetPort: int, req: Request): Future[tuple[status: int, body: string, contentType: string]] {.async.} =
  ## Forward an HTTP request to a target port on localhost.
  ## Returns the response status, body, and content type.
  let client = newAsyncHttpClient()
  let url = "http://localhost:" & $targetPort & $req.url
  try:
    let response = await client.request(url, httpMethod = req.reqMethod,
                                         body = req.body)
    let body = await response.body
    let ct = response.headers.getOrDefault("content-type")
    result = (status: response.code.int, body: body, contentType: ct)
  except:
    result = (status: 503, body: "Service Unavailable", contentType: "text/plain")
  finally:
    client.close()

proc startRouter*(router: HostRouter) {.async.} =
  ## Start the async HTTP reverse proxy server.
  ## Routes requests based on Host header to the appropriate internal port.
  ## Returns 404 for unknown hosts and 503 for down apps.
  let httpServer = newAsyncHttpServer()

  proc cb(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      let hostHeader = req.headers.getOrDefault("host")
      let route = findRoute(router, hostHeader)

      if route == nil:
        await req.respond(Http404, "Not Found: No application configured for this host",
                          newHttpHeaders([("Content-Type", "text/plain")]))
        return

      try:
        let (status, body, contentType) = await forwardRequest(route.internalPort, req)
        let headers = newHttpHeaders([("Content-Type", contentType)])
        await req.respond(HttpCode(status), body, headers)
      except:
        await req.respond(Http503, "Service Unavailable",
                          newHttpHeaders([("Content-Type", "text/plain")]))

  httpServer.listen(Port(router.routerPort))
  while true:
    if httpServer.shouldAcceptRequest():
      await httpServer.acceptRequest(cb)
    else:
      await sleepAsync(500)
