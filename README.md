# motoml

Fast, fully compliant TOML 1.1 reader and parser for Mojo.

`motoml` provides two complementary parsing engines designed for different workloads:
1. **Lazy TOML Reader (`motoml.lazy`)**: A high-performance, zero/low-allocation parser operating over borrowed byte spans (`Span[Byte]`). Uses a flat node tape and on-demand decoding to achieve **6.8x to 26x faster throughput** than the eager parser (up to **2,597 MB/s** Strict and **2,994 MB/s** Trusted).
2. **Eager DOM Parser (`motoml.parser`)**: Parses TOML directly into an owned AST (`Toml` variant tree) with reflection support (`toml_to_type`) for deserializing into native Mojo structs.

Both engines leverage zero-copy memory-mapped file access via `MappedFile`.

---

## Features

- **Full TOML 1.1 Compliance**: Passes all 712 official TOML 1.1 test suite cases (100% compliant).
- **Zero/Low-Allocation Lazy Reader**:
  - **Flat Tape Architecture**: Parses the document hierarchy into a single contiguous tape of 32-byte `Node`s with intrusive links, eliminating nested heap collections (`Dict` and `List`).
  - **Zero-Copy Strings & Keys**: Borrows slices directly from the input buffer. Escape sequences are resolved lazily on demand (`as_string()`) or streamed without intermediate allocations (`to_json`).
  - **Flat KeyIndex**: Table lookup and duplicate key detection use an open-addressing hash table referencing byte offsets.
  - **Lazy Scalar Decoding**: Numbers, booleans, dates, times, and timestamps are classified during scanning and parsed only when queried.
  - **Parametrized Validation**:
    - `Validation.Strict` (default): Spec-compliant UTF-8 validation, duplicate key checking, and syntax verification.
    - `Validation.Trusted`: Bypasses UTF-8 and duplicate key checks for maximum parsing speed on known-valid inputs.
- **Mojo Struct Reflection**: Automatically deserialize TOML tables into typed Mojo structs with compile-time reflection.
- **Memory Mapped File I/O (`MappedFile`)**: Read files with zero-copy memory mapping, avoiding full-file allocations.

---

## Installation & Setup

`motoml` is managed with [Pixi](https://pixi.sh).

```bash
# Clone the repository
git clone https://github.com/mojoto/motoml.git
cd motoml

# Install dependencies and precompile
pixi run package

# Run all test suites
pixi run tests
```

---

## Lazy TOML Reader (`motoml.lazy`)

The lazy reader is recommended for read-heavy workloads, configuration extraction, large TOML files, and high-throughput pipelines.

### Quickstart

```mojo
from motoml.lazy import parse_lazy, Validation, Kind
from motoml.mmap_file import MappedFile

def main() raises:
    # 1. Zero-copy memory map the file
    var mf = MappedFile("config.toml")
    var view = mf.unsafe_view()

    # 2. Parse into a lazy Document view
    var doc = parse_lazy(view.as_bytes()).take()

    # 3. Access table values by key (O(1) open-addressing lookup)
    var server = doc["server"].value()
    var port = server["port"].value().as_int().take()

    # 4. Zero-copy string slice (no allocation if unescaped)
    if var host_slice = server["host"].value().as_slice():
        print("Host:", host_slice.value())

    # 5. Owned string (resolves escape sequences if needed)
    var title = doc["title"].value().as_string().take()

    # 6. Iterate arrays by index and length
    var users = doc["users"].value()
    for i in range(len(users)):
        var user = users[i].value()
        print("User:", user["name"].value().as_string().take())

    # 7. Maximum parsing throughput for trusted inputs
    var trusted_doc = parse_lazy[Validation.Trusted](view.as_bytes()).take()
```

### Lazy Value API

Each `Value` borrowed from a `Document` provides zero-allocation inspection and on-demand decoding methods:

| Method | Return Type | Description |
|---|---|---|
| `val.kind()` | `Kind` | Returns the node type (`Kind.Integer`, `Kind.String`, `Kind.Table`, etc.) |
| `val.is_table()` | `Bool` | Returns `True` if the node is a table |
| `val.is_array()` | `Bool` | Returns `True` if the node is an array |
| `val.is_string()` | `Bool` | Returns `True` if the node is a string |
| `val.is_int()` | `Bool` | Returns `True` if the node is an integer |
| `val.is_float()` | `Bool` | Returns `True` if the node is a float |
| `val.is_bool()` | `Bool` | Returns `True` if the node is a boolean |
| `val.key_slice()` | `StringSpan` | Returns the key name as a borrowed string slice |
| `val.as_slice()` | `Optional[StringSpan]` | Zero-copy borrowed string slice (returns `None` if escaped) |
| `val.as_string()` | `Result[String]` | Decodes to an owned `String`, resolving escapes |
| `val.as_int()` | `Result[Int]` | Decodes to an `Int` (supports dec, hex, oct, bin, underscores) |
| `val.as_float()` | `Result[Float64]` | Decodes to `Float64` (supports floats, exponents, nan, inf) |
| `val.as_bool()` | `Result[Bool]` | Decodes to `Bool` |
| `val.as_date()` | `Result[Date]` | Decodes to a local `Date` (`year`, `month`, `day`) |
| `val.as_time()` | `Result[Time]` | Decodes to a local `Time` (`hour`, `minute`, `second`) |
| `val.as_datetime()` | `Result[DateTime]` | Decodes to a `DateTime` (local or offset timestamp) |
| `val[key]` | `Optional[Value]` | Table lookup by key name in $O(1)$ time |
| `val[index]` | `Optional[Value]` | Array element lookup by zero-based index |
| `len(val)` | `Int` | Number of child entries in a table or array |
| `val.to_json(writer)` | `None raises` | Streams the subtree formatted as JSON directly to any `Writer` |
| `val.to_toml()` | `Toml raises` | Converts the subtree into an eager `Toml` variant |

---

## Eager DOM Parser & Struct Reflection

The eager parser builds an owned `Toml` variant tree and supports deserializing directly into native Mojo structs using compile-time reflection.

```mojo
from motoml.parser import parse_toml_raises
from motoml.reflection import toml_to_type_raises
from motoml.types.toml import Toml

@fieldwise_init
struct ServerConfig(Movable):
    var host: String
    var port: Int
    var enabled: Bool

def main() raises:
    var toml_str = """
    host = "127.0.0.1"
    port = 8080
    enabled = true
    """

    # Parse into eager Toml variant
    var toml_obj = parse_toml_raises(toml_str)

    # Convert directly into a Mojo struct
    var config = toml_to_type_raises[ServerConfig](toml_obj^)
    print(config.host, config.port, config.enabled)
```

---

## Memory-Mapped File Access (`MappedFile`)

`parse_toml_file(path)` parses a file using a read-only memory mapping, avoiding full-file heap allocations and copies.

For direct access with the lazy reader or eager parser:

```mojo
from motoml.mmap_file import MappedFile
from motoml.lazy import parse_lazy

def main() raises:
    var mf = MappedFile("large_dataset.toml")
    var view = mf.unsafe_view()  # Borrowed string view

    var doc = parse_lazy(view.as_bytes()).take()
    # Keep `mf` alive while `doc` and any borrowed views are in use.
```

> [!NOTE]
> `unsafe_view()` does not validate UTF-8 upfront; pass it directly to `parse_lazy` (which validates in `Strict` mode) or `parse_toml`. Keep the `MappedFile` instance alive while referencing its views, and do not truncate the underlying file while mapped.

---

## Benchmarks

Measured with Mojo `1.3.0.dev2026111316` on Apple Silicon (macOS):

### 1 MB Synthetic Corpora (`bench_compare.mojo`)

| Corpus | Old Eager Parser (ms) | Old Eager Parser (MB/s) | Lazy Strict (ms) | Lazy Strict (MB/s) | Speedup (Strict) | Lazy Trusted (MB/s) | Speedup (Trusted) |
|---|---:|---:|---:|---:|---:|---:|---:|
| `many_tables` | 45.65 ms | 21.9 MB/s | **1.76 ms** | **569.2 MB/s** | **25.98x** | **585.1 MB/s** | **26.71x** |
| `array_of_tables` | 27.67 ms | 36.1 MB/s | **1.21 ms** | **825.1 MB/s** | **22.83x** | **880.3 MB/s** | **24.36x** |
| `inline_nested` | 37.95 ms | 26.4 MB/s | **2.28 ms** | **438.8 MB/s** | **16.65x** | **458.7 MB/s** | **17.41x** |
| `strings_plain` | 5.77 ms | 173.3 MB/s | **0.39 ms** | **2,570.8 MB/s** | **14.84x** | **2,976.3 MB/s** | **17.18x** |
| `dotted_keys` | 29.95 ms | 33.4 MB/s | **2.12 ms** | **472.1 MB/s** | **14.14x** | **478.5 MB/s** | **14.33x** |
| `mixed` | 18.38 ms | 54.4 MB/s | **1.41 ms** | **711.3 MB/s** | **13.07x** | **737.5 MB/s** | **13.55x** |
| `dates` | 13.30 ms | 75.2 MB/s | **1.32 ms** | **759.3 MB/s** | **10.10x** | **775.2 MB/s** | **10.31x** |
| `ints_floats` | 14.31 ms | 69.9 MB/s | **1.61 ms** | **621.9 MB/s** | **8.90x** | **628.6 MB/s** | **9.00x** |
| `huge_table` | 9.97 ms | 100.3 MB/s | **1.28 ms** | **781.9 MB/s** | **7.79x** | **747.4 MB/s** | **7.45x** |
| `strings_escaped` | 9.30 ms | 107.5 MB/s | **1.37 ms** | **728.9 MB/s** | **6.78x** | **968.1 MB/s** | **9.01x** |

### Synthetic, Hold-Out & Parse + JSON Suite (`pixi run bench-lazy`, 15 runs median)

| Corpus | Set | Strict (MB/s) | Trusted (MB/s) | Parse + `to_json` (MB/s) |
|---|---|---:|---:|---:|
| `strings_plain` | Tuned | **2,597 MB/s** | **2,994 MB/s** | **1,379 MB/s** |
| `array_of_tables` | Tuned | **820 MB/s** | **864 MB/s** | **436 MB/s** |
| `huge_table` | Tuned | **761 MB/s** | **729 MB/s** | **507 MB/s** |
| `dates` | Tuned | **740 MB/s** | **757 MB/s** | **453 MB/s** |
| `strings_escaped` | Tuned | **715 MB/s** | **956 MB/s** | **366 MB/s** |
| `mixed` | Tuned | **697 MB/s** | **722 MB/s** | **352 MB/s** |
| `ints_floats` | Tuned | **620 MB/s** | **628 MB/s** | **215 MB/s** |
| `many_tables` | Tuned | **559 MB/s** | **567 MB/s** | **376 MB/s** |
| `dotted_keys` | Tuned | **464 MB/s** | **474 MB/s** | **386 MB/s** |
| `inline_nested` | Tuned | **426 MB/s** | **451 MB/s** | **295 MB/s** |
| `realworld_lock` | Hold-Out | **1,592 MB/s** | **1,773 MB/s** | **871 MB/s** |
| `realworld_config` | Hold-Out | **933 MB/s** | **1,021 MB/s** | **551 MB/s** |
| `toml_test_concat` | Hold-Out | **692 MB/s** | **774 MB/s** | **446 MB/s** |

### 10 MB Pressure Test (`bench_10mb.mojo`)

| Corpus | Old Eager Parser (ms) | Old Eager Parser (MB/s) | Lazy Strict (ms) | Lazy Strict (MB/s) | Speedup |
|---|---:|---:|---:|---:|---:|
| `many_tables_10mb` | 562.07 ms | 17.8 MB/s | **37.11 ms** | **269.5 MB/s** | **15.15x** |
| `mixed_10mb` | 257.35 ms | 38.9 MB/s | **26.33 ms** | **379.7 MB/s** | **9.77x** |
| `inline_nested_10mb` | 489.40 ms | 20.4 MB/s | **53.14 ms** | **188.2 MB/s** | **9.21x** |
| `strings_plain_10mb` | 72.28 ms | 138.4 MB/s | **8.05 ms** | **1,242.4 MB/s** | **8.98x** |

### Generic UTF-8, Multiline & Lookup Throughput (`bench_lazy_generic.mojo`)

- `utf8_heavy`: **2,257 MB/s** Strict max | **3,293 MB/s** Trusted max | **502 MB/s** Parse+JSON max
- `multiline_comments`: **1,182 MB/s** Strict max | **1,263 MB/s** Trusted max | **253 MB/s** Parse+JSON max
- `lookup_4k` (`doc[k]` + `as_int()`): **16.75 ns/entry** | `children()` + `as_int()`: **3.5 ns/entry** | `to_toml()` (4k entries): **0.098 ms**

---

## Running Tests

All unit tests and spec compliance suites use Mojo's standard `TestSuite`:

```bash
# Run all unit and compliance tests
pixi run tests

# Run lazy reader unit tests
pixi run test-lazy-unit

# Run full TOML 1.1 compliance suite against the lazy reader
pixi run test-lazy-suite

# Run eager parser unit tests
pixi run test-parser

# Run eager parser TOML 1.1 compliance suite
pixi run test-toml-suite

# Run struct reflection tests
pixi run test-reflection
```

---

## License

This project is licensed under the Apache 2.0 License.
