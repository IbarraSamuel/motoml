# Match ownership refactor findings

The attempted replacement of the unsafe payload extraction helpers with
match-bound payload moves was reverted to the previous implementation.

During validation, the match-based changes caused:

- A native allocator crash in the parser suite when matching out owned
  `Result` payloads.
- Invalid nested table contents when moving a `Toml.Table` out in the parser
  test.
- Invalid values or allocator crashes in list conversions and the
  TOML-conformance JSON translator.

After restoring the previous ownership implementation, `pixi run tests` passes:
10 TOML-type tests, 7 parser tests, 712 TOML conformance tests, and 16
reflection tests. One tuple-pattern in the JSON test helper was left using the
compiler-compatible non-`var` syntax; the tests otherwise use the restored
implementation.
