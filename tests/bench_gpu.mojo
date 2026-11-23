"""Comprehensive GPU vs CPU TOML 1.1 benchmark suite across sizes, corpora, phases, and batching."""

from std.math import ceildiv
from std.memory import unsafe_memcpy
from std.time import perf_counter_ns
from motoml import Mode, parse_toml
from motoml.mmap_file import MappedFile
from motoml.tape.reader import _parse_tape
from motoml.types.document import _materialize
from motoml_gpu import GpuTomlParser
from motoml_gpu.stage2 import _CachedBlockCursor, _Stage2Builder


def _sort_ints(mut v: List[Int]):
    for i in range(1, len(v)):
        var key = v[i]
        var j = i - 1
        while j >= 0 and v[j] > key:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = key


def _median_ns(mut v: List[Int]) -> Float64:
    _sort_ints(v)
    return Float64(v[len(v) // 2])


def _mbps(bytes_len: Int, ns: Float64) -> Int:
    var mb = Float64(bytes_len) / (1024.0 * 1024.0)
    return Int(mb / (ns / 1e9))


def bench_corpus_row(
    mut gpu: GpuTomlParser,
    label: StringSpan,
    view: StringSpan,
    iters: Int = 9,
) raises:
    var n = view.byte_length()
    var bytes = view.as_bytes()

    # Warmup
    _ = parse_toml[Mode.Strict](view)
    _ = parse_toml[Mode.Eager](view)
    _ = gpu.parse[Mode.Strict](view, force_gpu=True)
    _ = gpu.parse[Mode.Eager](view, force_gpu=True, gpu_materialize=True)

    var cpu_strict_t = List[Int](capacity=iters)
    var cpu_eager_t = List[Int](capacity=iters)
    var gpu_s1_t = List[Int](capacity=iters)
    var gpu_s2_t = List[Int](capacity=iters)
    var gpu_strict_t = List[Int](capacity=iters)
    var gpu_eager_cpu_mat_t = List[Int](capacity=iters)
    var gpu_eager_gpu_mat_t = List[Int](capacity=iters)

    for _ in range(iters):
        var t0 = perf_counter_ns()
        var d_cs = parse_toml[Mode.Strict](view)
        var t1 = perf_counter_ns()
        _ = len(d_cs.nodes)
        cpu_strict_t.append(Int(t1 - t0))

        var t2 = perf_counter_ns()
        var d_ce = parse_toml[Mode.Eager](view)
        var t3 = perf_counter_ns()
        _ = len(d_ce.nodes)
        cpu_eager_t.append(Int(t3 - t2))

        # Measure Stage 1 GPU vs Stage 2 CPU breakdown + E2E GPU Strict
        var ts0 = perf_counter_ns()
        var nb = gpu._run_stage1_gpu[True](bytes)
        var ts1 = perf_counter_ns()
        var cur = _CachedBlockCursor(
            gpu.cached_block_starts.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            gpu.cached_block_lens.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            gpu.cached_tokens.unsafe_ptr()
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmUntrackedOrigin](),
            0,
            nb,
        )
        var bld = _Stage2Builder[True, bytes.origin](bytes, cur^)
        _ = bld.parse_document()
        var tape = bld^.into_tape()
        var ts2 = perf_counter_ns()
        _ = len(tape.nodes)

        gpu_s1_t.append(Int(ts1 - ts0))
        gpu_s2_t.append(Int(ts2 - ts1))
        gpu_strict_t.append(Int(ts2 - ts0))

        # GPU Stage 1 + CPU _materialize vs GPU _materialize_gpu
        var te0 = perf_counter_ns()
        var de1 = gpu.parse[Mode.Eager](
            view, force_gpu=True, gpu_materialize=False
        )
        var te1 = perf_counter_ns()
        _ = len(de1.nodes)
        gpu_eager_cpu_mat_t.append(Int(te1 - te0))

        var te2 = perf_counter_ns()
        var de2 = gpu.parse[Mode.Eager](
            view, force_gpu=True, gpu_materialize=True
        )
        var te3 = perf_counter_ns()
        _ = len(de2.nodes)
        gpu_eager_gpu_mat_t.append(Int(te3 - te2))

    var cs_ns = _median_ns(cpu_strict_t)
    var ce_ns = _median_ns(cpu_eager_t)
    var gs1_ns = _median_ns(gpu_s1_t)
    var gs2_ns = _median_ns(gpu_s2_t)
    var gs_ns = _median_ns(gpu_strict_t)
    var gec_ns = _median_ns(gpu_eager_cpu_mat_t)
    var geg_ns = _median_ns(gpu_eager_gpu_mat_t)

    print(
        label,
        " (",
        n // 1024,
        " KB) | CPU Strict: ",
        _mbps(n, cs_ns),
        " MB/s (",
        Int(cs_ns / 1e3),
        " us) | GPU S1: ",
        _mbps(n, gs1_ns),
        " MB/s (",
        Int(gs1_ns / 1e3),
        " us) + S2: ",
        Int(gs2_ns / 1e3),
        " us => GPU Strict: ",
        _mbps(n, gs_ns),
        " MB/s | CPU Eager: ",
        _mbps(n, ce_ns),
        " MB/s vs GPU Eager(CPU-mat/GPU-mat): ",
        _mbps(n, gec_ns),
        "/",
        _mbps(n, geg_ns),
        " MB/s",
        sep="",
    )


def make_synthetic_doc(target_bytes: Int, kind: Int) -> String:
    """Build synthetic large TOML documents."""
    var out = String(capacity_bytes=target_bytes + 4096)
    var i = 0
    while out.byte_length() < target_bytes:
        if kind == 0:
            out.write(
                t"# Section comment line with metadata and description for"
                t" block {i} — skipped on GPU in parallel!\n"
                t'entry_{i} ='
                t' "abcdefghijklmnopqrstuvwxyz0123456789_ABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789_payload_segment_value"\n'
            )
        elif kind == 1:
            out.write(
                t'esc_{i} ='
                t' "line1\\nline2\\t\\"quoted\\"\\u0041\\u00DF_escaped_payload_string_value_{i}\\nend"\n'
            )
        else:
            if i % 8 == 0:
                out.write(t"[service_{i}]\n")
            out.write(
                t'host_{i} = "prod-node-{i}.internal.cluster.local"\nport_{i} ='
                t' {8000 + (i % 1000)}\nenabled_{i} = true\ndate_{i} ='
                t' 2026-11-22\n'
            )
        i += 1
    return out^


def main() raises:
    var gpu = GpuTomlParser(
        initial_capacity_bytes=68 * 1024 * 1024, min_gpu_bytes=0
    )
    gpu.warmup[True]()
    gpu.warmup[False]()

    print("================ 1. 10 MB REAL BENCHMARK CORPORA ================")
    var corpora_10mb = [
        ("strings_plain_10mb", "bench_data/strings_plain_10mb.toml"),
        ("strings_escaped_10mb", "bench_data/strings_escaped_10mb.toml"),
        ("ints_floats_10mb", "bench_data/ints_floats_10mb.toml"),
        ("dates_10mb", "bench_data/dates_10mb.toml"),
        ("many_tables_10mb", "bench_data/many_tables_10mb.toml"),
        ("realworld_lock_10mb", "bench_data/realworld_lock_10mb.toml"),
        ("realworld_config_10mb", "bench_data/realworld_config_10mb.toml"),
        ("mixed_10mb", "bench_data/mixed_10mb.toml"),
    ]
    for i in range(len(corpora_10mb)):
        var name, path = corpora_10mb[i]
        var mf = MappedFile(path)
        bench_corpus_row(gpu, name, mf.unsafe_view(), iters=7)

    print(
        "\n================ 2. SIZE CROSSOVER SWEEP (16 KB -> 64 MB)"
        " ================"
    )
    var sweep_kb = [16, 64, 256, 1024, 4096, 16384, 65536]
    for i in range(len(sweep_kb)):
        var kb = sweep_kb[i]
        var doc = make_synthetic_doc(kb * 1024, 0)
        bench_corpus_row(
            gpu,
            String(t"comments+strings_{kb}kb"),
            doc,
            iters=7 if kb <= 16384 else 5,
        )

    var esc64 = make_synthetic_doc(64 * 1024 * 1024, 1)
    bench_corpus_row(gpu, "escaped_strings_64mb", esc64, iters=5)

    var mix64 = make_synthetic_doc(64 * 1024 * 1024, 2)
    bench_corpus_row(gpu, "mixed_tables_64mb", mix64, iters=5)

    print(
        "\n================ 3. BATCHED MULTI-DOCUMENT PARSING ================"
    )
    var n_batch = 256
    var batch = List[String](capacity=n_batch)
    var total_b = 0
    for _ in range(n_batch):
        var d = make_synthetic_doc(16 * 1024, 0)
        total_b += d.byte_length()
        batch.append(d^)

    # Warmup
    _ = gpu.parse_batch_eager(Span(batch), force_gpu=True)

    var cpu_b_times = List[Int](capacity=7)
    var gpu_b_times = List[Int](capacity=7)
    for _ in range(7):
        var tc0 = perf_counter_ns()
        var c_docs = List[Int](capacity=n_batch)
        for i in range(n_batch):
            var cd = parse_toml[Mode.Eager](batch[i])
            c_docs.append(len(cd.nodes))
        var tc1 = perf_counter_ns()
        cpu_b_times.append(Int(tc1 - tc0))

        var tg0 = perf_counter_ns()
        var g_docs = gpu.parse_batch_eager(Span(batch), force_gpu=True)
        var tg1 = perf_counter_ns()
        _ = len(g_docs)
        gpu_b_times.append(Int(tg1 - tg0))

    var cb_ns = _median_ns(cpu_b_times)
    var gb_ns = _median_ns(gpu_b_times)
    print(
        "Batch 256 x 16 KB (",
        total_b // 1024,
        " KB) | CPU Eager: ",
        _mbps(total_b, cb_ns),
        " MB/s (",
        Int(cb_ns / 1e3),
        " us) | GPU Batch Eager: ",
        _mbps(total_b, gb_ns),
        " MB/s (",
        Int(gb_ns / 1e3),
        " us)",
        sep="",
    )
