from motoml.parser import parse_toml_raises
from motoml.types.toml import Toml
from motoml.mmap_file import MappedFile
from std.pathlib import Path
from std.reflection import call_location
from std.time import perf_counter_ns
from std.benchmark import run


def toml_files() -> Path:
    var location = call_location().file_name()
    return Path(location[byte = : location.rfind("/")]) / "toml_files"


def main() raises:
    var root = toml_files() / "tests"
    var files = MappedFile(root / "files-toml-1.1.0").unsafe_view().splitlines()
    var valid_files = 0
    var total_bytes = 0
    var total_parse_ns: Float64 = 0
    var checksum = 0

    for relative_path in files:
        if not relative_path.endswith(".toml") or "invalid/" in relative_path:
            continue

        var file = root / relative_path
        var mapped_file = MappedFile(file)
        var content = mapped_file.unsafe_view()

        var parsed = parse_toml_raises[log=False](content)

        def parse_doc() raises {imm content}:
            _ = parse_toml_raises[log=False](content)

        var report = run(parse_doc, max_iters=1000, max_runtime_secs=30)
        total_parse_ns += report.mean("ns")

        checksum += len(parsed[Dict[String, Toml]])
        total_bytes += len(mapped_file)
        valid_files += 1

    print("Valid suite files parsed: ", valid_files, sep="")
    print("Total input size: ", total_bytes, " bytes", sep="")
    print("Total parse time: ", total_parse_ns, " ns", sep="")
    print(
        "Total parse time: ",
        Float64(total_parse_ns) / 1_000_000_000.0,
        " s",
        sep="",
    )
    print("Checksum: ", checksum, sep="")
