## Gzip compression using system zlib.
## Provides a simple gzipCompress proc for compressing string content.

{.passl: "-lz".}

const
  Z_OK = 0.cint
  Z_STREAM_END = 1.cint
  Z_FINISH = 4.cint
  Z_DEFAULT_COMPRESSION = -1.cint
  MAX_WBITS = 15.cint
  GZIP_ENCODING = 16.cint  # Add to windowBits for gzip format

type
  ZStream {.importc: "z_stream", header: "<zlib.h>".} = object
    next_in {.importc: "next_in".}: ptr uint8
    avail_in {.importc: "avail_in".}: cuint
    total_in {.importc: "total_in".}: culong
    next_out {.importc: "next_out".}: ptr uint8
    avail_out {.importc: "avail_out".}: cuint
    total_out {.importc: "total_out".}: culong
    msg {.importc: "msg".}: cstring
    state {.importc: "state".}: pointer
    zalloc {.importc: "zalloc".}: pointer
    zfree {.importc: "zfree".}: pointer
    opaque {.importc: "opaque".}: pointer
    data_type {.importc: "data_type".}: cint
    adler {.importc: "adler".}: culong
    reserved {.importc: "reserved".}: culong

proc deflateInit2(strm: ptr ZStream, level: cint, meth: cint,
                  windowBits: cint, memLevel: cint,
                  strategy: cint): cint {.importc: "deflateInit2_",
                  header: "<zlib.h>", cdecl.}

# We need to use the actual deflateInit2_ which takes version and stream size
proc deflateInit2Wrapper(strm: ptr ZStream, level: cint,
                         windowBits: cint): cint {.inline.} =
  proc deflateInit2Raw(strm: ptr ZStream, level: cint, meth: cint,
                       windowBits: cint, memLevel: cint, strategy: cint,
                       version: cstring, streamSize: cint): cint
                       {.importc: "deflateInit2_", header: "<zlib.h>", cdecl.}
  proc zlibVersion(): cstring {.importc: "zlibVersion", header: "<zlib.h>", cdecl.}
  deflateInit2Raw(strm, level, 8.cint, windowBits, 8.cint, 0.cint,
                  zlibVersion(), cint(sizeof(ZStream)))

proc deflate(strm: ptr ZStream, flush: cint): cint
             {.importc: "deflate", header: "<zlib.h>", cdecl.}

proc deflateEnd(strm: ptr ZStream): cint
               {.importc: "deflateEnd", header: "<zlib.h>", cdecl.}

proc gzipCompress*(input: string): string =
  ## Compress a string using gzip format.
  ## Returns empty string on failure.
  if input.len == 0:
    return ""

  var stream: ZStream
  stream.zalloc = nil
  stream.zfree = nil
  stream.opaque = nil

  let ret = deflateInit2Wrapper(addr stream, Z_DEFAULT_COMPRESSION,
                                 MAX_WBITS + GZIP_ENCODING)
  if ret != Z_OK:
    return ""

  # Allocate output buffer (worst case: slightly larger than input)
  let maxOutLen = input.len + input.len div 10 + 128
  var output = newString(maxOutLen)

  stream.next_in = cast[ptr uint8](unsafeAddr input[0])
  stream.avail_in = cuint(input.len)
  stream.next_out = cast[ptr uint8](addr output[0])
  stream.avail_out = cuint(maxOutLen)

  let deflateRet = deflate(addr stream, Z_FINISH)
  if deflateRet != Z_STREAM_END:
    discard deflateEnd(addr stream)
    return ""

  let compressedLen = int(stream.total_out)
  discard deflateEnd(addr stream)

  output.setLen(compressedLen)
  return output
