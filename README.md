# motoml

Fast, fully compliant TOML 1.1 parser and view API for Mojo.

`motoml` uses a single high-performance flat-tape parser and exposes `Toml` as a lightweight 32-byte value view over the parsed document, parameterized by `Mode`:

- **Lazy modes (zero/low allocation, default `Mode.Strict`)**: Borrow directly from the source `StringSpan` or memory-mapped file and decode scalars, temporals, and escapes on demand (**up to 2,597 MB/s Strict** and **3,048 MB/s Trusted**).
  - `Mode.Strict` (default): Full TOML 1.1 compliance (UTF-8, duplicate keys, escape rules, lexical scalar validation).
  - `Mode.Lexical`: UTF-8 and lexical/scalar validation without hash-index duplicate checks.
  - `Mode.Structure`: Duplicate-key and table-redefinition checks without UTF-8 or scalar lexical overhead.
  - `Mode.Trusted`: Maximum throughput on trusted inputs by compiling out validation checks.
- **Eager mode (`Mode.Eager`)**: Parses with `Mode.Strict` validation, then materializes decoded strings, keys, scalars, arrays, and temporals into compact owned storage so documents outlive the source buffer and reads become O(1) loads (**3.6x–22.8x faster than legacy AST parsing**, up to **2,293 MB/s**).

---

## Features

- **Full TOML 1.1 Compliance**: Passes all 712 official `toml-test` 1.1.0 cases in both `Mode.Strict` and `Mode.Eager`, and all 218 valid cases across `Mode.Lexical`, `Mode.Structure`, and `Mode.Trusted`.
- **Single `Toml` View API**:
  - **Kind-based casting**: Unchecked `val[Kind.Integer]` (aborts on missing/mismatch) and checked `val.take[Kind.Integer]()` (raises on missing/mismatch). Spec-strict types (integers are only readable via `Kind.Integer`, floats via `Kind.Float`).
  - **First-class containers**: `Kind.Table` yields `TomlTable`, `Kind.Array` yields `TomlArray`, alongside direct indexing (`doc["server"]["port"][Kind.Integer]`, `doc["users"][0]["name"][Kind.String]`).
  - **Compile-time struct reflection**: `doc.take[MyStruct]()` deserializes tables directly into native Mojo structs (`Int`, `Float64`, `Bool`, `String`, `Date`, `Time`, `DateTime`, `List[T]`, `Optional[T]`, and nested structs).
- **Zero-Copy File Parsing (`parse_toml_file`)**: Returns an owning `TomlFile[mode]` backed by `MappedFile` (released immediately after materialization in `Mode.Eager`).

---

## Installation & Setup

`motoml` is managed with [Pixi](https://pixi.sh).

```bash
# Clone the repository
git clone https://github.com/mojoto/motoml.git
cd motoml

# Precompile package
pixi run package

# Run all test suites
pixi run tests
```

---

## Quickstart

```mojo
from motoml import parse_toml, parse_toml_file, Mode, Kind, KindTag

def main() raises:
    var src = """
    title = "motoml"
    [server]
    host = "127.0.0.1"
    port = 8080
    [[users]]
    name = "alice"
    """

    # 1. Parse with default lazy Mode.Strict (borrows `src`)
    var doc = parse_toml(src).take()

    # 2. Index and cast by Kind
    var title = doc["title"][Kind.String]
    var port = doc["server"]["port"].take[Kind.Integer]()  # checked, raises on error

    # 3. Zero-copy unescaped string slice (always succeeds in Mode.Eager)
    if var host = doc["server"]["host"].string_span():
        print("Host:", host.value())

    # 4. Iterate arrays and tables
    for user in doc["users"]:
        print("User:", user["name"][Kind.String])

    for (k, v) in doc["server"].items():
        print(k, v.kind())

    # 5. Parse eagerly into an owned document (no lifetime dependency on `src`)
    var eager_doc = parse_toml[Mode.Eager](src).take()
    print(eager_doc["title"][Kind.String])

    # 6. Memory-mapped file parsing
    var cfg = parse_toml_file("config.toml")
    print(cfg["title"][Kind.String])
```

### Struct Reflection

```mojo
from motoml import parse_toml

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
    var doc = parse_toml(toml_str).take()
    var config = doc.take[ServerConfig]()
    print(config.host, config.port, config.enabled)
```

---

## `Toml` View & `Kind` API

| Method / Operator | Return Type | Description |
|---|---|---|
| `val.kind()` | `KindTag` | Dynamic tag (`String`, `Integer`, `Float`, `Boolean`, `Date`, `Time`, `DateTime`, `Array`, `Table`, `Missing`) |
| `val.is_kind[Kind.X]()` | `Bool` | Compile-time parameterized kind check |
| `val.is_missing()` / `Bool(val)` | `Bool` | Check whether a key/index lookup succeeded |
| `val[key]` / `val[index]` | `Toml` | $O(1)$ table lookup or array element lookup ($O(1)$ in Eager, $O(i)$ in lazy) |
| `val.get(key)` / `val.get(index)` | `Optional[Toml]` | Safe lookup returning `None` if absent |
| `key in val` | `Bool` | Table key membership check |
| `len(val)` | `Int` | $O(1)$ child count for tables and arrays |
| `val[Kind.String]` | `String` | Extract decoded string (aborts on missing/mismatch) |
| `val[Kind.Integer]` | `Int` | Extract `Int` (aborts on missing/mismatch) |
| `val[Kind.Float]` | `Float64` | Extract `Float64` including `nan`/`inf`/`-inf` (aborts on missing/mismatch) |
| `val[Kind.Boolean]` | `Bool` | Extract `Bool` (aborts on missing/mismatch) |
| `val[Kind.Date]` / `Time` / `DateTime` | `Date` / `Time` / `DateTime` | Extract temporal value (aborts on missing/mismatch) |
| `val[Kind.Table]` / `val[Kind.Array]` | `TomlTable` / `TomlArray` | Narrow view to typed table or array wrapper |
| `val.take[Kind.X]()` | `KindPayload[X]` | Checked extraction (raises on missing, mismatch, or invalid lazy scalar) |
| `val.take[T]()` | `T` | Reflection-based deserialization into scalar, `List`, `Optional`, or struct `T` |
| `val.string_span()` | `Optional[StringSpan]` | Zero-copy borrowed UTF-8 span if contiguous (always available in `Mode.Eager`) |
| `val.to_json(writer)` | `None raises` | Stream `toml-test` tagged JSON directly to any `Writer` |

> [!NOTE]
> In lazy modes (`Mode.Strict`, `Mode.Lexical`, `Mode.Structure`, `Mode.Trusted`), `TomlDocument` borrows the input `StringSpan` — keep the source buffer (or `TomlFile`) alive while using the document. In `Mode.Eager`, the source buffer can be freed immediately after `parse_toml[Mode.Eager]` returns.

---

## Benchmarks

Measured with Mojo `1.3` on Apple Silicon (macOS):

### 1 MB Synthetic & Hold-Out Corpora (`pixi run bench-lazy`, 15 runs median)

| Corpus | Set | Strict (MB/s) | Trusted (MB/s) | Eager (MB/s) | Parse + `to_json` (MB/s) |
|---|---|---:|---:|---:|---:|
| `strings_plain` | Tuned | **2,597 MB/s** | **3,048 MB/s** | **2,293 MB/s** | **1,377 MB/s** |
| `array_of_tables` | Tuned | **831 MB/s** | **881 MB/s** | **673 MB/s** | **442 MB/s** |
| `huge_table` | Tuned | **783 MB/s** | **744 MB/s** | **659 MB/s** | **523 MB/s** |
| `dates` | Tuned | **752 MB/s** | **773 MB/s** | **631 MB/s** | **450 MB/s** |
| `strings_escaped` | Tuned | **729 MB/s** | **973 MB/s** | **392 MB/s** | **372 MB/s** |
| `mixed` | Tuned | **701 MB/s** | **735 MB/s** | **497 MB/s** | **356 MB/s** |
| `ints_floats` | Tuned | **629 MB/s** | **640 MB/s** | **411 MB/s** | **219 MB/s** |
| `many_tables` | Tuned | **573 MB/s** | **585 MB/s** | **498 MB/s** | **388 MB/s** |
| `dotted_keys` | Tuned | **477 MB/s** | **483 MB/s** | **421 MB/s** | **394 MB/s** |
| `inline_nested` | Tuned | **436 MB/s** | **463 MB/s** | **348 MB/s** | **302 MB/s** |
| `realworld_lock` | Hold-Out | **1,631 MB/s** | **1,802 MB/s** | **1,274 MB/s** | **891 MB/s** |
| `realworld_config` | Hold-Out | **952 MB/s** | **1,044 MB/s** | **716 MB/s** | **560 MB/s** |
| `toml_test_concat` | Hold-Out | **707 MB/s** | **789 MB/s** | **488 MB/s** | **453 MB/s** |

### Access, Iteration & Reflection (`bench_lazy_generic.mojo`)

- **4k-key lookup + integer read** (`doc[k][Kind.Integer]`): **15.25 ns/entry** (Strict) | **14.25 ns/entry** (Eager)
- **Child iteration + integer read**: **3.5 ns/entry** (Strict) | **2.0 ns/entry** (Eager)
- **Array index (`arr[i][Kind.Integer]`)**: **0.5 ns/elem** (Eager)
- **Struct reflection (`parse_toml` + `take[Struct]()`)**: **310 ns/call** (Strict) | **390 ns/call** (Eager)

---

## Running Tests

All unit tests and spec compliance suites use Mojo's standard `TestSuite`:

```bash
# Run all unit, compliance, comptime, and reflection suites
pixi run tests

# Individual suites
pixi run test-toml-type
pixi run test-parser
pixi run test-toml-suite
pixi run test-lazy-unit
pixi run test-comptime-parser
pixi run test-reflection
```

---

## License

This project is licensed under the Apache 2.0 License.
