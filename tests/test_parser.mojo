from motoml.parser import parse_toml, toml_to_tagged_json
from test_suite import PyTestSuite
from files_to_test import TOML_FILES
from std.pathlib import Path
from std.reflection import call_location
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises


def translate_json_to_types(
    py: Python, json: PythonObject
) raises -> PythonObject:
    if "type" in json and "value" in json and len(json) == 2:
        var type = json["type"]
        var str_v = json["value"]

        var value: PythonObject
        if type == "float":
            if str_v == "nan":
                value = py.none()
            else:
                value = py.float(str_v)
        elif type == "integer":
            value = py.int(str_v)
        else:
            value = str_v
        return {"type": json["type"], "value": value}

    if py.type(json) is py.evaluate("list"):
        var new_list = py.list()
        for it in json:
            new_list.append(translate_json_to_types(py, it))
        return new_list
    elif py.type(json) is py.evaluate("dict"):
        var new_dict = py.dict()
        for kv in json.items():
            new_dict[kv[0]] = translate_json_to_types(py, kv[1])
        return new_dict
    else:
        return json


def file_test[testno: Int](py: Python) raises:
    var strpath = StaticString(TOML_FILES).splitlines()[testno]
    var file = toml_files() / strpath
    var exp_file = Path(String(file).removesuffix(file.suffix()) + ".json")
    if not (file.exists() and exp_file.exists()):
        raise "one file not exists: " + String(file) + " or " + String(exp_file)
    var content = file.read_text()
    var json_result = toml_to_tagged_json(content)
    var exp_result = exp_file.read_text()

    var json = py.import_module("json")
    try:
        py_obj = exp_result.to_python_object()
        py_expected = json.loads(py_obj)
        py_expected = translate_json_to_types(py, py_expected)
    except:
        raise "[TESTCASE ERR]"

    try:
        r_obj = json_result.to_python_object()
    except:
        raise "[Python Interop Error] Failed to convert json result to python object. {}".format(
            json_result
        )
    try:
        py_result = json.loads(r_obj)
        py_result = translate_json_to_types(py, py_result)
    except:
        raise "[OUTPUT ERR] Error parsing json output from parser: {}".format(
            r_obj
        )

    try:
        assert_true(py_result == py_expected)
    except:
        assert_equal(String(py_result), String(py_expected))


def file_test_raises[testno: Int](py: Python) raises:
    var strpath = StaticString(TOML_FILES).splitlines()[testno]
    var file = toml_files() / strpath
    print(t"file: {file}")
    if not file.exists():
        raise "file not exists: " + String(file)
    var content = file.read_text()

    with assert_raises():
        var json_result = toml_to_tagged_json(content)


@always_inline
fn toml_files() -> Path:
    var loc = call_location().file_name
    return Path(loc[byte = : loc.rfind("/")]) / "toml_files"


fn only_toml_files(values: StaticString) -> List[Int]:
    return [i for i, f in enumerate(values.splitlines()) if f.endswith(".toml")]


fn main() raises:
    comptime only_toml = only_toml_files(TOML_FILES)
    var files = StaticString(TOML_FILES).splitlines()
    var suite = PyTestSuite()

    comptime for li in only_toml:
        var fpath = files[li]
        var root_fpath = String(t"[{li}]: tests/toml_files/{fpath}")
        if fpath.startswith("invalid"):
            print(t"[invalid] adding test: {fpath}")
            suite.test[file_test_raises[li]](root_fpath)
        else:
            print(t"[valid] adding test: {fpath}")
            suite.test[file_test[li]](root_fpath)

    print("Running tests...")
    suite^.run()
