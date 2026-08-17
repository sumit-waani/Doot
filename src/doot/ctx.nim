## Request context object for the Doot HTTP runtime.
## Holds parsed request data: path params, form data, query string,
## headers, file uploads, session, and current user.

import std/[tables, strutils, uri]
import ./db_types

type
  UploadedFile* = object
    filename*: string
    path*: string
    contentType*: string
    size*: int

  DootSession* = ref object
    id*: string
    data*: Table[string, string]
    modified*: bool

  DootCtx* = ref object
    params*: Table[string, string]      # URL path parameters
    form*: Table[string, string]        # POST form data
    query*: Table[string, string]       # Query string parameters
    headers*: Table[string, string]     # Request headers
    file*: Table[string, UploadedFile]  # Uploaded files
    session*: DootSession               # Session data
    currentUser*: Row                   # nil if not authenticated
    requestMethod*: string              # HTTP method
    requestPath*: string                # Request path

proc newSession*(id: string = ""): DootSession =
  DootSession(
    id: id,
    data: initTable[string, string](),
    modified: false
  )

proc get*(session: DootSession, key: string): string =
  if session.data.hasKey(key):
    return session.data[key]
  return ""

proc set*(session: DootSession, key: string, value: string) =
  session.data[key] = value
  session.modified = true

proc delete*(session: DootSession, key: string) =
  if session.data.hasKey(key):
    session.data.del(key)
    session.modified = true

proc newCtx*(): DootCtx =
  DootCtx(
    params: initTable[string, string](),
    form: initTable[string, string](),
    query: initTable[string, string](),
    headers: initTable[string, string](),
    file: initTable[string, UploadedFile](),
    session: newSession(),
    currentUser: nil,
    requestMethod: "GET",
    requestPath: "/"
  )

proc parseQueryString*(qs: string): Table[string, string] =
  ## Parse a query string like "key1=value1&key2=value2" into a table.
  result = initTable[string, string]()
  if qs.len == 0:
    return
  let stripped = if qs[0] == '?': qs[1..^1] else: qs
  for pair in stripped.split('&'):
    if pair.len == 0:
      continue
    let eqIdx = pair.find('=')
    if eqIdx == -1:
      result[decodeUrl(pair)] = ""
    else:
      let key = decodeUrl(pair[0..<eqIdx])
      let value = decodeUrl(pair[eqIdx+1..^1])
      result[key] = value

proc parseFormBody*(body: string): Table[string, string] =
  ## Parse URL-encoded form body (application/x-www-form-urlencoded).
  parseQueryString(body)

proc parseHeaders*(rawHeaders: seq[(string, string)]): Table[string, string] =
  ## Parse header tuples into a table (case-insensitive keys stored lowercase).
  result = initTable[string, string]()
  for (key, value) in rawHeaders:
    result[key.toLowerAscii()] = value

proc populateFromRequest*(ctx: DootCtx, meth: string, path: string,
                          queryStr: string, body: string,
                          rawHeaders: seq[(string, string)],
                          pathParams: Table[string, string]) =
  ## Populate the context from a parsed HTTP request.
  ctx.requestMethod = meth
  ctx.requestPath = path
  ctx.params = pathParams
  ctx.query = parseQueryString(queryStr)
  ctx.headers = parseHeaders(rawHeaders)

  # Parse form body only for POST/PUT/PATCH with form content type
  let contentType = ctx.headers.getOrDefault("content-type", "")
  if meth in ["POST", "PUT", "PATCH"] and
     "application/x-www-form-urlencoded" in contentType:
    ctx.form = parseFormBody(body)

  # NOTE: MULTIPART FORM PARSING IS NOT YET IMPLEMENTED.
  # The `ctx.file` table (Table[string, UploadedFile]) exists in the type
  # definition but is never populated. Requests with Content-Type
  # multipart/form-data will result in an empty `file` table and any
  # form fields within the multipart body will not appear in `ctx.form`.
  # Multipart parsing (file uploads) is planned for Phase 4/5.
