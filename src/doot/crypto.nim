## Cryptographic primitives for Doot authentication.
## Provides HMAC-SHA256 cookie signing via OpenSSL C FFI
## and argon2id password hashing via libargon2 C FFI.

import std/[strutils, sysrand]

# =============================================================================
# OpenSSL HMAC-SHA256 C FFI bindings
# =============================================================================

type
  EVP_MD {.importc: "EVP_MD", header: "openssl/evp.h", incompletestruct.} = object

proc EVP_sha256(): ptr EVP_MD {.importc: "EVP_sha256", header: "openssl/evp.h".}

proc HMAC(evp_md: ptr EVP_MD, key: pointer, key_len: cint,
           data: pointer, data_len: csize_t,
           md: pointer, md_len: ptr cuint): pointer {.
  importc: "HMAC", header: "openssl/hmac.h".}

# =============================================================================
# libargon2 C FFI bindings
# =============================================================================

const
  ARGON2_OK = 0.cint
  Argon2_id = 2.cint

proc argon2id_hash_encoded(t_cost: uint32, m_cost: uint32,
                           parallelism: uint32,
                           pwd: pointer, pwdlen: csize_t,
                           salt: pointer, saltlen: csize_t,
                           hashlen: csize_t, encoded: cstring,
                           encodedlen: csize_t): cint {.
  importc: "argon2id_hash_encoded", header: "argon2.h".}

proc argon2id_verify(encoded: cstring, pwd: pointer,
                     pwdlen: csize_t): cint {.
  importc: "argon2id_verify", header: "argon2.h".}

proc argon2_encodedlen(t_cost: uint32, m_cost: uint32,
                       parallelism: uint32, saltlen: uint32,
                       hashlen: uint32, argon2type: cint): csize_t {.
  importc: "argon2_encodedlen", header: "argon2.h".}

# =============================================================================
# HMAC-SHA256 signing
# =============================================================================

proc hmacSign*(key: string, data: string): string =
  ## Produce a hex-encoded HMAC-SHA256 signature of data using key.
  var md: array[32, uint8]  # SHA-256 produces 32 bytes
  var md_len: cuint = 32

  let keyPtr = if key.len > 0: unsafeAddr key[0] else: nil
  let dataPtr = if data.len > 0: unsafeAddr data[0] else: nil

  let res = HMAC(EVP_sha256(), keyPtr, key.len.cint,
                 dataPtr, data.len.csize_t,
                 addr md[0], addr md_len)
  if res == nil:
    raise newException(CatchableError, "HMAC computation failed")

  result = ""
  for i in 0 ..< md_len.int:
    result.add(toHex(md[i], 2).toLowerAscii())

proc timingSafeEqual*(a, b: string): bool =
  ## Timing-safe comparison of two strings.
  ## Always compares all bytes regardless of where differences occur,
  ## preventing timing side-channel attacks.
  if a.len != b.len:
    return false
  var diff: uint8 = 0
  for i in 0 ..< a.len:
    diff = diff or (a[i].uint8 xor b[i].uint8)
  result = diff == 0

proc hmacVerify*(key: string, data: string, signature: string): bool =
  ## Verify an HMAC-SHA256 signature using timing-safe comparison.
  ## Returns true if the signature matches, false otherwise.
  let computed = hmacSign(key, data)
  result = timingSafeEqual(computed, signature)

# =============================================================================
# Argon2id password hashing
# =============================================================================

const
  DefaultTimeCost: uint32 = 3
  DefaultMemoryCost: uint32 = 65536  # 64 MB
  DefaultParallelism: uint32 = 4
  DefaultHashLen: uint32 = 32
  DefaultSaltLen = 16

proc hashPassword*(password: string): string =
  ## Hash a password using argon2id with secure defaults.
  ## Returns the encoded hash string (starts with '$argon2id$').
  ## Parameters: t_cost=3, m_cost=64MB, parallelism=4, hash_len=32.
  var salt: array[DefaultSaltLen, byte]
  if not urandom(salt):
    raise newException(OSError, "Failed to read from system random source")

  let encodedLen = argon2_encodedlen(
    DefaultTimeCost, DefaultMemoryCost, DefaultParallelism,
    DefaultSaltLen.uint32, DefaultHashLen, Argon2_id
  )

  var encoded = newString(encodedLen)

  let pwdPtr = if password.len > 0: unsafeAddr password[0] else: nil

  let rc = argon2id_hash_encoded(
    DefaultTimeCost, DefaultMemoryCost, DefaultParallelism,
    pwdPtr, password.len.csize_t,
    addr salt[0], DefaultSaltLen.csize_t,
    DefaultHashLen.csize_t,
    encoded.cstring, encodedLen
  )

  if rc != ARGON2_OK:
    raise newException(CatchableError, "argon2id_hash_encoded failed with code " & $rc)

  # Trim trailing null bytes
  let nullPos = encoded.find('\0')
  if nullPos >= 0:
    result = encoded[0 ..< nullPos]
  else:
    result = encoded

proc verifyPassword*(password: string, encodedHash: string): bool =
  ## Verify a password against an argon2id encoded hash.
  ## argon2id_verify is internally timing-safe.
  ## Returns true if the password matches, false otherwise.
  let pwdPtr = if password.len > 0: unsafeAddr password[0] else: nil
  let rc = argon2id_verify(
    encodedHash.cstring,
    pwdPtr, password.len.csize_t
  )
  result = rc == ARGON2_OK

# =============================================================================
# Cookie signing/verification
# =============================================================================

proc signSessionCookie*(sessionId: string, secret: string): string =
  ## Sign a session ID with HMAC-SHA256, returning 'sessionId.signature' format.
  let signature = hmacSign(secret, sessionId)
  result = sessionId & "." & signature

proc verifySessionCookie*(cookie: string, secret: string): string =
  ## Verify a signed session cookie and return the session ID.
  ## Returns empty string if the cookie is invalid or tampered.
  let dotPos = cookie.rfind('.')
  if dotPos < 0 or dotPos == 0 or dotPos == cookie.len - 1:
    return ""

  let sessionId = cookie[0 ..< dotPos]
  let signature = cookie[dotPos + 1 .. ^1]

  if hmacVerify(secret, sessionId, signature):
    result = sessionId
  else:
    result = ""
