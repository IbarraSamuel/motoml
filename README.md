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
  - `parse_toml` / `parse_toml_file` raise directly with `line:col` diagnostics; `take[T]()` errors include full field/index paths and `line:col` locations.
  - `try_parse_toml`, `try_take`, and `try_to_toml` return a linear `Result` for compile-time (`comptime`) serde or branch-based error handling.
- **Single 32-Byte `Toml` View & Full Bidirectional Serde**:
  - **Unchecked fast cast**: `val[Kind.Integer]`, `val[Kind.String]`, and zero-copy `val[Kind.Str]` (`StringSpan`, aborts on missing/mismatch).
  - **Checked extraction & compile-time reflection (`take[T]()`)**: `Int` / fixed-width integers (`Int8`..`Int64`, `UInt8`..`UInt64`, `Float32`), zero-copy `StringSpan[origin]`, `List[T]`, `Array[T, N]`, `Tuple[*Ts]`, `Set[T]`, `Dict[K, V]`, `Optional[T]`, `OneOf[...]`, `take[*Ts]()`, fieldless `__enum`s, untagged / externally / internally / adjacently tagged `__union`s, and Mojo structs.
  - **Zero-cost `@__annotation` schema customization (`toml_attr`)**: `kebab_case` / `rename_all(style)`, `rename`, `alias`, `default`, `default_init`, `skip`, `skip_if_empty`, `deny_unknown_fields`, `flatten` (nested structs & catch-all `Dict`), and union `tag` / `content`.
  - **High-throughput TOML 1.1 serialization (`to_toml` / `write_toml`)**: Two-pass buffered serializer emitting idiomatic TOML keys, `[sections]`, and `[[array_of_tables]]`.
  - **Zero-allocation iteration & streaming**: `eager_items()`, `items_span()`, `eager_keys()`, `keys_span()`, `write_string_to(w)`, and `write_key_to(w)` alongside `items()` and `keys()`.
  - **Exact temporals**: `Date`, `Time` (with exact integer `nanosecond` precision), `Offset`, and `DateTime`.
  - **First-class containers**: `TomlTable` and `TomlArray` with O(1) table lookup and O(1) flat array indexing across all modes (`doc["server"]["port"][Kind.Integer]`, `doc["users"][0]["name"][Kind.Str]`).
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

### Schema Annotations (`toml_attr`) & TOML Serialization (`to_toml`, `write_toml`)

Customize struct/enum/union reflection with zero runtime overhead via `@__annotation` and serialize Mojo values back to spec-compliant TOML 1.1:

```mojo
from std.collections import Dict
from motoml import parse_toml, to_toml, toml_attr

@__annotation(toml_attr.kebab_case)
__enum LogLevel(Copyable, Writable):
    case debug
    case warn_only

@__annotation(toml_attr.kebab_case, toml_attr.deny_unknown_fields)
@fieldwise_init
struct ServerManifest(Movable):
    var service_name: String
    @__annotation(toml_attr.default(8080), toml_attr.alias("port"))
    var bind_port: UInt16
    @__annotation(toml_attr.default(LogLevel.warn_only))
    var log_level: LogLevel
    var feature_flags: Dict[String, Bool]

def main() raises:
    var raw = """
    service-name = "edge-proxy"
    port = 9443

    [feature-flags]
    http3 = true
    """
    var manifest = parse_toml(raw).take[ServerManifest]()
    print(to_toml(manifest))
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
| `val[key]` / `val[index]` | `Toml` | O(1) table lookup or O(1) array element lookup |
| `val.get(key)` / `val.get(index)` | `Optional[Toml]` | Safe lookup returning `None` if absent |
| `key in val` | `Bool` | Table key membership check |
| `len(val)` | `Int` | O(1) child count for tables and arrays |
| `val[Kind.String]` | `String` | Unchecked decoded string (aborts on missing/mismatch) |
| `val[Kind.Str]` / `val.as_str()` | `StringSpan[origin]` | Zero-copy borrowed UTF-8 span (`as_str()` in `Mode.Eager`; `Kind.Str` on all `Eager` or unescaped/literal lazy strings) |
| `val[Kind.Integer]` | `Int` | Unchecked `Int` (aborts on missing/mismatch) |
| `val[Kind.Float]` | `Float64` | Unchecked IEEE-754 `Float64` including `nan`/`inf`/`-inf` |
| `val[Kind.Boolean]` | `Bool` | Unchecked `Bool` |
| `val[Kind.Date]` / `Time` / `DateTime` | `Date` / `Time` / `DateTime` | Unchecked temporal value |
| `val[Kind.Table]` / `val[Kind.Array]` | `TomlTable` / `TomlArray` | Narrow view to typed table or array wrapper |
| `val.take[T]()` / `val.try_take[T]()` | `T` / `Result[T]` | Checked extraction into scalar, fixed-width int/float, `StringSpan`, temporal, `List`, `Array`, `Tuple`, `Set`, `Dict`, `Optional`, `OneOf`, `__enum`, `__union`, or struct `T` |
| `to_toml(v)` / `write_toml(v, w)` / `try_to_toml(v)` | `String` / `None` / `Result[String]` | Serialize a struct, `Dict`, or table-valued `__union` to TOML 1.1 |
| `val.string_span()` / `val.key_span()` | `Optional[StringSpan]` | Zero-copy borrowed UTF-8 span if contiguous (always available in `Mode.Eager`) |
| `val.key()` / `val.key_str()` | `String` / `StringSpan` | Decoded node key (`key_str()` zero-copy in `Mode.Eager`) |
| `val.write_string_to(w)` / `write_key_to(w)` | `None raises` | Stream decoded string or key directly to `Writer` without heap allocation |
| `val.items_span()` / `val.eager_items()` | Iterator | Zero-allocation table `(key_span, value)` iterators (`items()` / `keys()` also available) |
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
    ├── attr.mojo        # Schema annotations (toml_attr, CaseStyle)
    ├── kind.mojo        # KindTag and compile-time Kind tokens
    ├── tempo.mojo       # Date, Time (nanosecond), Offset, DateTime
    ├── one_of.mojo      # Reflectable Variant wrapper (OneOf)
    ├── reflection.mojo  # Struct/tuple/array/union/dict & error-path helpers
    ├── ser.mojo         # Buffered two-pass TOML 1.1 serializer (to_toml, write_toml)
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
| `strings_plain` | Tuned | **2,457 MB/s** | **3,049 MB/s** | **2,257 MB/s** | **1,136 MB/s** |
| `array_of_tables` | Tuned | **833 MB/s** | **1,052 MB/s** | **749 MB/s** | **410 MB/s** |
| `many_tables` | Tuned | **810 MB/s** | **867 MB/s** | **698 MB/s** | **443 MB/s** |
| `mixed` | Tuned | **760 MB/s** | **797 MB/s** | **570 MB/s** | **375 MB/s** |
| `huge_table` | Tuned | **759 MB/s** | **801 MB/s** | **683 MB/s** | **442 MB/s** |
| `dates` | Tuned | **734 MB/s** | **752 MB/s** | **608 MB/s** | **479 MB/s** |
| `strings_escaped` | Tuned | **694 MB/s** | **889 MB/s** | **403 MB/s** | **313 MB/s** |
| `ints_floats` | Tuned | **605 MB/s** | **622 MB/s** | **426 MB/s** | **252 MB/s** |
| `inline_nested` | Tuned | **556 MB/s** | **614 MB/s** | **467 MB/s** | **289 MB/s** |
| `dotted_keys` | Tuned | **524 MB/s** | **538 MB/s** | **482 MB/s** | **370 MB/s** |
| `realworld_lock` | Hold-Out | **1,527 MB/s** | **1,752 MB/s** | **1,342 MB/s** | **768 MB/s** |
| `realworld_config` | Hold-Out | **1,027 MB/s** | **1,178 MB/s** | **791 MB/s** | **580 MB/s** |
| `toml_test_concat` | Hold-Out | **867 MB/s** | **1,057 MB/s** | **661 MB/s** | **484 MB/s** |

### Access, Iteration & Reflection (`pixi run bench-generic`)

- **4k-key lookup + integer read** (`doc[k][Kind.Integer]`): **12.75 ns/entry** (Strict) | **8.5 ns/entry** (Eager)
- **Child iteration + integer read**: **2.75 ns/entry** (Strict) | **2.0 ns/entry** (Eager)
- **Array index (`arr[i][Kind.Integer]`)**: **3.0 ns/elem** (Strict) | **0.5 ns/elem** (Eager)
- **Struct reflection (`parse_toml` + `take[Struct]()`)**: **140 ns/call** (Strict) | **210 ns/call** (Eager)

See [DESIGN.md](DESIGN.md) for architectural details, memory layouts, invariants, and sanitizer verification.

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

---

## Python Package

`motoml` is also exposed as a root Python package backed by a native Mojo CPython extension (`python/motoml/_motoml.so`), built automatically via Hatchling (`hatch_build.py`).

### Installation

By default, the Python package only depends on **`mojo-compiler`**. Install the optional **`[max]`** (or **`[gpu]`**) extra to enable `GpuTomlParser`:

```bash
# CPU-only (mojo-compiler only)
python -m pip install .

# With MAX GPU acceleration (mojo-compiler + max-core)
python -m pip install ".[max]"

# Or with uv (local development & pytest)
uv sync --no-install-project --group dev --group test
uv run --no-build-isolation --reinstall-package motoml --group dev --group test pytest

# With MAX GPU support in uv
uv sync --no-install-project --extra max --group dev --group test
uv run --no-build-isolation --reinstall-package motoml --extra max --group dev --group test pytest
```

### Python Quickstart

```python
import decimal
import motoml

# 1. Drop-in `tomllib`-compatible API (accepts str, bytes, bytearray; GIL-released parsing)
data = motoml.loads('title = "motoml"\nprice = 19.99\n', parse_float=decimal.Decimal)
cfg = motoml.load_file("config.toml")  # zero-copy mmap in Mojo

# 2. Lazy native document & views (O(1) lookups without materializing the full dict)
doc = motoml.parse_file("config.toml")
port = doc["server"]["port"]       # native int
server_dict = doc["server"].to_dict()
tagged_json = doc.to_json()

# 3. Spec-compliant TOML 1.1 serialization
text = motoml.dumps({"server": {"host": "127.0.0.1", "port": 8080}})

# 4. Fast validation & tagged JSON (100% Mojo, GIL released)
motoml.validate(text)
json_str = motoml.to_tagged_json(text)

# 5. Optional MAX GPU acceleration (when installed with `motoml[max]`)
if motoml.has_gpu():
    gpu = motoml.GpuTomlParser()
    docs = gpu.parse_batch(['a = 1\n', 'b = 2\n'])
```

---

## License

This project is licensed under the Apache 2.0 License.
