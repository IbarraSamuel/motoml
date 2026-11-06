from motoml.parser import parse_toml_raises
from motoml.lazy import parse_lazy, Validation
from motoml.mmap_file import MappedFile
from std.time import perf_counter_ns


def bench_corpus(name: StringSpan, path_str: String) raises:
    var mf = MappedFile(path_str)
    var view = mf.unsafe_view()
    var size_bytes = view.byte_length()
    var size_mb = Float64(size_bytes) / (1024.0 * 1024.0)

    # 1. Old parser
    _ = parse_toml_raises[log=False](view)  # warmup
    var old_best: Int = 1_000_000_000_000
    for _ in range(3):
        var t0 = perf_counter_ns()
        var res = parse_toml_raises[log=False](view)
        var t1 = perf_counter_ns()
        if (t1 - t0) < old_best:
            old_best = t1 - t0
    var old_ms = Float64(old_best) / 1_000_000.0
    var old_mbps = size_mb / (Float64(old_best) / 1_000_000_000.0)

    # 2. Lazy Strict
    _ = parse_lazy[Validation.Strict](view.as_bytes()).take()  # warmup
    var strict_best: Int = 1_000_000_000_000
    for _ in range(3):
        var t0 = perf_counter_ns()
        var res = parse_lazy[Validation.Strict](view.as_bytes()).take()
        var t1 = perf_counter_ns()
        if (t1 - t0) < strict_best:
            strict_best = t1 - t0
    var strict_ms = Float64(strict_best) / 1_000_000.0
    var strict_mbps = size_mb / (Float64(strict_best) / 1_000_000_000.0)
    var strict_speedup = Float64(old_best) / Float64(strict_best)

    # 3. Lazy Trusted (no-validation mode)
    _ = parse_lazy[Validation.Trusted](view.as_bytes()).take()  # warmup
    var trusted_best: Int = 1_000_000_000_000
    for _ in range(3):
        var t0 = perf_counter_ns()
        var res = parse_lazy[Validation.Trusted](view.as_bytes()).take()
        var t1 = perf_counter_ns()
        if (t1 - t0) < trusted_best:
            trusted_best = t1 - t0
    var trusted_ms = Float64(trusted_best) / 1_000_000.0
    var trusted_mbps = size_mb / (Float64(trusted_best) / 1_000_000_000.0)
    var trusted_speedup = Float64(old_best) / Float64(trusted_best)

    print(
        name,
        "| Old:",
        old_ms,
        "ms (",
        old_mbps,
        "MB/s) | Lazy Strict:",
        strict_ms,
        "ms (",
        strict_mbps,
        "MB/s) [",
        strict_speedup,
        "x] | Lazy Trusted:",
        trusted_ms,
        "ms (",
        trusted_mbps,
        "MB/s) [",
        trusted_speedup,
        "x]",
    )


def main() raises:
    print(
        "=================== TOML READER BENCHMARK COMPARISON"
        " ==================="
    )
    bench_corpus("strings_plain   ", "bench_data/strings_plain_1mb.toml")
    bench_corpus("strings_escaped ", "bench_data/strings_escaped_1mb.toml")
    bench_corpus("ints_floats     ", "bench_data/ints_floats_1mb.toml")
    bench_corpus("dates           ", "bench_data/dates_1mb.toml")
    bench_corpus("many_tables     ", "bench_data/many_tables_1mb.toml")
    bench_corpus("array_of_tables ", "bench_data/array_of_tables_1mb.toml")
    bench_corpus("inline_nested   ", "bench_data/inline_nested_1mb.toml")
    bench_corpus("mixed           ", "bench_data/mixed_1mb.toml")
    bench_corpus("huge_table      ", "bench_data/huge_table_1mb.toml")
    bench_corpus("dotted_keys     ", "bench_data/dotted_keys_1mb.toml")
