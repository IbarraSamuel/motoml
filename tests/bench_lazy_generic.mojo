"""Generic (non-bench-corpus) benchmarks: UTF-8, multiline/comments, query & decode."""

from std.time import perf_counter_ns
from motoml import parse_toml, to_toml, toml_attr, Mode, Kind


def make_utf8_heavy_doc(n_entries: Int) -> String:
    var s = String(capacity_bytes=n_entries * 72)
    s += "# Header café 🚀\n"
    for i in range(n_entries):
        s += (
            "entry_"
            + String(i)
            + ' = "Données utf-8 №'
            + String(i)
            + ' — 日本語テスト ✓"\n'
        )
    return s^


def make_multiline_comment_doc(n_entries: Int) -> String:
    var s = String(capacity_bytes=n_entries * 140)
    for i in range(n_entries):
        s += "# Section comment line for item " + String(i) + "\n"
        s += "[section_" + String(i) + "]\n"
        s += (
            'bio = """First line '
            + String(i)
            + '\\\n    indented continuation "quoted" end"""\n'
        )
        s += "score = " + String(Float64(i) * 1.25 + 0.5) + "\n"
        s += "ts = 2026-05-" + String(10 + (i % 18)) + "T12:34:56Z\n"
    return s^


def make_lookup_doc(n_entries: Int) -> String:
    var s = String(capacity_bytes=n_entries * 48)
    for i in range(n_entries):
        s += "k_" + String(i) + " = " + String(i * 13 + 7) + "\n"
    return s^


def make_array_doc(n_elems: Int) -> String:
    var s = String(capacity_bytes=n_elems * 10 + 16)
    s += "arr = ["
    for i in range(n_elems):
        if i > 0:
            s += ","
        s += String(i)
    s += "]\n"
    return s^


struct BenchConfig(Movable):
    var host: String
    var port: Int
    var ratio: Float64
    var enabled: Bool


struct ZeroCopyBenchConfig[origin: ImmOrigin](Movable):
    var host: StringSpan[Self.origin]
    var port: Int
    var ratio: Float64
    var enabled: Bool


@__annotation(toml_attr.kebab_case, toml_attr.deny_unknown_fields)
@fieldwise_init
struct AnnotatedBenchConfig(Movable):
    var bind_host: String

    @__annotation(toml_attr.default(8080))
    var bind_port: Int
    var sample_ratio: Float64
    var tls_enabled: Bool


def bench_parse(name: String, content: String, runs: Int = 15) raises:
    var mb = Float64(content.byte_length()) / 1e6

    var d0 = parse_toml[Mode.Strict](content)
    var j0 = String(capacity_bytes=content.byte_length() * 2)
    d0.to_json(j0)
    _ = j0.byte_length()
    var d1 = parse_toml[Mode.Trusted](content)
    _ = len(d1)
    var d2 = parse_toml[Mode.Eager](content)
    _ = len(d2)

    var best_strict = Float64(1e18)
    var best_trusted = Float64(1e18)
    var best_eager = Float64(1e18)
    var best_json = Float64(1e18)

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Strict](content)
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_strict:
            best_strict = ms

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Trusted](content)
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_trusted:
            best_trusted = ms

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Eager](content)
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_eager:
            best_eager = ms

    for _ in range(runs):
        var out = String(capacity_bytes=content.byte_length() * 2)
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Strict](content)
        doc.to_json(out)
        var t1 = perf_counter_ns()
        _ = out.byte_length()
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_json:
            best_json = ms

    print(
        name,
        "| Strict max:",
        Int(mb / (best_strict / 1000.0)),
        "MB/s | Trusted max:",
        Int(mb / (best_trusted / 1000.0)),
        "MB/s | Eager max:",
        Int(mb / (best_eager / 1000.0)),
        "MB/s | Parse+JSON max:",
        Int(mb / (best_json / 1000.0)),
        "MB/s",
    )


def bench_lookup_and_decode() raises:
    var lookup_src = make_lookup_doc(4000)
    var lazy_doc = parse_toml[Mode.Strict](lookup_src)
    var eager_doc = parse_toml[Mode.Eager](lookup_src)
    var keys = List[String](capacity=4000)
    for i in range(4000):
        keys.append("k_" + String(i))

    var best_lazy_lookup_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for ref k in keys:
            acc += lazy_doc[k][Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_lazy_lookup_ns:
            best_lazy_lookup_ns = dt

    var best_eager_lookup_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for ref k in keys:
            acc += eager_doc[k][Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_eager_lookup_ns:
            best_eager_lookup_ns = dt

    var best_lazy_iter_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for child in lazy_doc:
            acc += child[Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_lazy_iter_ns:
            best_lazy_iter_ns = dt

    var best_eager_iter_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for child in eager_doc:
            acc += child[Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_eager_iter_ns:
            best_eager_iter_ns = dt

    var arr_src = make_array_doc(2000)
    var arr_lazy = parse_toml[Mode.Strict](arr_src)
    var arr_eager = parse_toml[Mode.Eager](arr_src)
    var lazy_arr_v = arr_lazy["arr"]
    var eager_arr_v = arr_eager["arr"]
    var best_eager_arr_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for i in range(2000):
            acc += eager_arr_v[i][Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_eager_arr_ns:
            best_eager_arr_ns = dt

    var best_lazy_arr_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for i in range(2000):
            acc += lazy_arr_v[i][Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_lazy_arr_ns:
            best_lazy_arr_ns = dt

    var best_alloc_items_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for k, v in eager_doc.items():
            acc += k.byte_length() + v[Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_alloc_items_ns:
            best_alloc_items_ns = dt

    var best_eager_items_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for k, v in eager_doc.eager_items():
            acc += k.byte_length() + v[Kind.Integer]
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_eager_items_ns:
            best_eager_items_ns = dt

    var cfg_src = (
        'host = "localhost"\nport = 8080\nratio = 0.75\nenabled = true\n'
    )
    var best_refl_lazy_ns = Int(1 << 60)
    var best_refl_eager_ns = Int(1 << 60)
    for _ in range(15):
        var t0 = perf_counter_ns()
        var acc = 0
        for _ in range(100):
            var d = parse_toml[Mode.Strict](cfg_src)
            var c = d.take[BenchConfig]()
            acc += c.port
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_refl_lazy_ns:
            best_refl_lazy_ns = dt

    for _ in range(15):
        var t0 = perf_counter_ns()
        var acc = 0
        for _ in range(100):
            var d = parse_toml[Mode.Eager](cfg_src)
            var c = d.take[BenchConfig]()
            acc += c.port
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_refl_eager_ns:
            best_refl_eager_ns = dt

    var best_zc_refl_ns = Int(1 << 60)
    for _ in range(15):
        var t0 = perf_counter_ns()
        var acc = 0
        for _ in range(100):
            var d = parse_toml[Mode.Strict](cfg_src)
            var c = d.take[ZeroCopyBenchConfig[ImmOrigin(origin_of(d))]]()
            acc += c.port + c.host.byte_length()
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_zc_refl_ns:
            best_zc_refl_ns = dt

    var ann_src = (
        'bind-host = "localhost"\nsample-ratio = 0.75\ntls-enabled = true\n'
    )
    var best_ann_refl_ns = Int(1 << 60)
    for _ in range(15):
        var t0 = perf_counter_ns()
        var acc = 0
        for _ in range(100):
            var d = parse_toml[Mode.Strict](ann_src)
            var c = d.take[AnnotatedBenchConfig]()
            acc += c.bind_port
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_ann_refl_ns:
            best_ann_refl_ns = dt

    var ser_cfg = AnnotatedBenchConfig(
        bind_host="localhost",
        bind_port=8080,
        sample_ratio=0.75,
        tls_enabled=True,
    )
    var best_to_toml_ns = Int(1 << 60)
    for _ in range(15):
        var t0 = perf_counter_ns()
        var acc = 0
        for _ in range(100):
            var s = to_toml(ser_cfg)
            acc += s.byte_length()
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_to_toml_ns:
            best_to_toml_ns = dt

    print(
        "Lazy lookup_4k:",
        Float64(best_lazy_lookup_ns) / 4000.0,
        "ns/entry | Eager lookup_4k:",
        Float64(best_eager_lookup_ns) / 4000.0,
        "ns/entry",
    )
    print(
        "Lazy iter:",
        Float64(best_lazy_iter_ns) / 4000.0,
        "ns/entry | Eager iter:",
        Float64(best_eager_iter_ns) / 4000.0,
        "ns/entry | Lazy arr[i]:",
        Float64(best_lazy_arr_ns) / 2000.0,
        "ns/elem | Eager arr[i]:",
        Float64(best_eager_arr_ns) / 2000.0,
        "ns/elem",
    )
    print(
        "Eager items() (String):",
        Float64(best_alloc_items_ns) / 4000.0,
        "ns/entry | eager_items() (StringSpan):",
        Float64(best_eager_items_ns) / 4000.0,
        "ns/entry",
    )
    print(
        "Reflection (100x parse+take[Struct]) Lazy:",
        Float64(best_refl_lazy_ns) / 100.0,
        "ns/call | Zero-copy Lazy:",
        Float64(best_zc_refl_ns) / 100.0,
        "ns/call | Eager:",
        Float64(best_refl_eager_ns) / 100.0,
        "ns/call",
    )
    print(
        "Annotated kebab+default+deny_unknown (parse+take):",
        Float64(best_ann_refl_ns) / 100.0,
        "ns/call | Struct to_toml():",
        Float64(best_to_toml_ns) / 100.0,
        "ns/call",
    )


def main() raises:
    print("=================== GENERIC BENCHMARKS ===================")
    bench_parse("utf8_heavy", make_utf8_heavy_doc(5000))
    bench_parse("multiline_comments", make_multiline_comment_doc(3000))
    bench_lookup_and_decode()
