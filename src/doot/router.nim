## Route matching engine for the Doot HTTP runtime.
## Handles route registration, path parameter extraction, and dispatch.
## Routes are ordered: static before parameterized, more segments before fewer.

import std/[strutils, tables, algorithm]

type
  DootHttpMethod* = enum
    hmGet = "GET"
    hmPost = "POST"
    hmPut = "PUT"
    hmDelete = "DELETE"
    hmPatch = "PATCH"

  RouteHandler* = proc(params: Table[string, string]): pointer {.gcsafe.}

  Route* = object
    httpMethod*: DootHttpMethod
    pattern*: string            # Original path pattern e.g. "/posts/:id"
    segments*: seq[string]      # Split segments e.g. @["posts", ":id"]
    paramNames*: seq[string]    # Parameter names e.g. @["id"]
    isStatic*: bool             # True if no :param segments
    authRequired*: bool         # True if route requires authentication
    roleName*: string           # Required role or ""
    handlerName*: string        # Handler identifier for dispatch

  RouteMatch* = object
    matched*: bool
    route*: Route
    params*: Table[string, string]

  RouteTable* = object
    routes*: seq[Route]

proc parseHttpMethod*(s: string): DootHttpMethod =
  case s.toUpperAscii()
  of "GET": hmGet
  of "POST": hmPost
  of "PUT": hmPut
  of "DELETE": hmDelete
  of "PATCH": hmPatch
  else: hmGet

proc splitPath*(path: string): seq[string] =
  ## Split a path into segments, stripping leading/trailing slashes.
  let trimmed = path.strip(chars = {'/'})
  if trimmed.len == 0:
    return @[]
  result = trimmed.split('/')

proc newRoute*(httpMethod: DootHttpMethod, pattern: string, handlerName: string = "",
               authRequired: bool = true, roleName: string = ""): Route =
  let segments = splitPath(pattern)
  var paramNames: seq[string] = @[]
  var isStatic = true
  for seg in segments:
    if seg.len > 0 and seg[0] == ':':
      paramNames.add(seg[1..^1])
      isStatic = false
  Route(
    httpMethod: httpMethod,
    pattern: pattern,
    segments: segments,
    paramNames: paramNames,
    isStatic: isStatic,
    authRequired: authRequired,
    roleName: roleName,
    handlerName: handlerName
  )

proc newRouteTable*(): RouteTable =
  RouteTable(routes: @[])

proc routeScore(route: Route): int =
  ## Higher score = higher priority.
  ## Static routes score higher, more segments score higher.
  result = route.segments.len * 10
  if route.isStatic:
    result += 1000
  # Count static segments (non-param segments add priority)
  for seg in route.segments:
    if seg.len == 0 or seg[0] != ':':
      result += 5

proc addRoute*(table: var RouteTable, route: Route) =
  ## Add a route to the table and maintain ordering.
  ## Static routes come before parameterized ones.
  ## More segments before fewer.
  table.routes.add(route)
  table.routes.sort(proc(a, b: Route): int =
    cmp(routeScore(b), routeScore(a))
  )

proc addRoute*(table: var RouteTable, httpMethod: DootHttpMethod, pattern: string,
               handlerName: string = "", authRequired: bool = true,
               roleName: string = "") =
  let route = newRoute(httpMethod, pattern, handlerName, authRequired, roleName)
  table.addRoute(route)

proc matchRoute*(table: RouteTable, httpMethod: DootHttpMethod,
                 path: string): RouteMatch =
  ## Match a request path against the route table.
  ## Returns the first matching route with extracted parameters.
  let requestSegments = splitPath(path)

  for route in table.routes:
    if route.httpMethod != httpMethod:
      continue
    if route.segments.len != requestSegments.len:
      continue

    var matched = true
    var params = initTable[string, string]()
    for i in 0..<route.segments.len:
      let routeSeg = route.segments[i]
      let reqSeg = requestSegments[i]
      if routeSeg.len > 0 and routeSeg[0] == ':':
        # Parameter segment - capture value
        params[routeSeg[1..^1]] = reqSeg
      elif routeSeg != reqSeg:
        matched = false
        break

    if matched:
      return RouteMatch(matched: true, route: route, params: params)

  return RouteMatch(matched: false, route: Route(), params: initTable[string, string]())

proc matchRoute*(table: RouteTable, httpMethodStr: string,
                 path: string): RouteMatch =
  let meth = parseHttpMethod(httpMethodStr)
  matchRoute(table, meth, path)
