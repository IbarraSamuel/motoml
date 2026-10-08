# TOML suite failure fixes

The baseline command `pixi run test-toml-suite` reported 217 failures. This log
records each implementation change made while addressing those failures.

## 1. Reject collisions while merging table contents

- **Failing case:** `tests/toml_files/invalid/array/extend-defined-aot.toml`
- **Changed:** `src/parser.mojo`, in `parse_multiline_collections`, immediately
  before merging parsed values into the table container.
- **Why the old implementation was wrong:** The parser called `update` directly
  on an existing table. That silently replaced an existing key (in this case,
  an array-of-tables) with new values instead of rejecting the invalid
  redefinition.
- **Change:** Check the parsed table's keys against the destination first and
  return an error if a key already exists. The valid, non-overlapping table
  merge continues to use the existing update operation.

## 2. Reject arrays that reach end-of-input before `]`

- **Failing cases:** `tests/toml_files/invalid/array/no-close-01.toml` through
  `no-close-08.toml`
- **Changed:** `src/parser.mojo`, in `parse_inline_array`, after its parsing
  loop and before returning the array.
- **Why the old implementation was wrong:** The loop also stops when its index
  reaches the input length. The function then returned the partially parsed
  array without distinguishing that premature end from encountering `]`.
- **Change:** Return a parse error when the loop ended at or beyond the input
  length; a closed array still returns through the existing success path.

## 3. Distinguish array-of-tables from static arrays

- **Failing case:** `tests/toml_files/invalid/array/extending-table.toml`
- **Changed:** `src/parser.mojo`, in `parse_multiline_collections` and
  `get_table_ref`.
- **Why the old implementation was wrong:** `get_table_ref` descended into the
  last table of any array. That is needed for `[[...]]` arrays, but incorrectly
  allowed a later table header to extend an ordinary static array such as
  `a = [{ b = 1 }]`.
- **Change:** Keep the paths explicitly declared as array-of-tables during the
  parse and permit descent or appending only for those paths. Also initialize
  that path list once per parse of multiline collections so later headers can
  consult earlier declarations.

## 4. Require separators between array elements

- **Failing cases:** `tests/toml_files/invalid/array/no-comma-01.toml`,
  `no-comma-02.toml`, and `missing-separator-01.toml`,
  `missing-separator-02.toml`, `text-before-array-separator.toml`
- **Changed:** `src/parser.mojo`, in `parse_inline_array`, after each element is
  parsed.
- **Why the old implementation was wrong:** `stop_at[Comma, SquareBracketClose]`
  searched forward for a delimiter. This allowed invalid tokens between array
  elements (or after a value) to be silently skipped.
- **Change:** After whitespace/comments, accept only end-of-input, `]`, or a
  comma; return a parse error for any other token.

## 5. Reject unterminated inline tables

- **Failing case:** `tests/toml_files/invalid/array/no-close-06.toml`
- **Changed:** `src/parser.mojo`, in `parse_kv_pairs`, before returning the
  parsed table.
- **Why the old implementation was wrong:** The same loop handles both
  inline tables and document-level table values. It returned the parsed
  contents when input ended, even when an inline table still required `}`.
- **Change:** Treat end-of-input as an error only when `parse_kv_pairs` is
  parsing an inline table (its `end_char` is `}`), leaving document-level
  tables unchanged.

## 6. Stop inline-table parsing at actual separators

- **Failing case:** `tests/toml_files/invalid/array/no-close-06.toml`
- **Changed:** `src/parser.mojo`, in the inline-table (`separator == ','`)
  branch of `parse_kv_pairs`.
- **Why the old implementation was wrong:** The generic `stop_at` scan looked
  for `}` without recognizing comments, so a `}` inside an end-of-line comment
  was mistaken for the inline table's closing delimiter.
- **Change:** For comma-separated inline tables, skip only TOML whitespace and
  comments, then require either the actual closing delimiter or a comma.

## 7. Reject array-of-tables declarations over empty arrays

- **Failing case:** `tests/toml_files/invalid/array/tables-01.toml`
- **Changed:** `src/parser.mojo`, in `get_table_ref`, before appending an
  array-of-tables entry.
- **Why the old implementation was wrong:** The check treated an existing
  array as a conflict only when it contained at least one item. An explicitly
  defined empty array therefore passed as if it were a new array-of-tables.
- **Change:** Record whether the key already existed before `setdefault` and
  reject an unmarked existing array regardless of its length.

## 8. Require a token boundary after boolean literals

- **Failing cases:** `tests/toml_files/invalid/bool/starting-same-false.toml`
  and `starting-same-true.toml`
- **Changed:** `src/parser.mojo`, in `string_to_type`, using the new
  `is_value_terminator` helper.
- **Why the old implementation was wrong:** The parser matched `false` or
  `true` by prefix only, so values such as `falsey` and `truer` were accepted as
  booleans and their suffixes were skipped by the outer parser.
- **Change:** Require a valid value terminator immediately after a boolean
  literal. The helper recognizes delimiters, whitespace, comments, and
  end-of-input.

## 9. Reject prohibited control bytes throughout the document

- **Failing cases:** The invalid control-character fixtures under
  `tests/toml_files/invalid/control/` (29 cases).
- **Changed:** `src/parser.mojo`, adding `validate_control_characters` and
  invoking it at the start of `parse_toml`.
- **Why the old implementation was wrong:** The parser treated carriage
  returns as ignorable whitespace and did not validate control bytes in values,
  strings, or comments, allowing TOML-forbidden input through.
- **Change:** Scan the full document before tokenization. Permit TAB and LF,
  permit CR only as part of CRLF, and reject other C0 bytes and DEL in every
  context.

## 10. Validate date, time, and offset formats and ranges

- **Failing cases:** The invalid fixtures under
  `tests/toml_files/invalid/datetime/`, `local-date/`, `local-datetime/`, and
  `local-time/` (36 cases).
- **Changed:** `src/types/tempo.mojo`, in `Date.from_string`,
  `Time.from_string`, and `Offset.from_string`.
- **Why the old implementation was wrong:** These constructors converted
  substrings to numbers but did not enforce exact field formats or legal
  calendar/clock ranges. Impossible dates, out-of-range times and offsets, and
  malformed fractional seconds could therefore become TOML values.
- **Change:** Validate digit/separator positions, month-specific day counts
  with Gregorian leap-year rules, clock and offset limits, and fractional
  second syntax before constructing values.

## 11. Restrict unquoted keys to TOML bare-key characters

- **Failing cases:** `tests/toml_files/invalid/encoding/ideographic-space.toml`
  and `tests/toml_files/invalid/table/bare-invalid-character-01.toml` /
  `bare-invalid-character-02.toml`
- **Changed:** `src/parser.mojo`, adding `is_bare_key_char` and applying it in
  `parse_keys` while scanning an unquoted key.
- **Why the old implementation was wrong:** The key scanner advanced through
  arbitrary bytes until it encountered a recognized delimiter. This let
  non-ASCII whitespace and other forbidden characters be accepted in bare
  keys.
- **Change:** Permit only ASCII letters, digits, `_`, and `-` in bare-key
  segments. Quoted keys continue through their existing string parser.

## 12. Validate decimal and based numeric tokens

- **Failing cases:** The invalid numeric fixtures under
  `tests/toml_files/invalid/float/` and `tests/toml_files/invalid/integer/`
  (39 cases).
- **Changed:** `src/parser.mojo`, adding digit-sequence, integer, and float
  validators and using them in `string_to_type`.
- **Why the old implementation was wrong:** Integer parsing accepted
  underscore removal without validating separator placement or leading zeros.
  Float parsing treated any token containing `e`/`E` as a float and delegated
  malformed forms directly to `atof`.
- **Change:** Validate signs, bases, digit placement, separators, leading
  zeros, decimal points, and exponents before conversion.

## 13. Preserve inline-table immutability

- **Failing cases:** `tests/toml_files/invalid/inline-table/duplicate-key-03.toml`,
  `overwrite-02.toml`, `overwrite-05.toml`, and `overwrite-08.toml`
- **Changed:** `src/parser.mojo`, threading inline-table paths through
  `parse_toml`, `parse_multiline_collections`, `parse_kv_pairs`, `parse_value`,
  and `get_table_ref`.
- **Why the old implementation was wrong:** Parsed inline tables became
  ordinary `Toml.Table` values with no record that TOML forbids extending them.
  Consequently a later dotted key or table header could descend into one.
- **Change:** Track the dotted paths of inline tables and reject later
  assignments or table headers that descend into or redefine those paths.

## 14. Reject trailing tokens after document values

- **Failing case:** `tests/toml_files/invalid/integer/text-after-integer.toml`
- **Changed:** `src/parser.mojo`, in the newline-separated branch of
  `parse_kv_pairs`.
- **Why the old implementation was wrong:** The generic `stop_at` scan moved
  to the next newline and discarded any unparsed characters after a valid
  value, so `42 the ultimate answer?` was accepted as `42`.
- **Change:** After a document value, allow only spaces/tabs, a comment, a
  newline, or end-of-input; otherwise return a parse error.

## 15. Reject malformed and empty key segments

- **Failing cases:** The remaining invalid fixtures under
  `tests/toml_files/invalid/key/` (7 cases).
- **Changed:** `src/parser.mojo`, in `parse_keys`.
- **Why the old implementation was wrong:** The key scanner allowed empty
  bare segments around dots, accepted raw newlines in quoted keys, and could
  replace an already-scanned bare segment with a following quoted segment.
- **Change:** Reject empty bare segments, newline-containing quoted keys, and
  mixed bare/quoted segments. Empty quoted keys remain legal.

## 16. Reject redefinition of dotted-key and declared tables

- **Failing cases:** `tests/toml_files/invalid/spec-1.1.0/common-46-0.toml`
  and `common-46-1.toml`
- **Changed:** `src/parser.mojo`, in `parse_kv_pairs` and
  `parse_multiline_collections`.
- **Why the old implementation was wrong:** A dotted key such as
  `apple.color = "red"` created the `apple` table implicitly, but a later
  `[fruit.apple]` or `[fruit.apple.taste]` header reused that table instead of
  rejecting its redefinition. The initial existing-key check also rejected
  legal cases where a table parent was only implicitly created by another
  table header.
- **Change:** Track dotted-key-created paths separately from explicitly
  declared headers. Reject headers targeting dotted-key-created paths and
  repeated explicit headers, while allowing valid implicit table parents.

## 17. Validate string escapes and single-line boundaries

- **Failing cases:** The 21 remaining fixtures under
  `tests/toml_files/invalid/string/`, covering unknown/malformed escapes,
  non-scalar Unicode escapes, malformed multiline continuations, and raw
  newlines in single-line strings.
- **Changed:** `src/types/string_ref.mojo`, adding `validate_string_escapes`
  and calling it before decoding basic strings; `src/parser.mojo`, rejecting
  CR/LF while scanning single-line quoted strings.
- **Why the old implementation was wrong:** The string decoder transformed
  only selected escape forms and let unknown escapes pass through. It also
  converted Unicode escapes without checking for surrogate or out-of-range
  code points. The quoted-string scanner could continue across raw newlines.
- **Change:** Validate each basic-string escape and Unicode scalar before the
  existing conversion, allow multiline line-continuation escapes only in
  multiline strings, and reject raw newlines in single-line strings.

## 18. Preserve empty quoted keys

- **Affected valid cases:** `tests/toml_files/valid/key/empty-01.toml` through
  `empty-03.toml`, `dotted-empty.toml`, and empty-name table fixtures.
- **Changed:** `src/parser.mojo`, in `parse_keys`.
- **Why the initial key validation was too broad:** TOML permits an empty key
  when it is quoted; only an empty bare key or empty bare dotted segment is
  invalid.
- **Change:** Keep the rejection for empty bare segments but allow empty quoted
  segments, including as a complete key.

## 19. Accept valid hexadecimal and multiline string escapes

- **Affected valid cases:** `tests/toml_files/valid/string/hex-escape.toml`,
  `ends-in-whitespace-escape.toml`, and multiline fixtures.
- **Changed:** `src/types/string_ref.mojo`, in `validate_string_escapes`.
- **Why the initial escape validation was too narrow:** It rejected TOML's
  valid two-digit `\xHH` escapes and required a multiline continuation
  backslash to be immediately followed by a line break, rather than allowing
  spaces/tabs before that line break.
- **Change:** Validate two-digit hexadecimal escapes and allow spaces/tabs
  between a multiline continuation backslash and its CRLF/LF.

## 20. Accept times without seconds

- **Affected valid cases:** `tests/toml_files/valid/datetime/no-seconds.toml`.
- **Changed:** `src/types/tempo.mojo`, in `Time.from_string`.
- **Why the initial range fix was too narrow:** It required seconds in every
  local time and date-time, although TOML permits `HH:MM` without seconds.
- **Change:** Accept the five-byte `HH:MM` form with seconds defaulted to zero,
  while retaining strict validation when seconds are present.

## 21. Preserve CRLF document separators

- **Affected valid case:** `tests/toml_files/valid/newline-crlf.toml`.
- **Changed:** `src/parser.mojo`, in the newline-separated branch of
  `parse_kv_pairs`.
- **Why the initial trailing-token fix was too narrow:** It accepted LF as a
  line separator but rejected the CR byte in a valid CRLF pair.
- **Change:** Consume an optional CR before requiring the LF; the document
  validator already rejects a bare CR.

## 22. Keep table paths unambiguous across dotted keys and array entries

- **Affected valid cases:** `tests/toml_files/valid/key/dotted-empty.toml`,
  `valid/spec-1.1.0/common-40.toml`, `valid/array/array-subtables.toml`,
  `valid/table/array-table-array.toml`, `valid/table/names.toml`, and
  `valid/table/names-with-values.toml`.
- **Changed:** `src/parser.mojo`, in `toml_key_path`,
  `table_scope_prefix`, and `parse_multiline_collections`.
- **Why the initial table-path tracking was wrong:** Joining decoded key
  segments with `.` made distinct paths such as `a.b.c` and `a."b.c`
  indistinguishable. It also treated the same subtable name in different
  array-of-table entries as a duplicate.
- **Change:** Encode each key segment with its byte length and qualify
  declarations under array-of-table paths with that entry's occurrence.

## 23. Treat invalid UTF-8 read failures as expected invalid fixtures

- **Failing cases:** The 11 invalid UTF-8/BOM fixtures under
  `tests/toml_files/invalid/encoding/` that cannot be converted to a Mojo
  `String`.
- **Changed:** `tests/test_toml_suite.mojo`, around `file.read_text()`.
- **Why the old test implementation was wrong:** It read the fixture before
  entering the expected-error assertion, so invalid UTF-8 raised outside the
  test's invalid-input handling.
- **Change:** Treat read failures for `invalid/encoding/` fixtures as the
  expected rejection; propagate read failures for every other fixture.

## 24. Ignore table-header-like text inside comments

- **Failing case:** `tests/toml_files/valid/spec-1.1.0/common-40.toml`
- **Changed:** `src/parser.mojo:854`, in `parse_multiline_collections`,
  immediately after a table header.
- **Why the old implementation was wrong:** `stop_at[NewLine, SquareBracketOpen]`
  scanned through a header comment and mistook a `[` inside the comment for
  the next table header, replaying the commented text as syntax.
- **Change:** Consume optional whitespace and the complete comment through its
  newline before advancing to the next table body/header.

## Verification

The final `zsh -lic 'pixi run test-toml-suite'` run completed with **680
passed, 0 failed, 0 skipped**. `git diff --check` and editor diagnostics for
the modified Mojo files also completed without errors.
