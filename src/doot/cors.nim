## CORS enforcement for the Doot HTTP runtime.
## Denied by default (secure by default). Cross-origin requests
## receive a 403 unless explicitly configured to allow specific origins.

import std/[tables, strutils]
import ./response

type
  CorsConfig* = object
    enabled*: bool              # Default: false (deny all)
    allowedOrigins*: seq[string]
    allowedMethods*: seq[string]
    allowedHeaders*: seq[string]
    allowCredentials*: bool
    maxAge*: int                # Preflight cache in seconds

proc defaultCorsConfig*(): CorsConfig =
  ## Default CORS config: deny all cross-origin requests.
  CorsConfig(
    enabled: false,
    allowedOrigins: @[],
    allowedMethods: @["GET", "POST", "PUT", "DELETE", "PATCH"],
    allowedHeaders: @["Content-Type", "Authorization", "X-Requested-With"],
    allowCredentials: false,
    maxAge: 86400
  )

proc newCorsConfig*(origins: seq[string], methods: seq[string] = @[],
                    headers: seq[string] = @[]): CorsConfig =
  ## Create a CORS config that allows specific origins.
  let meths = if methods.len > 0: methods
              else: @["GET", "POST", "PUT", "DELETE", "PATCH"]
  let hdrs = if headers.len > 0: headers
             else: @["Content-Type", "Authorization", "X-Requested-With"]
  CorsConfig(
    enabled: true,
    allowedOrigins: origins,
    allowedMethods: meths,
    allowedHeaders: hdrs,
    allowCredentials: false,
    maxAge: 86400
  )

proc isOriginAllowed*(config: CorsConfig, origin: string): bool =
  ## Check if a given origin is allowed by the CORS config.
  if not config.enabled:
    return false
  if "*" in config.allowedOrigins:
    return true
  for allowed in config.allowedOrigins:
    if allowed.toLowerAscii() == origin.toLowerAscii():
      return true
  return false

proc checkCors*(origin: string, config: CorsConfig): bool =
  ## Returns true if the origin is allowed, false if denied.
  isOriginAllowed(config, origin)

proc corsHeaders*(config: CorsConfig, origin: string): Table[string, string] =
  ## Generate CORS response headers for an allowed origin.
  result = initTable[string, string]()
  if config.enabled and isOriginAllowed(config, origin):
    result["Access-Control-Allow-Origin"] = origin
    result["Access-Control-Allow-Methods"] = config.allowedMethods.join(", ")
    result["Access-Control-Allow-Headers"] = config.allowedHeaders.join(", ")
    if config.allowCredentials:
      result["Access-Control-Allow-Credentials"] = "true"
    result["Access-Control-Max-Age"] = $config.maxAge

proc handleCorsRequest*(origin: string, config: CorsConfig): DootResponse =
  ## Handle a CORS preflight or check.
  ## Returns 403 if denied, or 204 with CORS headers if allowed.
  if origin.len == 0:
    # No Origin header means same-origin request, allow it
    return DootResponse(status: 0, headers: initTable[string, string](), body: "")
  if not checkCors(origin, config):
    return errorResponse(403, "CORS request denied")
  var headers = corsHeaders(config, origin)
  headers["Content-Type"] = "text/plain"
  return DootResponse(status: 204, headers: headers, body: "")

proc corsResponse*(origin: string, config: CorsConfig): DootResponse =
  ## Check CORS for a regular (non-preflight) request.
  ## Returns a 403 response if denied, or a zero-status (pass-through) if allowed.
  if origin.len == 0:
    # No Origin header: not a cross-origin request
    return DootResponse(status: 0, headers: initTable[string, string](), body: "")
  if not checkCors(origin, config):
    return errorResponse(403, "CORS request denied")
  # Allowed: return zero-status to indicate pass-through
  return DootResponse(status: 0, headers: corsHeaders(config, origin), body: "")
