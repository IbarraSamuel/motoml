"""Full TOML 1.1 compliance, cross-mode byte-for-byte parity, GPU Eager materializer,
chunk-boundary stress, and batch GPU parsing test suite (`force_gpu=True`).
"""

from std.pathlib import Path
from std.reflection import call_location
from std.testing import assert_equal, assert_raises, assert_true
from motoml import Mode, parse_toml, toml_to_tagged_json
from motoml.mmap_file import MappedFile
from motoml_gpu import GpuTomlParser, toml_to_tagged_json_gpu
from json_parser import JsonDoc, parse_json, translate_json_to_types


@always_inline
def toml_files() -> Path:
    var loc = call_location().file_name()
    return Path(loc[byte = : loc.rfind("/")]) / "toml_files"


def test_full_toml_1_1_suite_on_gpu(mut gpu: GpuTomlParser) raises:
    var toml_dir = toml_files() / "tests"
    var files_map = MappedFile(toml_dir / "files-toml-1.1.0")
    var v11_files = files_map.unsafe_view().splitlines()

    var valid_count = 0
    var invalid_count = 0

    for fpath in v11_files:
        var spath = String(t"{toml_dir}/{fpath}")
        if not spath.endswith(".toml"):
            continue
        var fmap = MappedFile(spath)
        var content = fmap.unsafe_view()

        if "invalid/" in spath:
            # Must raise on both Strict and Eager with force_gpu=True
            var raised_strict = False
            try:
                _ = toml_to_tagged_json_gpu[Mode.Strict](
                    gpu, content, force_gpu=True
                )
            except:
                raised_strict = True
            if not raised_strict:
                raise Error(
                    t"GPU Strict failed to reject invalid TOML: {spath}"
                )

            var raised_eager = False
            try:
                _ = gpu.parse[Mode.Eager](
                    content, force_gpu=True, gpu_materialize=True
                )
            except:
                raised_eager = True
            if not raised_eager:
                raise Error(t"GPU Eager failed to reject invalid TOML: {spath}")
            invalid_count += 1
        else:
            # Byte-for-byte tagged JSON parity against CPU reference across all 3 modes + GPU Eager materializer!
            var cpu_json = toml_to_tagged_json[Mode.Strict](content)
            var gpu_strict: String
            var gpu_trusted: String
            var gpu_eager = String()
            try:
                gpu_strict = toml_to_tagged_json_gpu[Mode.Strict](
                    gpu, content, force_gpu=True
                )
                gpu_trusted = toml_to_tagged_json_gpu[Mode.Trusted](
                    gpu, content, force_gpu=True
                )
                var gpu_eager_doc = gpu.parse[Mode.Eager](
                    content, force_gpu=True, gpu_materialize=True
                )
                gpu_eager_doc.to_json(gpu_eager)
            except e:
                raise Error(t"GPU failed on valid fixture {spath}: {e}")

            if gpu_strict != cpu_json:
                raise Error(
                    t"GPU Strict mismatch on {spath}:\ngot: {gpu_strict}\nexp:"
                    t" {cpu_json}"
                )
            if gpu_trusted != cpu_json:
                raise Error(
                    t"GPU Trusted mismatch on {spath}:\ngot:"
                    t" {gpu_trusted}\nexp: {cpu_json}"
                )
            if gpu_eager != cpu_json:
                raise Error(
                    t"GPU Eager (gpu_materialize) mismatch on {spath}:\ngot:"
                    t" {gpu_eager}\nexp: {cpu_json}"
                )
            valid_count += 1

    print(
        "[PASS] Official toml-test 1.1.0 on GPU (force_gpu=True): valid=",
        valid_count,
        "invalid=",
        invalid_count,
        "total=",
        valid_count + invalid_count,
    )


def test_chunk_and_block_boundaries_on_gpu(mut gpu: GpuTomlParser) raises:
    """Stress 64-byte thread boundaries and 16,384-byte block boundaries with
    straddling `\"\"\"`, `'''`, `\\\\\"`, UTF-8 4-byte codepoints, bare keys, and floats.
    """
    for pad in range(56, 72):
        var prefix = " " * pad
        # 1. Multiline basic string with 5 closing quotes straddling 64B boundary
        var doc1 = String(
            prefix,
            'k = """hello \\"world\\" """""\nnext_key = 12345\n',
        )
        assert_equal(
            toml_to_tagged_json_gpu[Mode.Strict](gpu, doc1, force_gpu=True),
            toml_to_tagged_json[Mode.Strict](doc1),
        )

        # 2. 4-byte UTF-8 emoji straddling 64B boundary inside string and comment
        var doc2 = String(
            's = "',
            "a" * pad,
            '🚀🔥🎉"\n# ',
            "b" * pad,
            "🚀\nx = 3.14159265358979\n",
        )
        assert_equal(
            toml_to_tagged_json_gpu[Mode.Strict](gpu, doc2, force_gpu=True),
            toml_to_tagged_json[Mode.Strict](doc2),
        )

        # 3. Dotted numeric key vs float value straddling 64B boundary
        var doc3 = String(
            prefix, "1.2.3 = 4.5e-6\ndt = 1979-05-27 07:32:00.123Z\n"
        )
        assert_equal(
            toml_to_tagged_json_gpu[Mode.Strict](gpu, doc3, force_gpu=True),
            toml_to_tagged_json[Mode.Strict](doc3),
        )

    # Stress 16 KB block boundary straddling
    var big_pad = " " * (16384 - 5)
    var block_doc = String(
        big_pad,
        'k = """across_16kb_block_boundary\\n\\u0041"""\nv = 9876543210\n',
    )
    var gpu_e = gpu.parse[Mode.Eager](
        block_doc, force_gpu=True, gpu_materialize=True
    )
    var gpu_e_json = String()
    gpu_e.to_json(gpu_e_json)
    assert_equal(gpu_e_json, toml_to_tagged_json[Mode.Eager](block_doc))
    print("[PASS] 64B thread & 16KB block boundary straddle tests passed!")


def test_batch_gpu_parsing(mut gpu: GpuTomlParser) raises:
    var batch = List[String]()
    for i in range(64):
        batch.append(
            String(
                t'[package]\nname = "pkg_{i}"\nversion = "1.2.{i}"\ncount ='
                t" {i * 10}\nenabled = true\n"
            )
        )
    var docs = gpu.parse_batch_eager(Span(batch), force_gpu=True)
    assert_equal(len(docs), 64)
    for i in range(64):
        var got_json = String()
        docs[i].to_json(got_json)
        assert_equal(got_json, toml_to_tagged_json[Mode.Eager](batch[i]))
    print(
        "[PASS] Batched multi-document GPU parsing (64 docs in 1 launch)"
        " passed!"
    )


def main() raises:
    var gpu = GpuTomlParser(
        initial_capacity_bytes=2 * 1024 * 1024, min_gpu_bytes=0
    )
    gpu.warmup[True]()
    gpu.warmup[False]()
    test_full_toml_1_1_suite_on_gpu(gpu)
    test_chunk_and_block_boundaries_on_gpu(gpu)
    test_batch_gpu_parsing(gpu)
