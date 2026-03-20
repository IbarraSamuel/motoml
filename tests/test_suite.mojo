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

    @always_inline
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
        return {self.tests^.concat((other^,)), self.location}

    @always_inline("nodebug")
    fn abandon(deinit self):
        pass

    fn run(deinit self) raises:
        comptime size = Variadic.size(Self.ts)
        var reports = List[TestReport](capacity=size)

        comptime for i in range(size):
            comptime full_nm = get_type_name[Self.ts[i]]()
            var name = full_nm[
                byte = full_nm.find("().") + 3 : full_nm.find(", {}")
            ]
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
                error=error^.or_else({}),
            )
            reports.append(report^)

        var report = TestSuiteReport(reports=reports^, location=self.location)

        if report.failures > 0:
            raise Error(report^)

        print(report)
