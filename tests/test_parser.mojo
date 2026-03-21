from motoml.parser import parse_toml, toml_to_tagged_json
from files_to_test import TOML_FILES
from std.pathlib import Path
from std.reflection import call_location, SourceLocation
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true, assert_raises
from std.testing.suite import TestReport, TestResult, TestSuiteReport

from std.time import perf_counter_ns


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


def file_test(strpath: String) raises:
    # var strpath = StaticString(TOML_FILES).splitlines()[testno]
    var file = toml_files() / strpath
    if not file.exists():
        raise "file not exists: " + String(file)
    var content = file.read_text()

    if "invalid" in strpath:
        with assert_raises():
            var json_result = toml_to_tagged_json(content)
        return

    var json_result = toml_to_tagged_json(content)

    var exp_file = Path(String(file).removesuffix(file.suffix()) + ".json")
    if not exp_file.exists():
        raise t"json file not exists: {exp_file}"

    var exp_result = exp_file.read_text()

    var py = Python()
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


@always_inline
def toml_files() -> Path:
    var loc = call_location().file_name
    return Path(loc[byte = : loc.rfind("/")]) / "toml_files"


def main() raises:
    var suite = PyTestSuite()

    for li, fpath in enumerate(StaticString(TOML_FILES).splitlines()):
        if not fpath.endswith(".toml"):
            continue
        var root_fpath = String(t"[{li}]: tests/toml_files/{fpath}")
        suite.test(name=root_fpath, location=fpath)

    print("Running tests...")
    suite^.run()


@fieldwise_init
@explicit_destroy("run() or abandon() the TestSuite")
struct PyTestSuite(Movable):
    var tests: List[Tuple[String, String]]
    var location: SourceLocation

    @always_inline
    def __init__(
        out self: PyTestSuite, location: Optional[SourceLocation] = None
    ):
        self.tests = {}
        self.location = location.or_else(call_location())

    def test(mut self, *, name: String, location: String):
        self.tests.append((name, location))

    def abandon(deinit self):
        pass

    def run(deinit self) raises:
        var reports = List[TestReport](capacity=len(self.tests))

        for name, location in self.tests:
            var error: Optional[Error] = None
            var start = perf_counter_ns()
            try:
                file_test(location)
            except e:
                error = {e^}
            var duration = perf_counter_ns() - start
            var result = TestResult.PASS if not error else TestResult.FAIL
            var report = TestReport(
                name=name,
                duration_ns=duration,
                result=result,
                error=error^.or_else({}),
            )
            reports.append(report^)

        # parallelize[test_n](len(reports))
        # for ti in range(len(reports)):
        #     tg.create_task(test_n(ti))

        # tg.wait()
        var report = TestSuiteReport(reports=reports^, location=self.location)

        if report.failures > 0:
            raise Error(report^)

        print(report)
