# String reference optimization

## UTF-8 validation

Mojo `String` maintains a valid UTF-8 invariant. In the Mojo standard-library
source used for this check, `String(unsafe_from_utf8=...)` still contains an
`_is_valid_utf8` assertion, while `String(from_utf8=...)` checks validity
explicitly before delegating to that constructor. The source is available in
the [Modular standard library](https://github.com/modular/modular/blob/9d6a4ca8fc378f2cd5f1f70479bac27b8b3c2615/Mojo/stdlib/std/collections/string/string.mojo).

That invariant does not make the parser's document-level UTF-8 check
redundant: `MappedFile.unsafe_view()` creates a `StringSlice` from mapped bytes
without validating them. `parse_toml()` must continue validating the complete
input once, before parsing or exposing string slices. `StringRef` had no
separate UTF-8 validation to remove; its escape validation checks TOML string
escape syntax and must remain.

## Change

`StringRef.calc_value()` now scans the trimmed source for bytes that can change
the result: backslashes, quotes, or the control characters converted by
`CommonEscape`. If none are present, it copies the slice directly into the
result `String` and skips escape parsing, quote escaping, and the common-escape
replacement passes. Strings that need TOML processing still use the existing
validation and decoding paths.

This is a fast path only; it does not change the behavior for strings that
contain escapes, quotes, or converted control characters.

## Benchmark

Measured with Mojo `1.2.0.dev2026101705` and `tests/bench_parser.mojo`, using
214 valid suite files (27,548 input bytes). Each number is the benchmark's
reported total parse time across those files; the result checksum was `577`
for every run.

| Implementation | Runs (ns) | Median (ns) |
|---|---:|---:|
| Before fast path | 1,028,969; 1,057,772; 1,037,241 | 1,037,241 |
| Fast path | 856,148; 866,845; 865,105 | 865,105 |

The median total was approximately **16.6% lower** with the fast path. Timings
are environment-dependent; these results are for the same machine and
benchmark configuration.

## Parser hot-path optimization

`string_to_type()` now dispatches special scalar tokens by their first byte,
so ordinary numeric values avoid repeated slice comparisons against `true`,
`false`, `nan`, and `inf`. Exact token matching and boolean terminator checks
are preserved. Decimal digit validation also applies the leading-zero rule in
the same pass that validates digits and separators, avoiding a second scan for
decimal integers and float mantissas. `is_digit_for_base()` is always inlined
for its validation loops.

Measured with the same Mojo version and benchmark setup as above. The previous
row is the last optimization documented here; the parser changes were measured
over five runs. Each run parsed 214 valid suite files (27,548 bytes), and every
run produced checksum `577`.

| Implementation | Runs (ns) | Median (ns) |
|---|---:|---:|
| StringRef fast path | 856,148; 866,845; 865,105 | 865,105 |
| Parser hot-path changes | 849,980; 854,247; 839,431; 845,080; 843,460 | 845,080 |

The new median is approximately **2.3% lower** than the previous optimization's
median. This is a modest improvement, and the observed run-to-run variation
means timings should be treated as environment-dependent rather than a
guaranteed speedup.

## Further parser and string-processing changes

The current implementation includes additional changes beyond the scalar
hot-path optimization:

- `StringRef.calc_value()` keeps the direct-copy path for strings that need no
  processing. When processing is needed, `_escape_for_output()` now converts
  control characters and, for literal strings, escapes backslashes and quotes
  in one pass instead of chaining multiple `String.replace()` allocations.
  Basic-string escape validation and decoding still run before output escaping.
- Parser path tracking uses `Set[String]` for membership and a dictionary for
  array-table occurrence counts. Key paths are built incrementally using
  length-prefixed segments, and paths for key/value entries are only built
  when their values are arrays or inline tables.
- Already-validated bare keys are copied directly from their source bytes
  rather than passing through `StringRef` processing. Table construction also
  avoids creating intermediate tables before they are needed, transfers parsed
  entries directly into empty tables, and uses smaller initial array capacities.
- `parse_toml()` validates document control characters up front, including
  enforcing CRLF for carriage returns.

### Current working-tree benchmark

Ran with Mojo `1.2.0.dev2026101705` using Pixi and `tests/bench_parser.mojo`.
The five runs parsed 214 valid suite files (27,548 input bytes); each produced
checksum `577`.

| Implementation | Runs (ns) | Median (ns) |
|---|---:|---:|
| Previously reported parser hot-path changes | 849,980; 854,247; 839,431; 845,080; 843,460 | 845,080 |
| Current implementation | 697,133; 700,917; 704,563; 702,067; 704,760 | 702,067 |

The current median is **16.9% lower** than the previously reported parser
hot-path median and **32.3% lower** than the original pre-fast-path median.
This benchmark measures the current set of changes together; it does not
isolate the contribution of any individual change. As before, timings are
environment-dependent.

## Validation

- `pixi run package`
- `pixi run move-to-test`
- `cd tests && pixi run mojo test_parser.mojo` — 8 passed
- `cd tests && pixi run mojo test_toml_suite.mojo` — 680 passed
- `pixi run bench-parser` and `cd tests && pixi run mojo bench_parser.mojo` —
  5 runs, checksum `577` on every run
