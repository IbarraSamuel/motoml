"""Generic (non-bench-corpus) benchmarks: UTF-8, multiline/comments, query & decode."""

from std.time import perf_counter_ns
from std.collections import Dict
from motoml.lazy import parse_lazy, Validation, Kind
from motoml.types.toml import Toml


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
        s += (
            "k_"
            + String(i)
            + " = "
            + String(i * 13 + 7)
            + "\n"
        )
    return s^


def bench_parse(name: String, content: String, runs: Int = 15) raises:
    var bytes = content.as_bytes()
    var mb = Float64(len(bytes)) / 1e6

    var d0 = parse_lazy[Validation.Strict](bytes).take()
    var j0 = String(capacity_bytes=len(bytes) * 2)
    d0.to_json(j0)
    _ = j0.byte_length()
    var d1 = parse_lazy[Validation.Trusted](bytes).take()
    _ = len(d1)

    var best_strict = Float64(1e18)
    var best_trusted = Float64(1e18)
    var best_json = Float64(1e18)

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_lazy[Validation.Strict](bytes).take()
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_strict:
            best_strict = ms

    for _ in range(runs):
        var t0 = perf_counter_ns()
        var doc = parse_lazy[Validation.Trusted](bytes).take()
        var t1 = perf_counter_ns()
        _ = len(doc)
        var ms = Float64(t1 - t0) / 1e6
        if ms < best_trusted:
            best_trusted = ms

    for _ in range(runs):
        var out = String(capacity_bytes=len(bytes) * 2)
        var t0 = perf_counter_ns()
        var doc = parse_lazy[Validation.Strict](bytes).take()
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
        "MB/s | Parse+JSON max:",
        Int(mb / (best_json / 1000.0)),
        "MB/s",
    )


def bench_lookup_and_decode() raises:
    var lookup_src = make_lookup_doc(4000)
    var doc = parse_lazy(lookup_src.as_bytes()).take()
    var keys = List[String](capacity=4000)
    for i in range(4000):
        keys.append("k_" + String(i))

    var best_lookup_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for ref k in keys:
            acc += doc[k].value().as_int().take()
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_lookup_ns:
            best_lookup_ns = dt

    var best_iter_ns = Int(1 << 60)
    for _ in range(15):
        var acc = 0
        var t0 = perf_counter_ns()
        for child in doc.root().children():
            acc += child.as_int().take()
        var t1 = perf_counter_ns()
        if acc == -1:
            print(acc)
        var dt = Int(t1 - t0)
        if dt < best_iter_ns:
            best_iter_ns = dt

    var best_totoml_ns = Int(1 << 60)
    for _ in range(10):
        var t0 = perf_counter_ns()
        var tree = doc.to_toml()
        var t1 = perf_counter_ns()
        _ = len(tree[Dict[String, Toml]])
        var dt = Int(t1 - t0)
        if dt < best_totoml_ns:
            best_totoml_ns = dt

    print(
        "lookup_4k (key[]+as_int):",
        Float64(best_lookup_ns) / 4000.0,
        "ns/entry | children_iter+as_int:",
        Float64(best_iter_ns) / 4000.0,
        "ns/entry | to_toml:",
        Float64(best_totoml_ns) / 1e6,
        "ms",
    )


def main() raises:
    print("=================== GENERIC LAZY BENCHMARKS ===================")
    bench_parse("utf8_heavy", make_utf8_heavy_doc(5000))
    bench_parse("multiline_comments", make_multiline_comment_doc(3000))
    bench_lookup_and_decode()
