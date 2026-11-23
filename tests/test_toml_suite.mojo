from motoml import Mode, toml_to_tagged_json
from motoml.mmap_file import MappedFile
from json_parser import JsonDoc, parse_json, translate_json_to_types
from std.pathlib import Path
from std.reflection import SourceLocation, call_location
from std.testing import assert_equal, assert_raises
from std.testing.suite import TestReport, TestResult, TestSuiteReport
from std.time import perf_counter_ns


def toml_single_test[mode: Mode](strpath: String) raises -> None:
    var file = Path(strpath)
    if not file.exists():
        raise t"file does not exist: {file}"
    var fmap = MappedFile(file)
    var content = fmap.unsafe_view()

    if "invalid/" in strpath:
        with assert_raises():
            _ = toml_to_tagged_json[mode](content)
        return

    var result_json = toml_to_tagged_json[mode](content)

    var exp_file = Path(String(file).removesuffix(file.suffix()) + ".json")
    if not exp_file.exists():
        raise t"json file does not exist: {exp_file}"

    var expected_result = exp_file.read_text()

    var expected: JsonDoc
    try:
        expected = translate_json_to_types(parse_json(expected_result))
    except:
        raise "[TESTCASE ERR]"

    var result: JsonDoc
    try:
        result = translate_json_to_types(parse_json(result_json))
    except:
        raise t"[OUTPUT ERR] Error parsing json output from parser: {result_json}"
    try:
        assert_equal(result, expected)
    except:
        raise t"Values are not equal.\nresult:\n{result}\nexpected:\n{expected}"


@always_inline
def toml_files() -> Path:
    var loc = call_location().file_name()
    return Path(loc[byte = : loc.rfind("/")]) / "toml_files"


def _run_suite[
    mode: Mode
](
    label: String,
    toml_dir: Path,
    v11_files: List[StringSpan[_]],
    valid_only: Bool = False,
) raises:
    var suite = NamedTestSuite[mode]()
    for li, fpath in enumerate(v11_files):
        var spath = String(t"{toml_dir}/{fpath}")
        if not spath.endswith(".toml"):
            continue
        if valid_only and "invalid/" in spath:
            continue
        var root_fpath = String(t"[{label} 1.1 {li}]: {toml_dir}/{fpath}")
        suite.add_test(name=root_fpath, location=spath)
    suite^.run()


def main() raises:
    var toml_dir = toml_files() / "tests"
    var files_map = MappedFile(toml_dir / "files-toml-1.1.0")
    var v11_files = files_map.unsafe_view().splitlines()

    _run_suite[Mode.Strict]("Strict", toml_dir, v11_files, valid_only=False)
    _run_suite[Mode.Eager]("Eager", toml_dir, v11_files, valid_only=False)
    _run_suite[Mode.Trusted]("Trusted", toml_dir, v11_files, valid_only=True)


@fieldwise_init
struct NamedTestSuite[mode: Mode](
    not Deinitable else "run tests or abandon them.", Movable
):
    var tests: List[Tuple[String, String]]
    var location: SourceLocation

    @always_inline
    def __init__(out self, location: Optional[SourceLocation] = None):
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
                toml_single_test[Self.mode](location)
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

        var report = TestSuiteReport(reports=reports^, location=self.location)

        if report.failures > 0:
            raise Error(report)

        print(report)
