from std.reflection import (
    get_function_name,
    call_location,
    SourceLocation,
    reflect,
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

    @always_inline
    def __init__(
        out self: UnifiedTestSuite[], location: Optional[SourceLocation] = None
    ):
        self.tests = {}
        self.location = location.or_else(call_location())

    def test(
        deinit self, var other: Some[def() raises]
    ) -> UnifiedTestSuite[
        *TypeList._concat[Self.ts.values, TypeList.of[type_of(other)].values]()
    ]:
        return {self.tests^.concat((other^,)), self.location}

    @always_inline("nodebug")
    def abandon(deinit self):
        pass

    def run(deinit self) raises:
        comptime size = Self.ts.size
        var reports = List[TestReport](capacity=size)

        comptime for i in range(size):
            comptime full_nm = reflect[Self.ts[i]].name()
            var name = full_nm[
                byte = full_nm.find("().") + 3 : full_nm.find(", {}")
            ]
            var error: Optional[Error] = None
            ref test = self.tests[i]
            ref test_fn = trait_downcast[def() raises](test)
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
                error=error^.or_else({}),
            )
            reports.append(report^)

        var report = TestSuiteReport(reports=reports^, location=self.location)

        if report.failures > 0:
            raise Error(report^)

        print(report)


@fieldwise_init
@explicit_destroy("run() or abandon() the TestSuite")
struct TestSuite(Movable):
    var tests: List[Tuple[StaticString, def() raises thin]]
    var location: SourceLocation

    @always_inline
    def __init__(out self, location: Optional[SourceLocation] = None):
        self.tests = {}
        self.location = location.or_else(call_location())

    def test(
        mut self, name: StaticString, var t: def() raises thin
    ) -> ref[self] Self:
        self.tests.append((name, t))
        return self

    @always_inline("nodebug")
    def abandon(deinit self):
        pass

    def run(deinit self) raises:
        var size = len(self.tests)
        var reports = List[TestReport](capacity=size)

        for full_nm, test_fn in self.tests:
            var name = full_nm[
                byte = full_nm.find("().") + 3 : full_nm.find(", {}")
            ]
            var error: Optional[Error] = None
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
                error=error^.or_else({}),
            )
            reports.append(report^)

        var report = TestSuiteReport(reports=reports^, location=self.location)

        if report.failures > 0:
            raise Error(report^)

        print(report)
