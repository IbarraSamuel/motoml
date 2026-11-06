from motoml.lazy import parse_lazy, Validation
from motoml.mmap_file import MappedFile
from std.time import perf_counter_ns
from std.sys import argv


struct CountWriter(Writer):
    var bytes_written: Int

    def __init__(out self):
        self.bytes_written = 0

    def write_string(mut self, string: StringSpan):
        self.bytes_written += string.byte_length()


def _sort_ints(mut v: List[Int]):
    for i in range(1, len(v)):
        var key = v[i]
        var j = i - 1
        while j >= 0 and v[j] > key:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = key


def bench_one(
    name: StringSpan,
    path_str: String,
    is_holdout: Bool,
    csv: Bool,
    iters: Int = 15,
    warmups: Int = 3,
) raises:
    var mf = MappedFile(path_str)
    var view = mf.unsafe_view()
    var bytes = view.as_bytes()
    var size_mb = Float64(view.byte_length()) / (1024.0 * 1024.0)

    # Warmup
    for _ in range(warmups):
        var d1 = parse_lazy[Validation.Strict](bytes).take()
        _ = len(d1.nodes)
        var d2 = parse_lazy[Validation.Trusted](bytes).take()
        _ = len(d2.nodes)

    var strict_times = List[Int](capacity=iters)
    var trusted_times = List[Int](capacity=iters)
    var strict_json_times = List[Int](capacity=iters)

    for _ in range(iters):
        var t0 = perf_counter_ns()
        var d = parse_lazy[Validation.Strict](bytes).take()
        var t1 = perf_counter_ns()
        strict_times.append(Int(t1 - t0))

        var cw = CountWriter()
        d.to_json(cw)
        var t2 = perf_counter_ns()
        strict_json_times.append(Int(t2 - t0))

    for _ in range(iters):
        var t0 = perf_counter_ns()
        var d = parse_lazy[Validation.Trusted](bytes).take()
        var t1 = perf_counter_ns()
        _ = len(d.nodes)
        trusted_times.append(Int(t1 - t0))

    _sort_ints(strict_times)
    _sort_ints(trusted_times)
    _sort_ints(strict_json_times)

    var med_idx = iters // 2
    var s_med_mbps = size_mb / (Float64(strict_times[med_idx]) / 1e9)
    var s_max_mbps = size_mb / (Float64(strict_times[0]) / 1e9)
    var t_med_mbps = size_mb / (Float64(trusted_times[med_idx]) / 1e9)
    var t_max_mbps = size_mb / (Float64(trusted_times[0]) / 1e9)
    var sj_med_mbps = size_mb / (Float64(strict_json_times[med_idx]) / 1e9)

    var tag = "HOLDOUT" if is_holdout else "TUNED"
    if csv:
        print(
            name,
            ",",
            tag,
            ",",
            s_med_mbps,
            ",",
            s_max_mbps,
            ",",
            t_med_mbps,
            ",",
            t_max_mbps,
            ",",
            sj_med_mbps,
            sep="",
        )
    else:
        print(
            "[",
            tag,
            "] ",
            name,
            " | Strict med: ",
            Int(s_med_mbps),
            " MB/s (max ",
            Int(s_max_mbps),
            ") | Trusted med: ",
            Int(t_med_mbps),
            " MB/s (max ",
            Int(t_max_mbps),
            ") | Parse+JSON med: ",
            Int(sj_med_mbps),
            " MB/s",
            sep="",
        )


def main() raises:
    var args = argv()
    var csv = len(args) > 1 and StringSpan(args[1]) == "--csv"
    if csv:
        print(
            "corpus,set,strict_med_mbps,strict_max_mbps,trusted_med_mbps,trusted_max_mbps,parse_plus_json_med_mbps"
        )
    else:
        print(
            "=================== LAZY PARSER BENCHMARK (15 runs, median/max)"
            " ==================="
        )

    bench_one("strings_plain", "bench_data/strings_plain_1mb.toml", False, csv)
    bench_one(
        "strings_escaped", "bench_data/strings_escaped_1mb.toml", False, csv
    )
    bench_one("ints_floats", "bench_data/ints_floats_1mb.toml", False, csv)
    bench_one("dates", "bench_data/dates_1mb.toml", False, csv)
    bench_one("many_tables", "bench_data/many_tables_1mb.toml", False, csv)
    bench_one(
        "array_of_tables", "bench_data/array_of_tables_1mb.toml", False, csv
    )
    bench_one("inline_nested", "bench_data/inline_nested_1mb.toml", False, csv)
    bench_one("mixed", "bench_data/mixed_1mb.toml", False, csv)
    bench_one("huge_table", "bench_data/huge_table_1mb.toml", False, csv)
    bench_one("dotted_keys", "bench_data/dotted_keys_1mb.toml", False, csv)
    bench_one("realworld_lock", "bench_data/realworld_lock_1mb.toml", True, csv)
    bench_one(
        "realworld_config", "bench_data/realworld_config_1mb.toml", True, csv
    )
    bench_one(
        "toml_test_concat", "bench_data/toml_test_concat_1mb.toml", True, csv
    )
