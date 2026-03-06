from std.reflection import (
    get_function_name,
    get_type_name,
    call_location,
    SourceLocation,
)
from std.testing.suite import (
    TestReport,
    TestResult,
    TestSuiteReport,
)
from std.algorithm import parallelize
from std.time import perf_counter_ns
from std.runtime.asyncrt import TaskGroup

from std.python import PythonObject, Python


@fieldwise_init
@explicit_destroy("run() or abandon() the TestSuite")
struct UnifiedTestSuite[*ts: Movable](Movable):
    var tests: Tuple[*Self.ts]
    var location: SourceLocation

    fn __init__(
        out self: UnifiedTestSuite[], location: Optional[SourceLocation] = None
    ):
        self.tests = {}
        self.location = location.or_else(call_location())

    fn test(
        deinit self, var other: Some[fn() raises unified]
    ) -> UnifiedTestSuite[
        *Variadic.concat_types[Self.ts, Variadic.types[type_of(other)]]
    ]:
        return {self.tests.concat((other^,)), self.location}

    @always_inline("nodebug")
    fn abandon(deinit self):
        pass

    fn run(deinit self) raises:
        comptime size = Variadic.size(Self.ts)
        var reports = List[TestReport](capacity=size)

        comptime for i in range(size):
            comptime full_nm = get_type_name[Self.ts[i]]()
            var name = full_nm[full_nm.find("().") + 3 : full_nm.find(", {}")]
            var error: Optional[Error] = None
            ref test = self.tests[i]
            ref test_fn = trait_downcast[fn() raises unified](test)
            var start = perf_counter_ns()
            try:
                test_fn()
            except e:
                error = {e^}
            var duration = perf_counter_ns() - start
            var result = TestResult.PASS if not error else TestResult.FAIL
            var report = TestReport(
                name=name,
                duration_ns=duration,
                result=result,
                error=error.or_else({}),
            )
            reports.append(report^)

        var report = TestSuiteReport(reports=reports^, location=self.location)

        if report.failures > 0:
            raise Error(report^)

        print(report)


@fieldwise_init
@explicit_destroy("run() or abandon() the TestSuite")
struct PyTestSuite(Movable):
    var tests: List[Tuple[StaticString, fn(PythonObject) raises]]
    var location: SourceLocation

    fn __init__(
        out self: PyTestSuite, location: Optional[SourceLocation] = None
    ):
        self.tests = {}
        self.location = location.or_else(call_location())

    fn test[
        func: fn(PythonObject) raises
    ](mut self, name: Optional[StaticString] = None):
        self.tests.append((name.or_else(get_function_name[func]()), func))

    fn abandon(deinit self):
        pass

    fn run(deinit self) raises:
        # var size = len(self.tests)
        # var dummy_report = TestReport(
        #     name={},
        #     duration_ns={},
        #     result=TestResult.FAIL,
        #     error={},
        # )
        # var reports = List[TestReport](length=size, fill=dummy_report)
        var reports = List[TestReport](capacity=len(self.tests))
        # var tg = TaskGroup()
        var json = Python.import_module("json")

        for name, test in self.tests:
            var error: Optional[Error] = None
            var start = perf_counter_ns()
            try:
                test(json)
            except e:
                error = {e^}
            var duration = perf_counter_ns() - start
            var result = TestResult.PASS if not error else TestResult.FAIL
            var report = TestReport(
                name=name,
                duration_ns=duration,
                result=result,
                error=error.or_else({}),
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
