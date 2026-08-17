## Password generation and management for the dootd daemon.
## Generates cryptographically random admin passwords and manages
## hashing/verification using argon2id via crypto.nim.

import std/sysrand
import db_connector/db_sqlite
import ./crypto
import ./dootd_state

const
  PasswordGroupSize = 4
  PasswordGroups = 3
  PasswordChars = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    ## Character set excludes ambiguous characters: l, I, 1, O, 0

proc generateAdminPassword*(): string =
  ## Generate a cryptographically random password in the format k3x9-p2mN-q8vL.
  ## Uses groups of 4 alphanumeric characters separated by hyphens.
  ## Total: 12 random characters + 2 hyphens = 14 chars displayed.
  let totalChars = PasswordGroupSize * PasswordGroups
  var bytes: array[12, byte]
  if not urandom(bytes):
    raise newException(OSError, "Failed to read from system random source")

  result = ""
  for i in 0 ..< totalChars:
    if i > 0 and i mod PasswordGroupSize == 0:
      result.add('-')
    let idx = int(bytes[i]) mod PasswordChars.len
    result.add(PasswordChars[idx])

proc hashAndStorePassword*(db: DbConn, plaintext: string) =
  ## Hash a password with argon2id and store it in the config table.
  let hash = hashPassword(plaintext)
  setConfig(db, "admin_password_hash", hash)

proc verifyAdminPassword*(db: DbConn, plaintext: string): bool =
  ## Verify a plaintext password against the stored hash.
  ## Returns false if no password is set.
  let hash = getConfig(db, "admin_password_hash")
  if hash.len == 0:
    return false
  result = verifyPassword(plaintext, hash)

proc isPasswordSet*(db: DbConn): bool =
  ## Check if an admin password has been configured.
  let hash = getConfig(db, "admin_password_hash")
  result = hash.len > 0

proc resetPassword*(db: DbConn): string =
  ## Generate a new admin password, hash and store it.
  ## Returns the plaintext password (to display once to the user).
  result = generateAdminPassword()
  hashAndStorePassword(db, result)
