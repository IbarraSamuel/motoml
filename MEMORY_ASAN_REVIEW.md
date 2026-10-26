# Memory and ASAN Review

## Findings and fixes

- **TOML values did not release owned payloads.** `Toml` had an empty
  destructor, and its recursive array/table payloads could not use the
  compiler-generated enum destructor. `Toml` now explicitly conforms to
  `Deinitable`; its destructor dispatches to `_deinit_toml`, which releases
  scalar payloads and recursively destroys array elements and table values
  using the collection `deinit_with` APIs.
- **Failed reflected-struct conversions leaked initialized fields.**
  `_rebind_struct` allocated raw storage and deallocated it on errors without
  destroying fields that had already been initialized. The new cleanup helper
  destroys those fields in reverse order before deallocating the storage.
- **Truncated quoted values could read beyond the input.** `parse_value`
  checked quote lookahead bytes before ensuring they were present. The
  lookahead is now length-guarded, and an empty input at the value position
  returns a parse error.
- **A trailing backslash could be read past the end of a string.**
  `_find_escapes` now returns an incomplete-escape error before reading the
  byte after a final backslash.

Regression coverage was added for failed struct conversion after an owned
field is initialized, truncated quoted values, and incomplete string escapes.
The standalone [ASAN fixture runner](./tests/asan_parser.mojo) reads the suite
manifest and passes every listed TOML file through `parse_toml`, consuming
successful values and expected parse errors so their owned payloads are
destroyed during the run.

## Validation

The package precompiled successfully with Mojo
`1.3.0.dev2026102505 (1c0b6f77)`. Tests run against that fresh package:

- `tests/test_parser.mojo`: 9 passed
- `tests/test_reflection.mojo`: 17 passed
- `tests/test_toml_type.mojo`: 10 passed
- `tests/test_toml_suite.mojo`: 712 passed

The standalone runner was built as `/tmp/motoml-asan-parser` with
`--sanitize address` and run from the repository root:

```sh
ASAN_OPTIONS=halt_on_error=1:abort_on_error=1 /tmp/motoml-asan-parser
```

Result: `ASAN TOML fixture run passed: 712 files`, with no address-sanitizer
findings. Linking required a temporary, external compatibility shim to forward
Mojo's ASAN v8 version-check symbol to the installed Xcode Clang 21 runtime's
Apple-specific version-check symbol. The shim and executable are outside the
repository. LeakSanitizer is not supported by this macOS runtime; enabling
`detect_leaks` exits with an unsupported-platform message, so the run verifies
address-safety checks but not leak detection.
