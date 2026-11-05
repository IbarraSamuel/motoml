# motoml

Fast, fully compliant TOML 1.1 reader and parser for Mojo.

`motoml` provides two complementary parsing engines designed for different workloads:
1. **Lazy TOML Reader (`motoml.lazy`)**: A high-performance, zero/low-allocation parser operating over borrowed byte spans (`Span[Byte]`). Uses a flat node tape and on-demand decoding to achieve **2x to 6.5x faster throughput** (up to 240+ MB/s).
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
| `val.key_slice()` | `StringSlice` | Returns the key name as a borrowed string slice |
| `val.as_slice()` | `Optional[StringSlice]` | Zero-copy borrowed string slice (returns `None` if escaped) |
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

Measured with Mojo `1.3.0` on Apple Silicon (macOS):

### 1 MB Synthetic Corpora

| Corpus | Old Eager Parser (ms) | Old Eager Parser (MB/s) | Lazy Strict (ms) | Lazy Strict (MB/s) | Speedup (Strict) | Lazy Trusted (MB/s) | Speedup (Trusted) |
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

| Corpus | Old Eager Parser (ms) | Old Eager Parser (MB/s) | Lazy Strict (ms) | Lazy Strict (MB/s) | Speedup |
|---|---:|---:|---:|---:|---:|
| `many_tables_10mb` | 811.31 ms | 12.3 MB/s | **123.68 ms** | **80.9 MB/s** | **6.56x** |
| `inline_nested_10mb` | 688.87 ms | 14.5 MB/s | **165.27 ms** | **60.5 MB/s** | **4.17x** |
| `mixed_10mb` | 348.89 ms | 28.7 MB/s | **100.43 ms** | **99.6 MB/s** | **3.47x** |
| `strings_plain_10mb` | 120.01 ms | 83.3 MB/s | **47.08 ms** | **212.4 MB/s** | **2.55x** |

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
