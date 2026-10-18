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

## Validation

- `pixi run package`
- `pixi run move-to-test`
- `cd tests && pixi run mojo test_parser.mojo` — 8 passed
- `cd tests && pixi run mojo test_toml_suite.mojo` — 680 passed
- `cd tests && pixi run mojo bench_parser.mojo` — checksum `577` on every run
