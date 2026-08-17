## Error handling for the Doot HTTP runtime.
## Provides HTTP error exception types, default styled error pages,
## custom error page detection, and auto-404 helpers.

import std/[os]
import ./response
import ./db_types

type
  DootHttpError* = object of CatchableError
    status*: int

  Http404Error* = object of DootHttpError
  Http500Error* = object of DootHttpError

proc newHttp404*(message: string = "The requested resource was not found."): ref Http404Error =
  result = newException(Http404Error, message)
  result.status = 404

proc newHttp500*(message: string = "An internal server error occurred."): ref Http500Error =
  result = newException(Http500Error, message)
  result.status = 500

proc defaultErrorPage*(status: int, message: string): DootResponse =
  ## Generate a styled error page response.
  errorResponse(status, message)

proc checkCustomErrorPage*(viewsDir: string, status: int): string =
  ## Check if a custom error page exists at views/errors/{status}.do.
  ## Returns the file content if it exists, or empty string if not.
  let errorFile = viewsDir / "errors" / ($status & ".do")
  if fileExists(errorFile):
    return readFile(errorFile)
  return ""

proc handleError*(viewsDir: string, status: int, message: string): DootResponse =
  ## Handle an error by checking for custom error pages first,
  ## then falling back to the default styled error page.
  let customContent = checkCustomErrorPage(viewsDir, status)
  if customContent.len > 0:
    # Stub: just wrap the custom content in basic HTML
    let html = "<html><body><!-- Custom error page: " & $status &
               " -->" & customContent & "</body></html>"
    return newResponse(status, html, "text/html; charset=utf-8")
  return defaultErrorPage(status, message)

proc autoFind*(row: Row): Row =
  ## Auto-404 helper: if a database find returns nil, raise Http404.
  ## Use this to wrap db.find results so that nil automatically triggers 404.
  if row == nil:
    raise newHttp404("Record not found")
  return row

proc autoFindOrRaise*(row: Row, message: string = "Record not found"): Row =
  ## Auto-404 with custom message.
  if row == nil:
    raise newHttp404(message)
  return row
