from motoml.mmap_file import MappedFile
from motoml.parser import parse_toml
from std.pathlib import Path


def parse_fixture(path: String, is_invalid: Bool) raises:
    var file = Path(path)
    var mapped_file = MappedFile(file)
    var result = parse_toml[log=False](mapped_file.unsafe_view())

    if is_invalid:
        if case .Err = result:
            _ = result^.unsafe_take_error()
        else:
            _ = result^.unsafe_take_value()
            raise Error(t"Expected invalid TOML fixture to fail: {path}")
    else:
        if case .Ok = result:
            _ = result^.unsafe_take_value()
        else:
            var error = result^.unsafe_take_error()
            raise Error(t"Valid TOML fixture failed to parse: {path}: {error}")


def main() raises:
    var tests_dir = Path("tests/toml_files/tests")
    var manifest = MappedFile(tests_dir / "files-toml-1.1.0")
    var fixture_paths = manifest.unsafe_view().splitlines()
    var parsed = 0

    for fixture_path in fixture_paths:
        if not fixture_path.endswith(".toml"):
            continue
        var path = String(fixture_path)
        parse_fixture(
            String(t"{tests_dir}/{path}"), path.startswith("invalid/")
        )
        parsed += 1

    print("ASAN TOML fixture run passed:", parsed, "files")
