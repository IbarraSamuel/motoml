from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)
from std.math import isnan
from motoml import (
    parse_toml,
    Mode,
    _Mode,
    Kind,
    KindTag,
    Toml,
)
from motoml.types import tempo


def _check_all_types[
    mode_id: Int, //, mode: _Mode[mode_id]
](doc: Toml[_, mode]) raises:
    # String
    assert_equal(doc["str"].kind(), KindTag.String)
    assert_true(doc["str"].is_kind[Kind.String]())
    assert_equal(doc["str"][Kind.String], "hello friend")
    assert_equal(doc["str"].take[Kind.String](), "hello friend")
    assert_equal(doc["str"].string_span().value(), "hello friend")
    assert_equal(doc["lit"].string_span().value(), "literal\\path")
    assert_equal(doc["esc"][Kind.String], 'hello\n"world"')

    # Integer
    assert_equal(doc["int_v"].kind(), KindTag.Integer)
    assert_true(doc["int_v"].is_kind[Kind.Integer]())
    assert_equal(doc["int_v"][Kind.Integer], 3)
    assert_equal(doc["int_v"].take[Kind.Integer](), 3)

    # No implicit int -> float coercion
    with assert_raises():
        _ = doc["int_v"].take[Kind.Float]()

    # Float, NaN, Inf
    assert_equal(doc["float_v"].kind(), KindTag.Float)
    assert_equal(doc["float_v"][Kind.Float], 3.14)
    assert_equal(doc["nan_v"].kind(), KindTag.Float)
    assert_true(isnan(doc["nan_v"][Kind.Float]))
    assert_equal(doc["inf_v"].kind(), KindTag.Float)
    assert_true(doc["inf_v"][Kind.Float] > 1e300)
    assert_true(doc["ninf_v"][Kind.Float] < -1e300)

    # Bool
    assert_equal(doc["bool_f"].kind(), KindTag.Boolean)
    assert_equal(doc["bool_f"][Kind.Boolean], False)
    assert_equal(doc["bool_t"].take[Kind.Boolean](), True)

    # Temporals
    var expected_date = tempo.Date(year=2022, month=2, day=1)
    assert_equal(doc["date_v"].kind(), KindTag.Date)
    assert_equal(doc["date_v"][Kind.Date], expected_date)

    var expected_time = tempo.Time(hour=22, minute=32, second=4)
    assert_equal(doc["time_v"].kind(), KindTag.Time)
    assert_equal(doc["time_v"][Kind.Time], expected_time)

    var expected_dt = tempo.DateTime.from_string("2022-03-02 03:43:02").take()
    assert_equal(doc["dt_v"].kind(), KindTag.DateTime)
    assert_equal(doc["dt_v"][Kind.DateTime], expected_dt)

    # Array via Kind.Array
    assert_equal(doc["arr"].kind(), KindTag.Array)
    var arr = doc["arr"][Kind.Array]
    assert_equal(len(arr), 3)
    assert_equal(arr[0][Kind.Integer], 1)
    assert_equal(arr[1][Kind.Float], 2.0)
    assert_equal(arr[2][Kind.Boolean], True)

    # Table via Kind.Table and direct chaining
    assert_equal(doc["tbl"].kind(), KindTag.Table)
    var tbl = doc["tbl"][Kind.Table]
    assert_equal(tbl["first"][Kind.Integer], 1)
    assert_equal(tbl["second"][Kind.Float], 2.0)
    assert_equal(tbl["third"][Kind.Boolean], True)
    assert_true("first" in tbl)
    assert_false("missing" in tbl)
    assert_true(Bool(tbl.get("first")))
    assert_false(Bool(tbl.get("missing")))

    assert_equal(doc["outer"]["inner"]["val"][Kind.Integer], 99)

    # Missing view and wrong-kind take raise
    var miss = doc["nonexistent"]
    assert_equal(miss.kind(), KindTag.Missing)
    assert_true(miss.is_missing())
    assert_false(Bool(miss))
    with assert_raises():
        _ = miss.take[Kind.Integer]()
    with assert_raises():
        _ = doc["str"].take[Kind.Integer]()
    with assert_raises():
        _ = doc["int_v"].take[Kind.Table]()
    with assert_raises():
        _ = doc["int_v"].take[Kind.Array]()


comptime ALL_TYPES_SRC = """
    str = "hello friend"
    lit = 'literal\\path'
    esc = "hello\\n\\"world\\""
    int_v = 3
    float_v = 3.14
    nan_v = nan
    inf_v = inf
    ninf_v = -inf
    bool_f = false
    bool_t = true
    date_v = 2022-02-01
    time_v = 22:32:04
    dt_v = 2022-03-02T03:43:02
    arr = [1, 2.0, true]
    [tbl]
    first = 1
    second = 2.0
    third = true
    [outer.inner]
    val = 99
"""


def test_kinds_strict() raises:
    var doc = parse_toml[Mode.Strict](ALL_TYPES_SRC).take()
    _check_all_types(doc.root())


def test_kinds_eager() raises:
    var doc = parse_toml[Mode.Eager](ALL_TYPES_SRC).take()
    _check_all_types(doc.root())


def test_string_span_eager_vs_lazy() raises:
    var real_src = 'plain = "abc"\nesc = "a\\nb"\n'
    var lazy_doc = parse_toml[Mode.Strict](real_src).take()
    assert_true(Bool(lazy_doc["plain"].string_span()))
    assert_false(Bool(lazy_doc["esc"].string_span()))

    var eager_doc = parse_toml[Mode.Eager](real_src).take()
    assert_equal(eager_doc["plain"].string_span().value(), "abc")
    # Eager decodes escaped strings into its arena, so string_span() succeeds.
    assert_equal(eager_doc["esc"].string_span().value(), "a\nb")


def test_to_json_unescaped_strings() raises:
    var src = 'msg = "Hello \\"world\\"\\n\\t\\\\"\n'
    var lazy_doc = parse_toml(src).take()
    var out_lazy = String()
    lazy_doc["msg"].to_json(out_lazy)
    assert_equal(
        out_lazy,
        '{"type": "string", "value": "Hello \\"world\\"\\n\\t\\\\"}',
    )

    var eager_doc = parse_toml[Mode.Eager](src).take()
    var out_eager = String()
    eager_doc["msg"].to_json(out_eager)
    assert_equal(out_eager, out_lazy)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
