## Static file serving for the Doot HTTP runtime.
## Serves files from a given directory with MIME type detection,
## gzip compression, and cache headers.

import std/[tables, os, strutils]
import ./response
import ./gzip

proc getMimeType*(filename: string): string =
  ## Get MIME type for a file based on its extension.
  let ext = filename.splitFile().ext.toLowerAscii()
  case ext
  of ".html", ".htm": return "text/html"
  of ".css": return "text/css"
  of ".js": return "application/javascript"
  of ".json": return "application/json"
  of ".xml": return "application/xml"
  of ".png": return "image/png"
  of ".jpg", ".jpeg": return "image/jpeg"
  of ".gif": return "image/gif"
  of ".svg": return "image/svg+xml"
  of ".ico": return "image/x-icon"
  of ".woff": return "font/woff"
  of ".woff2": return "font/woff2"
  of ".ttf": return "font/ttf"
  of ".otf": return "font/otf"
  of ".txt": return "text/plain"
  of ".pdf": return "application/pdf"
  of ".webp": return "image/webp"
  of ".mp4": return "video/mp4"
  of ".webm": return "video/webm"
  else: return "application/octet-stream"

proc isCompressible*(mimeType: string): bool =
  ## Check if a MIME type should be gzip compressed.
  mimeType.startsWith("text/") or
    mimeType == "application/javascript" or
    mimeType == "application/json" or
    mimeType == "application/xml" or
    mimeType == "image/svg+xml"

proc serveStaticFile*(basePath: string, requestPath: string,
                      acceptsGzip: bool = false): DootResponse =
  ## Serve a static file from basePath, using requestPath to locate it.
  ## Returns a DootResponse with proper content-type and cache headers.
  ## Returns a 404 response if file not found.

  # Security: prevent path traversal by resolving the absolute path
  # and verifying it remains within the static root directory.
  let staticRoot = absolutePath(basePath)
  let candidate = absolutePath(basePath / requestPath.strip(chars = {'/'}))
  # Normalize both paths to remove any .. segments via absolutePath,
  # then verify the resolved candidate starts with the static root.
  if not candidate.startsWith(staticRoot):
    return errorResponse(404, "File not found")
  let filePath = candidate

  if not fileExists(filePath):
    return errorResponse(404, "File not found")

  let content = readFile(filePath)
  let mimeType = getMimeType(filePath)

  var headers = initTable[string, string]()
  headers["Content-Type"] = mimeType
  headers["Cache-Control"] = "public, max-age=3600"

  # Apply gzip for compressible types if client accepts
  if acceptsGzip and isCompressible(mimeType):
    let compressed = gzipCompress(content)
    if compressed.len > 0 and compressed.len < content.len:
      headers["Content-Encoding"] = "gzip"
      return DootResponse(status: 200, headers: headers, body: compressed)

  return DootResponse(status: 200, headers: headers, body: content)
