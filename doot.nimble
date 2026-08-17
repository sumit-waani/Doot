# Package

version       = "0.1.0"
author        = "Doot Contributors"
description   = "Doot DSL compiler - a web framework that compiles to native binaries"
license       = "MIT"
srcDir        = "src"
bin           = @["doot"]
backend       = "c"

# Dependencies

requires "nim >= 2.0.0"
# db_connector is bundled with the Nim toolchain at the system level.
# The nim.cfg provides the path, so no nimble dependency is needed.

# Tasks

task test, "Run the test suite":
  exec "nim c -r tests/test_lexer.nim"
  exec "nim c -r tests/test_parser.nim"
  exec "nim c -r tests/test_integration.nim"
  exec "nim c -r tests/test_schema.nim"
  exec "nim c -r tests/test_query.nim"
