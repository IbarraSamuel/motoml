from motoml import Mode, try_parse_toml
from motoml.mmap_file import MappedFile
from std.pathlib import Path


def parse_fixture(path: String, is_invalid: Bool) raises:
    var file = Path(path)
    var mapped_file = MappedFile(file)
    var view = mapped_file.unsafe_view()

    var result = try_parse_toml[Mode.Strict](view)
    if is_invalid:
        if case .Err(_) = result:
            _ = result^.unsafe_take_error()
        else:
            _ = result^.unsafe_take_value()
            raise Error(t"Expected invalid TOML fixture to fail: {path}")

        var eager_result = try_parse_toml[Mode.Eager](view)
        if case .Err(_) = eager_result:
            _ = eager_result^.unsafe_take_error()
        else:
            _ = eager_result^.unsafe_take_value()
            raise Error(
                t"Expected invalid TOML fixture to fail in Eager mode: {path}"
            )
    else:
        if case .Ok(_) = result:
            var doc = result^.unsafe_take_value()
            var out = String()
            doc.to_json(out)
        else:
            var error = result^.unsafe_take_error()
            raise Error(t"Valid TOML fixture failed to parse: {path}: {error}")

        var eager_result = try_parse_toml[Mode.Eager](view)
        if case .Ok(_) = eager_result:
            var edoc = eager_result^.unsafe_take_value()
            var out = String()
            edoc.to_json(out)
        else:
            var error = eager_result^.unsafe_take_error()
            raise Error(
                t"Valid TOML fixture failed Eager parse: {path}: {error}"
            )


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
