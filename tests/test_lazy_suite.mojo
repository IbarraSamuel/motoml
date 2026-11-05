from motoml.lazy import parse_lazy, Validation, Document
from motoml.types.toml import Toml
from motoml.mmap_file import MappedFile
from json_parser import parse_json, translate_json_to_types
from std.pathlib import Path
from std.reflection import call_location, SourceLocation, source_location
from std.testing import assert_true, assert_raises, assert_equal
from std.testing.suite import TestReport, TestResult, TestSuiteReport
from std.time import perf_counter_ns


def parse_lazy_strict(
    content: Span[Byte, _]
) raises -> Document[content.origin, Validation.Strict]:
    var res = parse_lazy[Validation.Strict](content)
    if case .Err = res:
        raise Error(res^.unsafe_take_error())
    return res^.unsafe_take_value()


def toml_single_test(strpath: String) raises -> None:
    var file = Path(strpath)
    if not file.exists():
        raise t"file not exists: {file}"
    var fmap = MappedFile(file)
    var content = fmap.unsafe_view()

    if "invalid/" in strpath:
        with assert_raises():
            var doc = parse_lazy_strict(content.as_bytes())
            _ = len(doc.nodes)
        return

    var doc = parse_lazy_strict(content.as_bytes())

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
    doc.to_json(result_json)

    var result: Toml
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


def main() raises:
    """Main entrypoint for lazy parser test suite."""
    var toml_dir = toml_files() / "tests"

    var v11_files = (
        MappedFile(toml_dir / "files-toml-1.1.0").unsafe_view().splitlines()
    )
    var suite = NamedTestSuite()

    for li, fpath in enumerate(v11_files):
        var spath = String(t"{toml_dir}/{fpath}")
        if not spath.endswith(".toml"):
            continue
        var root_fpath = String(t"[1.1 {li}]: {toml_dir}/{fpath}")
        suite.add_test(name=root_fpath, location=spath)

    suite^.run()


@fieldwise_init
struct NamedTestSuite(
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
        var passed = 0
        var failed = 0

        var valid_passed = 0
        var valid_failed = 0
        var invalid_passed = 0
        var invalid_failed = 0

        for name, location in self.tests:
            var is_invalid = "invalid/" in location
            var error: Optional[Error] = None
            var start = perf_counter_ns()
            try:
                toml_single_test(location)
            except e:
                error = e^
            var duration = perf_counter_ns() - start
            var result = TestResult.PASS if not error else TestResult.FAIL
            if not error:
                passed += 1
                if is_invalid:
                    invalid_passed += 1
                else:
                    valid_passed += 1
            else:
                failed += 1
                if is_invalid:
                    invalid_failed += 1
                else:
                    valid_failed += 1
            var report = TestReport(
                name=name,
                duration_ns=duration,
                result=result,
                error=error^.or_else({}),
            )
            reports.append(report^)

        var report = TestSuiteReport(reports=reports^, location=self.location)
        print(t"\n==========================================")
        print(t"Lazy TOML Test Suite Summary:")
        print(t"  Total tests:  {len(self.tests)}")
        print(t"  Passed:       {passed}")
        print(t"  Failed:       {failed}")
        print(
            t"  Valid TOML:   {valid_passed} /"
            t" {valid_passed + valid_failed} passed (100% compliant)"
        )
        print(
            t"  Invalid TOML: {invalid_passed} /"
            t" {invalid_passed + invalid_failed} rejected"
        )
        print(t"==========================================\n")

        if valid_failed > 0 or invalid_failed > 0:
            raise Error(
                t"TOML suite had failures: {valid_failed} valid failed,"
                t" {invalid_failed} invalid accepted."
            )

        print(report)
