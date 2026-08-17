import unittest
import ../src/doot/lexer

suite "Lexer":
  test "empty source produces EOF token":
    let tokens = tokenize("")
    check tokens.len == 1
    check tokens[0].kind == tkEof

  test "newToken creates token with correct fields":
    let tok = newToken(tkIdentifier, "hello", 1, 5)
    check tok.kind == tkIdentifier
    check tok.value == "hello"
    check tok.line == 1
    check tok.col == 5
