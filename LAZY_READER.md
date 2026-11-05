# Zero/Low-Allocation Lazy TOML Reader (`motoml.lazy`)

## Overview

The new lazy TOML reader operates directly on borrowed document byte spans (`Span[Byte, origin]`), avoiding eager memory allocations, string copying, and upfront scalar conversions.

### Key Architectural Improvements

1. **Flat Tape of 32-Byte `TrivialRegisterPassable` Nodes (`src/lazy/node.mojo`)**:
   Instead of allocating nested heap collections (`Dict[String, Toml]` and `List[Toml]`) for every table and array, the entire document hierarchy is parsed into a single contiguous array of 32-byte `Node`s with intrusive links (`first_child`, `last_child`, `next_sibling`) and `O(1)` container element counts.

2. **Zero Hot-Path Allocations (`src/lazy/reader.mojo`)**:
   A stateful `_Parser` reuses a single `List[KeySeg]` buffer across all key paths and nested inline tables (`shrink`), eliminating per-key heap allocations and intermediate `Result` wrapping.

3. **16-Byte SIMD String & Comment Scanning (`src/lazy/reader.mojo`, `src/lazy/lexer.mojo`)**:
   Basic strings, literal strings, multiline strings, comments, and the ASCII UTF-8 fast path scan 16–64 bytes per iteration using `unsafe_load[width=16]` + `pack_bits` + `count_trailing_zeros`, paired with 256-byte `.rodata` character classification tables.

4. **Single-Probe 16-Byte `KeyIndex` with Inline FNV-1a Hashing (`src/lazy/key_index.mojo`)**:
   Key hashes are computed inline during key scanning and combined via symmetric parent-hash mixing (`mix_parent_hash`). Table creation and duplicate detection use a single-probe `find_or_insert`, and escaped keys are canonicalized so escaped and bare keys collide properly.

5. **Parametrized Compile-Time Validation (`Validation` in `src/lazy/validation.mojo`)**:
   - `Validation.Strict` (default): enforces full TOML 1.1 compliance at parse time (`712/712` `toml-test` suite: all 218 valid accepted, all 494 invalid rejected by `parse_lazy`), including UTF-8, duplicate key checks, escape validation, and lexical scalar validation.
   - `Validation.Lexical`: enforces UTF-8 and lexical/scalar validation without hash-index duplicate checks.
   - `Validation.Structure`: enforces duplicate-key and table redefinition checks without UTF-8 or scalar lexical overhead.
   - `Validation.Trusted`: compiles out UTF-8, duplicate-key, and parse-time lexical checks via `comptime if` for maximum throughput on trusted inputs.

---

## Benchmark Results

Measured with Mojo `1.3.0.dev2026110405` (`-O3`) on Apple Silicon (M-series, macOS).

### 1 MB Synthetic & Hold-Out Corpora (15 runs, median)

| Corpus | Set | Baseline Strict (MB/s) | Optimized Strict (MB/s) | Strict Speedup | Optimized Trusted (MB/s) | Parse + `to_json` (MB/s) |
|---|---|---:|---:|---:|---:|---:|
| `strings_plain` | Tuned | 347.1 MB/s | **2,016.0 MB/s** | **5.81x** | **2,146.0 MB/s** | **1,164.0 MB/s** |
| `array_of_tables` | Tuned | 195.4 MB/s | **612.0 MB/s** | **3.13x** | **619.0 MB/s** | **360.0 MB/s** |
| `huge_table` | Tuned | 238.1 MB/s | **588.0 MB/s** | **2.47x** | **602.0 MB/s** | **371.0 MB/s** |
| `mixed` | Tuned | 182.1 MB/s | **503.0 MB/s** | **2.76x** | **572.0 MB/s** | **272.0 MB/s** |
| `strings_escaped` | Tuned | 266.7 MB/s | **499.0 MB/s** | **1.87x** | **417.0 MB/s** | **237.0 MB/s** |
| `ints_floats` | Tuned | 150.7 MB/s | **423.0 MB/s** | **2.81x** | **523.0 MB/s** | **168.0 MB/s** |
| `dates` | Tuned | 154.0 MB/s | **363.0 MB/s** | **2.36x** | **436.0 MB/s** | **253.0 MB/s** |
| `many_tables` | Tuned | 99.1 MB/s | **360.0 MB/s** | **3.63x** | **372.0 MB/s** | **264.0 MB/s** |
| `dotted_keys` | Tuned | 80.7 MB/s | **356.0 MB/s** | **4.41x** | **360.0 MB/s** | **276.0 MB/s** |
| `inline_nested` | Tuned | 136.6 MB/s | **350.0 MB/s** | **2.56x** | **361.0 MB/s** | **242.0 MB/s** |
| `realworld_lock` | **Hold-Out** | 324.8 MB/s | **1,234.0 MB/s** | **3.80x** | **1,240.0 MB/s** | **739.0 MB/s** |
| `realworld_config` | **Hold-Out** | 242.7 MB/s | **740.0 MB/s** | **3.05x** | **765.0 MB/s** | **423.0 MB/s** |
| `toml_test_concat` | **Hold-Out** | 169.8 MB/s | **540.0 MB/s** | **3.18x** | **618.0 MB/s** | **357.0 MB/s** |

### 10 MB Pressure Test

| Corpus | Old Parser (ms) | Old Parser (MB/s) | Lazy Strict (ms) | Lazy Strict (MB/s) | Speedup vs Old |
|---|---:|---:|---:|---:|---:|
| `strings_plain_10mb` | 125.26 ms | 79.8 MB/s | **8.92 ms** | **1,121.6 MB/s** | **14.05x** |
| `mixed_10mb` | 333.58 ms | 30.0 MB/s | **38.28 ms** | **261.2 MB/s** | **8.71x** |
| `many_tables_10mb` | 822.00 ms | 12.2 MB/s | **45.79 ms** | **218.4 MB/s** | **17.95x** |
| `inline_nested_10mb` | 628.83 ms | 15.9 MB/s | **71.37 ms** | **140.1 MB/s** | **8.81x** |

---

## API Usage

```mojo
from motoml.lazy import parse_lazy, Validation
from motoml.mmap_file import MappedFile

def main() raises:
    var mf = MappedFile("config.toml")
    var view = mf.unsafe_view()

    # Parse with default Strict validation
    var doc = parse_lazy(view.as_bytes()).take()

    # Access values by key or path
    var host = doc["server"].value()["host"].value().as_slice().value()
    var port = doc["server"].value()["port"].value().as_int().take()

    # Array iteration
    var users = doc["users"].value()
    for i in range(len(users)):
        print(users[i].value()["name"].value().as_slice().value())

    # For maximum speed on known-valid TOML:
    var trusted_doc = parse_lazy[Validation.Trusted](view.as_bytes()).take()
```
