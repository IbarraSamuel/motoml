# Zero/Low-Allocation Lazy TOML Reader (`motoml.lazy`)

## Overview

The new lazy TOML reader operates directly on borrowed document byte spans (`Span[Byte, origin]`), avoiding eager memory allocations, string copying, and upfront scalar conversions.

### Key Architectural Improvements

1. **Flat Tape of Nodes (`src/lazy/node.mojo`)**:
   Instead of allocating nested heap collections (`Dict[String, Toml]` and `List[Toml]`) for every table and array, the entire document hierarchy is parsed into a single contiguous array of 32-byte `Node`s with intrusive links (`first_child`, `last_child`, `next_sibling`).

2. **Zero-Copy Strings & Keys**:
   Strings and keys borrow directly from the input buffer. Unescaping is evaluated lazily only when requested via `as_string()` or streamed directly to any `Writer` without intermediate `String` allocation.

3. **Flat Hash KeyIndex (`src/lazy/key_index.mojo`)**:
   Duplicate key detection and table lookups use an open-addressing hash table referencing byte offsets in the source buffer. No `String` keys, no string concatenations, and no `Set[String]` path tracking.

4. **Lazy Scalar Parsing (`src/lazy/scalar_decode.mojo`)**:
   Numbers, booleans, and dates are classified during token scanning but only decoded when accessed (`as_int()`, `as_float()`, `as_date()`).

5. **Parametrized Validation (`Validation.Strict` vs `Validation.Trusted`)**:
   The validation mode is a compile-time parameter on the document type:
   - `Validation.Strict` (default): enforces UTF-8, duplicate key checks, and TOML syntax rules.
   - `Validation.Trusted`: compiles out UTF-8 and duplicate key checks for maximum parsing speed on trusted inputs.

---

## Benchmark Results

Measured with Mojo `1.3.0.dev2026103105` on Apple Silicon (M-series, macOS).

### 1 MB Synthetic Corpora

| Corpus | Old Parser (ms) | Old Parser (MB/s) | Lazy Strict (ms) | Lazy Strict (MB/s) | Speedup (Strict) | Lazy Trusted (MB/s) | Speedup (Trusted) |
|---|---:|---:|---:|---:|---:|---:|---:|
| `many_tables` | 57.74 ms | 17.3 MB/s | **10.04 ms** | **99.6 MB/s** | **5.75x** | **111.3 MB/s** | **6.43x** |
| `inline_nested` | 56.06 ms | 17.8 MB/s | **11.03 ms** | **90.6 MB/s** | **5.08x** | **104.6 MB/s** | **5.86x** |
| `array_of_tables` | 39.81 ms | 25.1 MB/s | **8.62 ms** | **116.0 MB/s** | **4.62x** | **127.0 MB/s** | **5.06x** |
| `dotted_keys` | 41.42 ms | 24.1 MB/s | **9.18 ms** | **109.0 MB/s** | **4.51x** | **122.4 MB/s** | **5.07x** |
| `strings_escaped` | 21.51 ms | 46.5 MB/s | **4.97 ms** | **201.1 MB/s** | **4.33x** | **215.6 MB/s** | **4.64x** |
| `mixed` | 28.98 ms | 34.5 MB/s | **8.01 ms** | **124.8 MB/s** | **3.62x** | **142.8 MB/s** | **4.14x** |
| `dates` | 24.17 ms | 41.4 MB/s | **7.82 ms** | **127.8 MB/s** | **3.09x** | **151.0 MB/s** | **3.65x** |
| `ints_floats` | 22.78 ms | 43.9 MB/s | **8.44 ms** | **118.6 MB/s** | **2.70x** | **134.5 MB/s** | **3.06x** |
| `huge_table` | 16.48 ms | 60.7 MB/s | **7.97 ms** | **125.4 MB/s** | **2.07x** | **156.7 MB/s** | **2.58x** |
| `strings_plain` | 8.64 ms | 115.7 MB/s | **4.16 ms** | **240.2 MB/s** | **2.08x** | **246.8 MB/s** | **2.13x** |

### 10 MB Pressure Test

| Corpus | Old Parser (ms) | Old Parser (MB/s) | Lazy Strict (ms) | Lazy Strict (MB/s) | Speedup |
|---|---:|---:|---:|---:|---:|
| `many_tables_10mb` | 811.31 ms | 12.3 MB/s | **123.68 ms** | **80.9 MB/s** | **6.56x** |
| `inline_nested_10mb` | 688.87 ms | 14.5 MB/s | **165.27 ms** | **60.5 MB/s** | **4.17x** |
| `mixed_10mb` | 348.89 ms | 28.7 MB/s | **100.43 ms** | **99.6 MB/s** | **3.47x** |
| `strings_plain_10mb` | 120.01 ms | 83.3 MB/s | **47.08 ms** | **212.4 MB/s** | **2.55x** |

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
