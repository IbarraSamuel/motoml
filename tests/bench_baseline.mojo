from motoml.parser import parse_toml_raises
from motoml.mmap_file import MappedFile
from std.time import perf_counter_ns
from std.pathlib import Path


def bench_file(path_str: String) raises:
    var mf = MappedFile(path_str)
    var view = mf.unsafe_view()
    # warm up
    _ = parse_toml_raises[log=False](view)

    var runs = 3
    var best_ns: Int = 1_000_000_000_000
    for _ in range(runs):
        var t0 = perf_counter_ns()
        var res = parse_toml_raises[log=False](view)
        var t1 = perf_counter_ns()
        var elapsed = t1 - t0
        if elapsed < best_ns:
            best_ns = elapsed

    var size_bytes = view.byte_length()
    var ms = Float64(best_ns) / 1_000_000.0
    var mb_per_sec = (Float64(size_bytes) / (1024.0 * 1024.0)) / (
        Float64(best_ns) / 1_000_000_000.0
    )
    print(
        path_str,
        " | size:",
        size_bytes,
        "bytes | best:",
        ms,
        "ms | throughput:",
        mb_per_sec,
        "MB/s",
    )


def main() raises:
    print("=== Baseline Benchmark (Old Parser) ===")
    bench_file("tests/bench_data/strings_plain_1mb.toml")
    bench_file("tests/bench_data/strings_escaped_1mb.toml")
    bench_file("tests/bench_data/ints_floats_1mb.toml")
    bench_file("tests/bench_data/dates_1mb.toml")
    bench_file("tests/bench_data/many_tables_1mb.toml")
    bench_file("tests/bench_data/array_of_tables_1mb.toml")
    bench_file("tests/bench_data/inline_nested_1mb.toml")
    bench_file("tests/bench_data/mixed_1mb.toml")
    bench_file("tests/bench_data/huge_table_1mb.toml")
    bench_file("tests/bench_data/dotted_keys_1mb.toml")
