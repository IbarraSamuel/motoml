from motoml.parser import parse_toml, toml_to_tagged_json
from test_suite import TestSuite
from files_to_test import TOML_FILES
from pathlib import Path
from reflection import call_location
from python import PythonObject, Python
from testing import assert_equal, assert_true


def sorting(py: PythonObject, item: PythonObject) -> PythonObject:
    if py.isinstance(item, py.dict):
        lst = py.list()
        for kv in item.items():
            key = kv[0]
            values = kv[1]
            lst.append(py.tuple(key, py.sorting(values)))
        return py.sorted(lst)
    if py.isinstance(item, py.list):
        lst = py.list()
        for x in item:
            lst.append(py.sorting(x))
        return py.sorted(lst)
    else:
        return item


fn file_test[strpath: StaticString]() raises:
    var file = toml_files() / strpath
    var exp_file = Path(String(file).removesuffix(file.suffix()) + ".json")
    if not (file.exists() and exp_file.exists()):
        raise "file not exists: " + String(file)

    var content = file.read_text()
    var json_result = toml_to_tagged_json(content)
    var exp_result = exp_file.read_text()

    var json = Python.import_module("json")
    var py_result = json.loads(PythonObject(json_result))
    var py_expected = json.loads(PythonObject(exp_result))

    var py = Python.import_module("builtins")
    py_result = sorting(py, py_result)
    py_expected = sorting(py, py_expected)
    assert_true(py_result == py_expected)


@always_inline
fn toml_files() -> Path:
    var loc = call_location().file_name
    return Path(loc[: loc.rfind("/")]) / "toml_files"


fn main() raises:
    comptime lines = StringSlice(TOML_FILES).splitlines()
    var suite = TestSuite()

    @parameter
    for li in range(len(lines)):
        comptime fpath = lines[li]

        @parameter
        if not (fpath.startswith("valid") and fpath.endswith(".toml")):
            continue

        var file = toml_files() / fpath

        if not file.exists():
            continue

        suite.test[file_test[fpath]](fpath)

    suite^.run()
