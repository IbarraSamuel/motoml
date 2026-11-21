# motoml

Fast, spec-compliant TOML 1.1 parser and view API for Mojo.

`motoml` uses a single flat-tape parser (`src/tape/`) and exposes `Toml` as a lightweight 32-byte value view over the parsed document, parameterized by `Mode`:

- **`Mode.Strict` (default)**: Lazy zero-copy borrowing parser with full TOML 1.1 compliance (UTF-8, duplicate keys, escape rules, lexical/range scalar validation, `line:col` parse errors).
- **`Mode.Eager`**: Parses with `Mode.Strict` validation, then materializes decoded strings, keys, scalars, arrays, and temporals into compact owned storage so documents outlive the source buffer with O(1) scalar loads and array indexing.
- **`Mode.Trusted`**: Lazy zero-copy parser skipping parse-time validation for maximum throughput on trusted inputs (checked on demand via `take[T]()`).

---

## Features

- **Full TOML 1.1 Compliance**: Passes all 712 official `toml-test` 1.1.0 cases in both `Mode.Strict` and `Mode.Eager`, and all 218 valid cases in `Mode.Trusted`.
- **Idiomatic Error Handling**:
  - `parse_toml` / `parse_toml_file` raise directly with `line:col` diagnostics.
  - `try_parse_toml` returns a linear `Result` for compile-time parsing (`comptime`) or branch-based error handling.
- **Single 32-Byte `Toml` View API**:
  - **Unchecked fast cast**: `val[Kind.Integer]` (aborts on missing/mismatch).
  - **Checked extraction & compile-time reflection**: `val.take[Int]()`, `val.take[List[T]]()`, `val.take[MyStruct]()`, `val.take[OneOf[...]]()`, `val.take[*Ts]()`, and single-payload `__union` types.
  - **Exact temporals**: `Date`, `Time` (with exact integer `nanosecond` precision), `Offset`, and `DateTime`.
  - **First-class containers**: `TomlTable` and `TomlArray`, alongside direct chaining (`doc["server"]["port"][Kind.Integer]`, `doc["users"][0]["name"][Kind.String]`).
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
from motoml import Kind, parse_toml

def main() raises:
    var src = """
    title = "api-gateway"

    [server]
    host = "127.0.0.1"
    port = 8080

    [[routes]]
    path = "/health"
    auth = false

    [[routes]]
    path = "/v1/users"
    auth = true
    """

    # Parse with default lazy Mode.Strict (borrows `src`, full TOML 1.1 validation)
    var doc = parse_toml(src)

    # Checked extraction (raises on missing key or kind mismatch)
    var title = doc["title"].take[String]()
    var port = doc["server"]["port"].take[Int]()

    # Unchecked fast cast (aborts on missing/mismatch)
    var host = doc["server"]["host"][Kind.String]
    print(title, host, port)

    # Safe lookups and missing-chain propagation
    if "server" in doc and doc["server"].get("port"):
        print("Server port is configured")
    if doc["missing"]["nested"][0].is_missing():
        print("Missing chains safely evaluate to KindTag.Missing")

    # Iterate arrays and table entries in document order
    for route in doc["routes"]:
        print("Route:", route["path"][Kind.String], "auth:", route["auth"][Kind.Boolean])

    for key, val in doc["server"].items():
        print(key, "->", val.kind())
```

---

## Examples

### Struct & Nested Reflection (`take[T]()`)

Deserialize TOML tables directly into Mojo structs—including nested structs, `List[T]` (and `[[array_of_tables]]`), and `Optional[T]` for absent keys:

```mojo
from std.collections import List, Optional
from motoml import parse_toml

struct RouteConfig(Movable):
    var path: String
    var auth: Bool
    var timeout_ms: Optional[Int]

struct ServerConfig(Movable):
    var host: String
    var port: Int
    var tls: Optional[Bool]

struct AppConfig(Movable):
    var title: String
    var tags: List[String]
    var server: ServerConfig
    var routes: List[RouteConfig]

def main() raises:
    var src = """
    title = "api-gateway"
    tags = ["edge", "prod"]

    [server]
    host = "0.0.0.0"
    port = 8443

    [[routes]]
    path = "/health"
    auth = false

    [[routes]]
    path = "/v1/orders"
    auth = true
    timeout_ms = 2500
    """

    var config = parse_toml(src).take[AppConfig]()
    print(config.title, config.server.host, config.server.port)
    print("TLS configured:", Bool(config.server.tls))
    print("Order timeout (ms):", config.routes[1].timeout_ms.value())
```

### Unions & Polymorphic Values (`OneOf`, `__union`, `take[*Ts]()`)

Handle heterogeneous TOML fields using `OneOf[...]` inside structs, single-payload `__union` enums, or ad-hoc `val.take[*Ts]()` returning a `Variant`:

```mojo
from std.collections import List
from motoml import OneOf, parse_toml

struct TcpTarget(Copyable, Movable):
    var host: String
    var port: Int

struct UnixTarget(Copyable, Movable):
    var socket: String

__union Upstream(Copyable, Movable):
    case tcp(TcpTarget)
    case unix(UnixTarget)

struct GatewayConfig(Movable):
    var listen: OneOf[Int, String]
    var upstreams: List[Upstream]

def main() raises:
    var src = """
    listen = 8080
    upstreams = [
        { host = "10.0.0.1", port = 9000 },
        { socket = "/var/run/backend.sock" },
    ]
    """

    var doc = parse_toml(src)
    var cfg = doc.take[GatewayConfig]()

    if cfg.listen.isa[Int]():
        print("Listening on port:", cfg.listen[Int])

    for upstream in cfg.upstreams:
        if case .tcp(t) = upstream:
            print("TCP upstream:", t.host, t.port)
        elif case .unix(u) = upstream:
            print("Unix upstream:", u.socket)

    # Ad-hoc multi-type extraction without defining a wrapper struct
    var port_or_addr = doc["listen"].take[Int, String]()
    print("Matched Int:", port_or_addr.isa[Int]())
```

### Exact Temporals (`Date`, `Time`, `DateTime`)

RFC 3339 / TOML 1.1 dates, times (with nanosecond precision), and offset/local datetimes map to first-class `Date`, `Time`, and `DateTime` structs:

```mojo
from motoml import Date, DateTime, Time, parse_toml

def main() raises:
    var src = """
    release_date = 2026-11-21
    cutoff_time = 14:30:00.125
    deployed_at = 2026-11-21T08:30:00-05:00
    """

    var doc = parse_toml(src)
    var d = doc["release_date"].take[Date]()
    var t = doc["cutoff_time"].take[Time]()
    var dt = doc["deployed_at"].take[DateTime]()

    print("Date:", String(d))
    print("Time nanoseconds:", t.nanosecond)
    print("Deployed:", String(dt))
```

### Parsing Modes & Lifetimes (`Strict`, `Eager`, `Trusted`)

Pick the mode that fits your lifetime and validation requirements:

```mojo
from motoml import Mode, TomlDocument, parse_toml

def load_owned_config(var raw_toml: String) raises -> TomlDocument[Mode.Eager]:
    # Strict validation + materialized owned arena; `raw_toml` can be dropped immediately
    var doc = parse_toml[Mode.Eager](raw_toml)
    _ = raw_toml^
    return doc^

def main() raises:
    # Mode.Eager: document outlives the source buffer and string_span() always succeeds
    var eager_doc = load_owned_config(String('greeting = "hello\\nworld"\n'))
    if case .Some(span) = eager_doc["greeting"].string_span():
        print(span)

    # Mode.Trusted: skips parse-time validation for maximum throughput on trusted inputs
    var trusted_doc = parse_toml[Mode.Trusted]("workers = 16\n")
    print("Workers:", trusted_doc["workers"].take[Int]())
```

### Memory-Mapped Files & Tagged JSON (`parse_toml_file`, `to_json`)

```mojo
from motoml import Kind, Mode, parse_toml_file

def main() raises:
    # Zero-copy memory-mapped file (borrows mmap until `cfg` drops)
    var cfg = parse_toml_file("config.toml")
    print(cfg["service"][Kind.String])

    # Stream `toml-test` tagged JSON to any Writer
    var json_out = String()
    cfg.to_json(json_out)
    print(json_out)

    # Eager mode materializes into owned storage and unmaps the file immediately
    var owned = parse_toml_file[Mode.Eager]("config.toml")
    print(owned["service"][Kind.String])
```

### Non-Raising `Result` & `comptime` Parsing (`try_parse_toml`)

Use `try_parse_toml` for branch-based error handling with `line:col` diagnostics, fallback defaults, or compile-time (`comptime`) config validation:

```mojo
from motoml import Kind, Mode, parse_toml, try_parse_toml

comptime EMBEDDED_CONFIG = """
[app]
name = "motoml"
workers = 4
"""

def main() raises:
    # 1. Parse and validate TOML at compile time
    comptime PARSED = try_parse_toml[Mode.Eager](EMBEDDED_CONFIG)
    var comptime_doc = materialize[PARSED]().take()
    print("Workers:", comptime_doc["app"]["workers"][Kind.Integer])

    # 2. Non-raising error handling with line:col diagnostics
    var res = try_parse_toml("port = 8080\nport = 9090\n")
    if res.is_ok():
        var doc = res^.unsafe_take_value()
        print("Port:", doc["port"][Kind.Integer])
    else:
        var err = res^.unsafe_take_error()
        print("Parse error:", err)  # includes `2:1` location

    # 3. Provide a fallback document on parse failure
    var defaults = parse_toml[Mode.Eager]("workers = 1\n")
    var cfg = try_parse_toml[Mode.Eager]("workers = [invalid").or_else(defaults^)
    print("Fallback workers:", cfg["workers"][Kind.Integer])
```

---

## `Toml` View & Extraction API

| Method / Operator | Return Type | Description |
|---|---|---|
| `val.kind()` | `KindTag` | Dynamic tag (`String`, `Integer`, `Float`, `Boolean`, `Date`, `Time`, `DateTime`, `Array`, `Table`, `Missing`) |
| `val.is_kind[Kind.X]()` | `Bool` | Compile-time parameterized kind check |
| `val.is_missing()` / `Bool(val)` | `Bool` | Check whether a key/index lookup succeeded |
| `val[key]` / `val[index]` | `Toml` | O(1) table lookup or array element lookup (O(1) in Eager, O(i) in lazy) |
| `val.get(key)` / `val.get(index)` | `Optional[Toml]` | Safe lookup returning `None` if absent |
| `key in val` | `Bool` | Table key membership check |
| `len(val)` | `Int` | O(1) child count for tables and arrays |
| `val[Kind.String]` | `String` | Unchecked decoded string (aborts on missing/mismatch) |
| `val[Kind.Integer]` | `Int` | Unchecked `Int` (aborts on missing/mismatch) |
| `val[Kind.Float]` | `Float64` | Unchecked IEEE-754 `Float64` including `nan`/`inf`/`-inf` |
| `val[Kind.Boolean]` | `Bool` | Unchecked `Bool` |
| `val[Kind.Date]` / `Time` / `DateTime` | `Date` / `Time` / `DateTime` | Unchecked temporal value |
| `val[Kind.Table]` / `val[Kind.Array]` | `TomlTable` / `TomlArray` | Narrow view to typed table or array wrapper |
| `val.take[T]()` | `T` | Checked extraction / reflection into scalar, temporal, container, `List`, `Optional`, `OneOf`, `__union`, or struct `T` |
| `val.string_span()` / `val.key_span()` | `Optional[StringSpan]` | Zero-copy borrowed UTF-8 span if contiguous (always available in `Mode.Eager`) |
| `val.to_json(writer)` | `None raises` | Stream `toml-test` tagged JSON directly to any `Writer` |

> [!NOTE]
> In lazy modes (`Mode.Strict`, `Mode.Trusted`), `TomlDocument` borrows the input `StringSpan` — keep the source buffer (or `TomlFile`) alive while using the document. In `Mode.Eager`, the source buffer can be freed immediately after `parse_toml[Mode.Eager]` returns.

---

## Project Layout

```text
src/
├── __init__.mojo        # Public re-exports
├── mode.mojo            # Mode.Strict, Mode.Eager, Mode.Trusted
├── parser.mojo          # parse_toml, try_parse_toml, parse_toml_file, TomlFile
├── result.mojo          # Linear Result[T, E] and internal ScalarResult[T]
├── mmap_file.mojo       # Read-only memory-mapped file handle
├── tape/                # Flat-tape parsing engine (shared by all modes)
│   ├── node.mojo        # 32-byte Node, NodeKind, NodeFlags, KeySeg
│   ├── key_index.mojo   # Open-addressing hash index for O(1) lookup & dup checks
│   ├── lexer.mojo       # SIMD UTF-8, whitespace/comment, and scalar scanners
│   ├── decode.mojo      # Unified scalar & string escape validators/decoders
│   └── reader.mojo      # Stateful flat-tape parser with cold line:col errors
└── types/               # Public value types, views, ownership, and codecs
    ├── kind.mojo        # KindTag and compile-time Kind tokens
    ├── tempo.mojo       # Date, Time (nanosecond), Offset, DateTime
    ├── one_of.mojo      # Reflectable Variant wrapper (OneOf)
    ├── reflection.mojo  # Struct/union/variant reflection helpers
    ├── store.mojo       # Backing store and arena writer
    ├── json.mojo        # SIMD JSON escaping and tagged JSON streaming
    ├── view.mojo        # Toml, TomlTable, TomlArray, and iterators
    └── document.mojo    # TomlDocument owner and Mode.Eager materialization
```

---

## Benchmarks

Measured with Mojo `1.3` on Apple Silicon (macOS):

### 1 MB Synthetic & Hold-Out Corpora (`pixi run bench-lazy`, 15 runs median)

| Corpus | Set | Strict (MB/s) | Trusted (MB/s) | Eager (MB/s) | Parse + `to_json` (MB/s) |
|---|---|---:|---:|---:|---:|
| `strings_plain` | Tuned | **2,577 MB/s** | **3,115 MB/s** | **2,278 MB/s** | **1,362 MB/s** |
| `array_of_tables` | Tuned | **839 MB/s** | **938 MB/s** | **680 MB/s** | **441 MB/s** |
| `huge_table` | Tuned | **783 MB/s** | **798 MB/s** | **667 MB/s** | **518 MB/s** |
| `dates` | Tuned | **765 MB/s** | **802 MB/s** | **636 MB/s** | **469 MB/s** |
| `strings_escaped` | Tuned | **722 MB/s** | **951 MB/s** | **390 MB/s** | **366 MB/s** |
| `mixed` | Tuned | **678 MB/s** | **747 MB/s** | **484 MB/s** | **345 MB/s** |
| `ints_floats` | Tuned | **620 MB/s** | **662 MB/s** | **404 MB/s** | **215 MB/s** |
| `many_tables` | Tuned | **567 MB/s** | **589 MB/s** | **491 MB/s** | **382 MB/s** |
| `dotted_keys` | Tuned | **479 MB/s** | **496 MB/s** | **422 MB/s** | **395 MB/s** |
| `inline_nested` | Tuned | **404 MB/s** | **445 MB/s** | **330 MB/s** | **284 MB/s** |
| `realworld_lock` | Hold-Out | **1,600 MB/s** | **1,828 MB/s** | **1,264 MB/s** | **873 MB/s** |
| `realworld_config` | Hold-Out | **899 MB/s** | **1,024 MB/s** | **680 MB/s** | **539 MB/s** |
| `toml_test_concat` | Hold-Out | **667 MB/s** | **778 MB/s** | **465 MB/s** | **440 MB/s** |

### Access, Iteration & Reflection (`pixi run bench-generic`)

- **4k-key lookup + integer read** (`doc[k][Kind.Integer]`): **20.75 ns/entry** (Strict) | **14.5 ns/entry** (Eager)
- **Child iteration + integer read**: **3.75 ns/entry** (Strict) | **2.0 ns/entry** (Eager)
- **Array index (`arr[i][Kind.Integer]`)**: **0.5 ns/elem** (Eager)
- **Struct reflection (`parse_toml` + `take[Struct]()`)**: **260 ns/call** (Strict) | **340 ns/call** (Eager)

---

## Running Tests & Fuzzing

All unit tests and spec compliance suites use Mojo's standard `TestSuite`:

```bash
# Run all unit, strict-spec, view, reflection, comptime, and toml-test suites
pixi run tests

# Individual suites
pixi run test-parsing
pixi run test-strict-spec
pixi run test-views-and-types
pixi run test-reflection
pixi run test-comptime
pixi run test-toml-suite

# Differential & mutation fuzzer against Python tomllib (auto-builds binary)
pixi run fuzz-lazy

# Benchmarks
pixi run bench-lazy
pixi run bench-generic
```

---

## License

This project is licensed under the Apache 2.0 License.
