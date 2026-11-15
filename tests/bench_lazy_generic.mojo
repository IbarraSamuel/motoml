"""Generic (non-bench-corpus) benchmarks: UTF-8, multiline/comments, query & decode."""

from std.time import perf_counter_ns
from motoml import parse_toml, Mode, Kind


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


def bench_parse(name: String, content: String, runs: Int = 15) raises:
    var mb = Float64(content.byte_length()) / 1e6

    var d0 = parse_toml[Mode.Strict](content).take()
    var j0 = String(capacity_bytes=content.byte_length() * 2)
    d0.to_json(j0)
    _ = j0.byte_length()
    var d1 = parse_toml[Mode.Trusted](content).take()
    _ = len(d1)
    var d2 = parse_toml[Mode.Eager](content).take()
    _ = len(d2)

    var best_strict = Float64(1e18)
    var best_trusted = Float64(1e18)
    var best_eager = Float64(1e18)
    var best_json = Float64(1e18)

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Strict](content).take()
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_strict:
            best_strict = ms

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Trusted](content).take()
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_trusted:
            best_trusted = ms

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Eager](content).take()
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_eager:
            best_eager = ms

    for _ in range(runs):
        var out = String(capacity_bytes=content.byte_length() * 2)
        var t0 = perf_counter_ns()
        var doc = parse_toml[Mode.Strict](content).take()
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
    var lazy_doc = parse_toml[Mode.Strict](lookup_src).take()
    var eager_doc = parse_toml[Mode.Eager](lookup_src).take()
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
    var arr_lazy = parse_toml[Mode.Strict](arr_src).take()
    var arr_eager = parse_toml[Mode.Eager](arr_src).take()
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
    _ = len(lazy_arr_v)

    var cfg_src = (
        'host = "localhost"\nport = 8080\nratio = 0.75\nenabled = true\n'
    )
    var best_refl_lazy_ns = Int(1 << 60)
    var best_refl_eager_ns = Int(1 << 60)
    for _ in range(15):
        var t0 = perf_counter_ns()
        var acc = 0
        for _ in range(100):
            var d = parse_toml[Mode.Strict](cfg_src).take()
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
            var d = parse_toml[Mode.Eager](cfg_src).take()
            var c = d.take[BenchConfig]()
            acc += c.port
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_refl_eager_ns:
            best_refl_eager_ns = dt

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
        "ns/entry | Eager arr[i]:",
        Float64(best_eager_arr_ns) / 2000.0,
        "ns/elem",
    )
    print(
        "Reflection (100x parse+take[Struct]) Lazy:",
        Float64(best_refl_lazy_ns) / 100.0,
        "ns/call | Eager:",
        Float64(best_refl_eager_ns) / 100.0,
        "ns/call",
    )


def main() raises:
    print("=================== GENERIC BENCHMARKS ===================")
    bench_parse("utf8_heavy", make_utf8_heavy_doc(5000))
    bench_parse("multiline_comments", make_multiline_comment_doc(3000))
    bench_lookup_and_decode()
