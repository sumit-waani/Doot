## Response types and helpers for the Doot HTTP runtime.
## Provides DootResponse type and constructor procs for common response patterns.

import std/[tables]

type
  DootResponse* = object
    status*: int
    headers*: Table[string, string]
    body*: string

proc newResponse*(status: int, body: string,
                  contentType: string = "text/html; charset=utf-8"): DootResponse =
  var headers = initTable[string, string]()
  headers["Content-Type"] = contentType
  DootResponse(status: status, headers: headers, body: body)

proc renderResponse*(templatePath: string,
                     locals: Table[string, string] = initTable[string, string]()): DootResponse =
  ## Stub renderer: returns placeholder HTML mentioning the template path.
  ## Full template engine is Phase 4.
  let html = "<html><body><!-- Template: " & templatePath &
             " --><p>Template stub: " & templatePath & "</p></body></html>"
  newResponse(200, html, "text/html; charset=utf-8")

proc redirectResponse*(path: string): DootResponse =
  ## Return a 302 redirect response with Location header.
  var headers = initTable[string, string]()
  headers["Content-Type"] = "text/html; charset=utf-8"
  headers["Location"] = path
  DootResponse(status: 302, headers: headers, body: "Redirecting to " & path)

proc explicitResponse*(status: int, body: string,
                       contentType: string): DootResponse =
  ## Return a custom response with explicit status, body, and content type.
  newResponse(status, body, contentType)

proc errorResponse*(status: int, message: string): DootResponse =
  ## Return a styled error page HTML response.
  let statusStr = $status
  let title = case status
    of 404: "Not Found"
    of 500: "Internal Server Error"
    of 401: "Unauthorized"
    of 403: "Forbidden"
    else: "Error"
  let html = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>""" & statusStr & " " & title & """</title>
  <style>
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      margin: 0;
      background: #f8f9fa;
      color: #333;
    }
    .error-container {
      text-align: center;
      padding: 2rem;
    }
    .error-code {
      font-size: 6rem;
      font-weight: 700;
      color: #dc3545;
      margin: 0;
      line-height: 1;
    }
    .error-title {
      font-size: 1.5rem;
      font-weight: 600;
      margin: 1rem 0 0.5rem;
    }
    .error-message {
      color: #6c757d;
      font-size: 1rem;
    }
  </style>
</head>
<body>
  <div class="error-container">
    <p class="error-code">""" & statusStr & """</p>
    <p class="error-title">""" & title & """</p>
    <p class="error-message">""" & message & """</p>
  </div>
</body>
</html>"""
  newResponse(status, html, "text/html; charset=utf-8")
