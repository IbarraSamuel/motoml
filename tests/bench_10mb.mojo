from motoml import parse_toml, Mode
from motoml.mmap_file import MappedFile
from std.time import perf_counter_ns


def bench_10mb(name: StringSpan, path_str: String) raises:
    var mf = MappedFile(path_str)
    var view = mf.unsafe_view()
    var size_bytes = view.byte_length()
    var size_mb = Float64(size_bytes) / (1024.0 * 1024.0)

    # 1. Eager
    var t0 = perf_counter_ns()
    var res_eager = parse_toml[Mode.Eager](view).take()
    var t1 = perf_counter_ns()
    _ = len(res_eager)
    var eager_ms = Float64(t1 - t0) / 1_000_000.0
    var eager_mbps = size_mb / (Float64(t1 - t0) / 1_000_000_000.0)

    # 2. Lazy Strict
    var t2 = perf_counter_ns()
    var res_lazy = parse_toml[Mode.Strict](view).take()
    var t3 = perf_counter_ns()
    _ = len(res_lazy)
    var strict_ms = Float64(t3 - t2) / 1_000_000.0
    var strict_mbps = size_mb / (Float64(t3 - t2) / 1_000_000_000.0)
    var speedup = Float64(t1 - t0) / Float64(t3 - t2)

    print(
        name,
        "| Eager:",
        eager_ms,
        "ms (",
        eager_mbps,
        "MB/s) | Lazy Strict:",
        strict_ms,
        "ms (",
        strict_mbps,
        "MB/s) [",
        speedup,
        "x]",
    )


def main() raises:
    print("=================== 10MB PRESSURE TEST ===================")
    bench_10mb("strings_plain_10mb   ", "bench_data/strings_plain_10mb.toml")
    bench_10mb("many_tables_10mb     ", "bench_data/many_tables_10mb.toml")
    bench_10mb("inline_nested_10mb   ", "bench_data/inline_nested_10mb.toml")
    bench_10mb("mixed_10mb           ", "bench_data/mixed_10mb.toml")
