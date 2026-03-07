from motoml.new_parser import parse_toml, toml_to_tagged_json
from test_suite import PyTestSuite
from files_to_test import TOML_FILES
from std.pathlib import Path
from std.reflection import call_location
from std.python import PythonObject
from std.testing import assert_equal, assert_true


# def sorting(py: PythonObject, item: PythonObject) -> PythonObject:
#     if py.isinstance(item, py.dict):
#         sorted_keys = py.sorted(item.keys())
#         result_dict = py.dict()
#         for k in sorted_keys:
#             result_dict[k] = sorting(py, item[k])
#         return result_dict
#     if py.isinstance(item, py.list):
#         lst = py.list()
#         for x in item:
#             lst.append(sorting(py, x))
#         return py.sorted(lst)
#     else:
#         return item


# def compare_two_objs(
#     py: PythonObject, obj1: PythonObject, obj2: PythonObject
# ) -> PythonObject:
#     if py.isinstance(item, py.dict):
#         sorted_keys = py.sorted(item.keys())
#         result_dict = py.dict()
#         for k in sorted_keys:
#             result_dict[k] = sorting(py, item[k])
#         return result_dict
#     if py.isinstance(item, py.list):
#         lst = py.list()
#         for x in item:
#             lst.append(sorting(py, x))
#         return py.sorted(lst)
#     else:
#         return item


fn file_test[strpath: StaticString](json: PythonObject) raises:
    var file = toml_files() / strpath
    var exp_file = Path(String(file).removesuffix(file.suffix()) + ".json")
    if not (file.exists() and exp_file.exists()):
        raise "one file not exists: " + String(file) + " or " + String(exp_file)
    var content = file.read_text()
    print("parsing file:", file)
    var json_result = toml_to_tagged_json(content)
    var exp_result = exp_file.read_text()

    try:
        py_obj = exp_result.to_python_object()
        py_expected = json.loads(py_obj)
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
    except:
        raise "[OUTPUT ERR] Error parsing json output from parser: {}".format(
            r_obj
        )

    # try:
    #     assert_true(py_result == py_expected)
    # except:
    assert_equal(py_result, py_expected)


@always_inline
fn toml_files() -> Path:
    var loc = call_location().file_name
    return Path(loc[: loc.rfind("/")]) / "toml_files"


fn filter_files(files: StaticString) -> List[StaticString]:
    return [
        f
        for f in files.splitlines()
        if (f.startswith("valid") and f.endswith(".toml"))
    ]


fn main() raises:
    comptime files_to_test = filter_files(TOML_FILES)

    var suite = PyTestSuite()

    comptime for li in range(len(files_to_test)):
        comptime fpath = files_to_test[li]
        comptime root_fpath = StaticString(
            "[{}]: tests/toml_files/{}".format(li, fpath)
        )
        suite.test[file_test[fpath]](root_fpath)

    suite^.run()
