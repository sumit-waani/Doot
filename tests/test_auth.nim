## Tests for Doot crypto primitives.
## Covers HMAC-SHA256 signing, argon2id password hashing, and cookie signing.

import std/[unittest, strutils]
import ../src/doot/crypto

suite "HMAC-SHA256 Signing":
  test "hmacSign produces consistent output for same key and data":
    let key = "my-secret-key"
    let data = "hello-world"
    let sig1 = hmacSign(key, data)
    let sig2 = hmacSign(key, data)
    check sig1 == sig2
    check sig1.len == 64  # SHA-256 produces 32 bytes = 64 hex chars

  test "hmacSign produces hex-encoded output":
    let sig = hmacSign("key", "data")
    for c in sig:
      check c in {'0'..'9', 'a'..'f'}

  test "hmacSign with different keys produces different signatures":
    let sig1 = hmacSign("key1", "data")
    let sig2 = hmacSign("key2", "data")
    check sig1 != sig2

  test "hmacSign with different data produces different signatures":
    let sig1 = hmacSign("key", "data1")
    let sig2 = hmacSign("key", "data2")
    check sig1 != sig2

  test "hmacSign with empty key still works":
    let sig = hmacSign("", "data")
    check sig.len == 64

  test "hmacSign with empty data still works":
    let sig = hmacSign("key", "")
    check sig.len == 64

suite "HMAC-SHA256 Verification":
  test "hmacVerify returns true for valid signature":
    let key = "secret"
    let data = "message"
    let sig = hmacSign(key, data)
    check hmacVerify(key, data, sig) == true

  test "hmacVerify returns false for tampered data":
    let key = "secret"
    let sig = hmacSign(key, "original")
    check hmacVerify(key, "tampered", sig) == false

  test "hmacVerify returns false for tampered signature":
    let key = "secret"
    let data = "message"
    let sig = hmacSign(key, data)
    let tampered = "a" & sig[1..^1]  # Change first char
    check hmacVerify(key, data, tampered) == false

  test "hmacVerify returns false for wrong key":
    let sig = hmacSign("key1", "data")
    check hmacVerify("key2", "data", sig) == false

  test "hmacVerify returns false for empty signature":
    check hmacVerify("key", "data", "") == false

  test "hmacVerify returns false for signature of wrong length":
    check hmacVerify("key", "data", "abc123") == false

suite "Timing-Safe Comparison":
  test "timingSafeEqual returns true for equal strings":
    check timingSafeEqual("hello", "hello") == true

  test "timingSafeEqual returns false for different strings":
    check timingSafeEqual("hello", "world") == false

  test "timingSafeEqual returns false for different lengths":
    check timingSafeEqual("short", "longer-string") == false

  test "timingSafeEqual returns true for empty strings":
    check timingSafeEqual("", "") == true

  test "timingSafeEqual returns false for empty vs non-empty":
    check timingSafeEqual("", "x") == false

suite "Argon2id Password Hashing":
  test "hashPassword produces argon2id encoded format":
    let hash = hashPassword("mypassword123")
    check hash.startsWith("$argon2id$")

  test "hashPassword produces different hashes for same password (random salt)":
    let hash1 = hashPassword("samepassword")
    let hash2 = hashPassword("samepassword")
    check hash1 != hash2  # Different salts

  test "hashPassword never stores plaintext":
    let password = "super-secret-password"
    let hash = hashPassword(password)
    check password notin hash

  test "hashPassword contains version info":
    let hash = hashPassword("test")
    check "v=19" in hash  # Argon2 version 0x13 = 19

  test "hashPassword with empty password works":
    let hash = hashPassword("")
    check hash.startsWith("$argon2id$")

suite "Argon2id Password Verification":
  test "verifyPassword returns true for correct password":
    let password = "correct-horse-battery-staple"
    let hash = hashPassword(password)
    check verifyPassword(password, hash) == true

  test "verifyPassword returns false for wrong password":
    let hash = hashPassword("original-password")
    check verifyPassword("wrong-password", hash) == false

  test "verifyPassword returns false for empty password when hash is non-empty":
    let hash = hashPassword("some-password")
    check verifyPassword("", hash) == false

  test "verifyPassword with empty password hash works":
    let hash = hashPassword("")
    check verifyPassword("", hash) == true
    check verifyPassword("not-empty", hash) == false

suite "Session Cookie Signing":
  test "signSessionCookie produces sessionId.signature format":
    let cookie = signSessionCookie("abc123", "secret")
    check '.' in cookie
    let parts = cookie.split('.')
    check parts.len == 2
    check parts[0] == "abc123"
    check parts[1].len == 64  # hex-encoded HMAC-SHA256

  test "signSessionCookie is deterministic for same inputs":
    let c1 = signSessionCookie("session1", "key")
    let c2 = signSessionCookie("session1", "key")
    check c1 == c2

  test "signSessionCookie produces different output for different secrets":
    let c1 = signSessionCookie("session1", "key1")
    let c2 = signSessionCookie("session1", "key2")
    check c1 != c2

suite "Session Cookie Verification":
  test "verifySessionCookie round-trips correctly":
    let secret = "my-app-secret"
    let sessionId = "abcdef1234567890"
    let cookie = signSessionCookie(sessionId, secret)
    let result = verifySessionCookie(cookie, secret)
    check result == sessionId

  test "verifySessionCookie returns empty for tampered session ID":
    let secret = "my-secret"
    let cookie = signSessionCookie("original-id", secret)
    # Replace session ID portion
    let tampered = "tampered-id" & cookie[cookie.find('.')..^1]
    check verifySessionCookie(tampered, secret) == ""

  test "verifySessionCookie returns empty for tampered signature":
    let secret = "my-secret"
    let cookie = signSessionCookie("session123", secret)
    # Modify last char of signature
    let tampered = cookie[0..^2] & (if cookie[^1] == 'a': "b" else: "a")
    check verifySessionCookie(tampered, secret) == ""

  test "verifySessionCookie returns empty for wrong secret":
    let cookie = signSessionCookie("session1", "secret1")
    check verifySessionCookie(cookie, "secret2") == ""

  test "verifySessionCookie returns empty for missing dot":
    check verifySessionCookie("nodothere", "secret") == ""

  test "verifySessionCookie returns empty for empty string":
    check verifySessionCookie("", "secret") == ""

  test "verifySessionCookie returns empty for just a dot":
    check verifySessionCookie(".", "secret") == ""

  test "verifySessionCookie returns empty for dot at start":
    check verifySessionCookie(".signature", "secret") == ""

  test "verifySessionCookie returns empty for dot at end":
    check verifySessionCookie("sessionid.", "secret") == ""

  test "verifySessionCookie handles session IDs with special characters":
    let secret = "key"
    let sessionId = "abc-def_123"
    let cookie = signSessionCookie(sessionId, secret)
    check verifySessionCookie(cookie, secret) == sessionId

  test "verifySessionCookie handles long session IDs":
    let secret = "key"
    let sessionId = "a".repeat(128)
    let cookie = signSessionCookie(sessionId, secret)
    check verifySessionCookie(cookie, secret) == sessionId
