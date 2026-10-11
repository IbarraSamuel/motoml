from motoml.parser import parse_toml_raises
from motoml.types.toml import Toml
from json_parser import parse_json, translate_json_to_types
from files_to_test import TOML_FILES
from std.pathlib import Path
from std.reflection import call_location, SourceLocation, source_location
from std.testing import assert_true, assert_raises
from std.testing.suite import TestReport, TestResult, TestSuiteReport

from std.time import perf_counter_ns


def toml_single_test(strpath: String) raises -> None:
    # var strpath = StaticString(TOML_FILES).splitlines()[testno]
    var file = toml_files() / strpath
    if not file.exists():
        raise "file not exists: " + String(file)
    var content: String
    try:
        content = file.read_text()
    except e:
        if "invalid/encoding/" in strpath:
            return
        raise e^

    # print(t"test readed! file: {strpath}")
    if "invalid/" in strpath:
        with assert_raises():
            var toml_r = parse_toml_raises[log=False](content)
            var w = String()
            toml_r.to_json(w)
            # print(w)
        return

    var toml_result = parse_toml_raises[log=False](content)

    var exp_file = Path(String(file).removesuffix(file.suffix()) + ".json")
    if not exp_file.exists():
        raise t"json file not exists: {exp_file}"

    var expected_result = exp_file.read_text()

    var expected: Toml
    try:
        expected = translate_json_to_types(parse_json(expected_result))
    except:
        raise "[TESTCASE ERR]"

    var result_json = String()
    try:
        toml_result.to_json(result_json)
    except:
        raise "[JSON Serialization Error] Failed to convert parser result to JSON."

    var result: Toml
    try:
        result = translate_json_to_types(parse_json(result_json))
    except:
        raise t"[OUTPUT ERR] Error parsing json output from parser: {result_json}"
    try:
        assert_true(result == expected)
    except:
        raise t"Values are not equal.\nresult:\n{result}\nexpected:\n{expected}"


@always_inline
def toml_files() -> Path:
    var loc = call_location().file_name()
    return Path(loc[byte = : loc.rfind("/")]) / "toml_files"


def main() raises:
    """Main entrypoint."""
    var suite = PyTestSuite()
    var files = StaticString(TOML_FILES).splitlines()
    for li, fpath in enumerate(files):
        if not fpath.endswith(".toml"):
            continue
        var root_fpath = String(t"[{li}]: tests/toml_files/{fpath}")
        suite.add_test(name=root_fpath^, location=fpath)

    # print("Running tests...")
    suite^.run()


@fieldwise_init
struct PyTestSuite(Deinitable where False, Movable):
    var tests: List[Tuple[String, String]]
    var location: SourceLocation

    @always_inline
    def __init__(
        out self: PyTestSuite, location: Optional[SourceLocation] = None
    ):
        self.tests = {}
        self.location = location.or_else(call_location())

    def add_test(mut self, *, name: String, location: String):
        self.tests.append((name, location))

    def abandon(deinit self):
        pass

    def run(deinit self) raises:
        var reports = List[TestReport](capacity=len(self.tests))

        for name, location in self.tests:
            var error: Optional[Error] = None
            var start = perf_counter_ns()
            try:
                toml_single_test(location)
            except e:
                error = e^
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
