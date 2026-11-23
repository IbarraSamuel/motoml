"""Public view, Kind, container, iterator, span, and temporal type tests."""

from motoml import (
    Date,
    DateTime,
    Kind,
    KindTag,
    Mode,
    Offset,
    Time,
    Toml,
    TomlArray,
    TomlTable,
    parse_toml,
)
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)
from std.utils.numerics import isinf, isnan


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


def _check_all_views[mode: Mode](doc: Toml[_, mode]) raises:
    # String
    assert_equal(doc["str"].kind(), KindTag.String)
    assert_true(doc["str"].kind() == Kind.String)
    assert_true(Kind.String == doc["str"].kind())
    assert_true(doc["str"].is_kind[Kind.String]())
    assert_equal(doc["str"][Kind.String], "hello friend")
    assert_equal(doc["str"].take[String](), "hello friend")
    assert_equal(doc["str"].string_span().value(), "hello friend")
    assert_equal(doc["lit"].string_span().value(), "literal\\path")
    assert_equal(doc["esc"][Kind.String], 'hello\n"world"')

    # Integer (no implicit int -> float coercion)
    assert_equal(doc["int_v"].kind(), KindTag.Integer)
    assert_equal(doc["int_v"][Kind.Integer], 3)
    assert_equal(doc["int_v"].take[Int](), 3)
    with assert_raises():
        _ = doc["int_v"].take[Float64]()

    # Float, NaN, Inf
    assert_equal(doc["float_v"].kind(), KindTag.Float)
    assert_equal(doc["float_v"][Kind.Float], 3.14)
    assert_true(isnan(doc["nan_v"][Kind.Float]))
    assert_true(
        isinf(doc["inf_v"][Kind.Float]) and doc["inf_v"][Kind.Float] > 0.0
    )
    assert_true(
        isinf(doc["ninf_v"][Kind.Float]) and doc["ninf_v"][Kind.Float] < 0.0
    )

    # Bool
    assert_equal(doc["bool_f"].kind(), KindTag.Boolean)
    assert_false(doc["bool_f"][Kind.Boolean])
    assert_true(doc["bool_t"].take[Bool]())

    # Temporals
    assert_equal(doc["date_v"][Kind.Date], Date(year=2022, month=2, day=1))
    assert_equal(doc["time_v"][Kind.Time], Time(hour=22, minute=32, second=4))
    assert_equal(
        doc["dt_v"][Kind.DateTime],
        DateTime.from_string("2022-03-02 03:43:02"),
    )

    # TomlArray
    var arr = doc["arr"][Kind.Array]
    assert_true(Bool(arr))
    assert_equal(len(arr), 3)
    assert_equal(arr[0][Kind.Integer], 1)
    assert_equal(arr[1][Kind.Float], 2.0)
    assert_equal(arr[2][Kind.Boolean], True)
    assert_true(Bool(arr.get(0)))
    assert_false(Bool(arr.get(-1)))
    assert_false(Bool(arr.get(3)))
    assert_true(arr[99].is_missing())

    # TomlTable
    var tbl = doc["tbl"][Kind.Table]
    assert_true(Bool(tbl))
    assert_equal(len(tbl), 3)
    assert_equal(tbl["first"][Kind.Integer], 1)
    assert_equal(tbl["second"][Kind.Float], 2.0)
    assert_equal(tbl["third"][Kind.Boolean], True)
    assert_true("first" in tbl)
    assert_false("missing" in tbl)
    assert_true(Bool(tbl.get("first")))
    assert_false(Bool(tbl.get("missing")))
    assert_equal(doc["outer"]["inner"]["val"][Kind.Integer], 99)

    # Missing propagation & checked take errors
    var miss = doc["nonexistent"]["deep"][0]
    assert_equal(miss.kind(), KindTag.Missing)
    assert_true(miss.is_kind[Kind.Missing]())
    assert_true(miss.is_missing())
    assert_false(Bool(miss))
    assert_equal(len(miss), 0)
    with assert_raises():
        _ = miss.take[Int]()
    with assert_raises():
        _ = doc["str"].take[Int]()
    with assert_raises():
        _ = doc["int_v"].take[TomlTable[doc.origin, mode]]()
    with assert_raises():
        _ = doc["int_v"].take[TomlArray[doc.origin, mode]]()


def test_views_all_modes() raises:
    var d_strict = parse_toml[Mode.Strict](ALL_TYPES_SRC)
    _check_all_views(d_strict.root())

    var d_eager = parse_toml[Mode.Eager](ALL_TYPES_SRC)
    _check_all_views(d_eager.root())

    var d_trusted = parse_toml[Mode.Trusted](ALL_TYPES_SRC)
    _check_all_views(d_trusted.root())


def test_iterators_and_spans() raises:
    var src = 'plain = "abc"\nesc = "a\\nb"\n"k\\t1" = 10\narr = [10, 20, 30]\n'
    var lazy_doc = parse_toml[Mode.Strict](src)
    var eager_doc = parse_toml[Mode.Eager](src)

    # string_span: contiguous in both, escaped only in Eager
    assert_equal(lazy_doc["plain"].string_span().value(), "abc")
    assert_false(Bool(lazy_doc["esc"].string_span()))
    assert_equal(eager_doc["plain"].string_span().value(), "abc")
    assert_equal(eager_doc["esc"].string_span().value(), "a\nb")

    # key_span: escaped key returns None in lazy, Some in Eager
    assert_false(Bool(lazy_doc["k\t1"].key_span()))
    assert_equal(eager_doc["k\t1"].key_span().value(), "k\t1")

    # Array iteration
    var arr_sum = 0
    for elem in lazy_doc["arr"]:
        arr_sum += elem[Kind.Integer]
    assert_equal(arr_sum, 60)

    # Table items & keys iteration preserve document order
    var keys = List[String]()
    for k in lazy_doc.keys():
        keys.append(k)
    assert_equal(len(keys), 4)
    assert_equal(keys[0], "plain")
    assert_equal(keys[1], "esc")
    assert_equal(keys[2], "k\t1")
    assert_equal(keys[3], "arr")

    var item_count = 0
    for k, v in eager_doc.items():
        assert_equal(k, keys[item_count])
        assert_true(Bool(v))
        item_count += 1
    assert_equal(item_count, 4)


def test_temporal_types_and_formatting() raises:
    # Date
    var d = Date.from_string("2026-02-09")
    assert_equal(d, Date(year=2026, month=2, day=9))
    assert_equal(String(d), "2026-02-09")
    assert_equal(String(Date(year=5, month=1, day=2)), "0005-01-02")
    with assert_raises():
        _ = Date.from_string("2023-02-29")

    # Offset (including Z / z fix!)
    assert_equal(Offset.from_string("Z"), Offset.utc)
    assert_equal(Offset.from_string("z"), Offset.utc)
    assert_equal(String(Offset.utc), "Z")
    var off_pos = Offset.from_string("+05:30")
    assert_equal(off_pos, Offset(hour=5, minute=30, positive=True))
    assert_equal(String(off_pos), "+05:30")
    var off_neg = Offset.from_string("-04:00")
    assert_equal(String(off_neg), "-04:00")
    with assert_raises():
        _ = Offset.from_string("+24:00")
    with assert_raises():
        _ = Offset.from_string("invalid")

    # Time nanosecond precision and zero-trimmed formatting
    assert_equal(String(Time(hour=1, minute=2, second=3)), "01:02:03")
    assert_equal(
        String(Time(hour=1, minute=2, second=3, nanosecond=500_000_000)),
        "01:02:03.5",
    )
    assert_equal(
        String(Time(hour=1, minute=2, second=3, nanosecond=50_000_000)),
        "01:02:03.05",
    )
    assert_equal(
        String(Time(hour=1, minute=2, second=3, nanosecond=123_000_000)),
        "01:02:03.123",
    )
    assert_equal(
        String(Time(hour=1, minute=2, second=3, nanosecond=1)),
        "01:02:03.000000001",
    )
    assert_equal(
        Time.from_string("09:08:07.004050600"),
        Time(hour=9, minute=8, second=7, nanosecond=4_050_600),
    )

    # DateTime formatting
    var dt_local = DateTime.from_string("2024-01-02 03:04:05.5")
    assert_equal(String(dt_local), "2024-01-02T03:04:05.5")
    var dt_utc = DateTime.from_string("2024-01-02T03:04:05.123Z")
    assert_equal(String(dt_utc), "2024-01-02T03:04:05.123Z")
    var dt_off = DateTime.from_string("2024-01-02T03:04-07:00")
    assert_equal(String(dt_off), "2024-01-02T03:04:00-07:00")


def test_write_to_and_to_json() raises:
    var src = 'msg = "Hello \\"world\\"\\n\\t\\\\"\nn = 42\n'
    var lazy_doc = parse_toml(src)
    var eager_doc = parse_toml[Mode.Eager](src)

    var out_lazy = String()
    var out_eager = String()
    lazy_doc["msg"].to_json(out_lazy)
    eager_doc["msg"].to_json(out_eager)
    assert_equal(
        out_lazy,
        '{"type": "string", "value": "Hello \\"world\\"\\n\\t\\\\"}',
    )
    assert_equal(out_eager, out_lazy)

    assert_equal(String(lazy_doc["missing"]), "Toml(Missing)")
    assert_equal(String(lazy_doc["n"]), "Toml(42)")
    assert_equal(String(Kind.Integer), "Integer")
    assert_equal(String(Kind.Str), "Str")
    assert_equal(String(KindTag.Table), "Table")
    assert_equal(String(Mode.Strict), "Strict")
    assert_equal(String(Mode.Eager), "Eager")
    assert_equal(String(Mode.Trusted), "Trusted")


def test_zero_copy_str_writers_and_span_iterators() raises:
    var long_esc = 'big = "' + ("abcde\\n" * 120) + '"\n'
    var src = (
        'plain = "zero-copy"\n'
        + "lit = 'raw\\literal'\n"
        + 'esc = "line1\\nline2\\t\\u00e9"\n'
        + '"k\\u005fesc" = 77\n'
        + long_esc
    )
    var sdoc = parse_toml[Mode.Strict](src)
    var edoc = parse_toml[Mode.Eager](src)
    var tdoc = parse_toml[Mode.Trusted](src)

    # Kind.Str zero-copy casts & checks
    assert_true(sdoc["plain"].is_kind[Kind.Str]())
    assert_true(sdoc["lit"].is_kind[Kind.Str]())
    assert_false(sdoc["esc"].is_kind[Kind.Str]())
    assert_true(edoc["esc"].is_kind[Kind.Str]())
    assert_true(sdoc["plain"].kind() == Kind.Str)
    assert_true(Kind.Str == sdoc["plain"].kind())
    assert_false(Kind.Str == Kind.String)

    assert_equal(sdoc["plain"][Kind.Str], "zero-copy")
    assert_equal(sdoc["lit"][Kind.Str], "raw\\literal")
    assert_equal(tdoc["plain"][Kind.Str], "zero-copy")
    assert_equal(edoc["plain"][Kind.Str], "zero-copy")
    assert_equal(edoc["esc"][Kind.Str], "line1\nline2\t\u00e9")
    assert_equal(edoc["esc"].as_str(), "line1\nline2\t\u00e9")

    # key(), key_str(), write_string_to(), write_key_to()
    assert_equal(sdoc["k_esc"].key(), "k_esc")
    assert_equal(edoc["k_esc"].key_str(), "k_esc")

    var buf = String()
    sdoc["esc"].write_string_to(buf)
    assert_equal(buf, "line1\nline2\t\u00e9")

    var kbuf = String()
    sdoc["k_esc"].write_key_to(kbuf)
    assert_equal(kbuf, "k_esc")

    var big_buf = String()
    sdoc["big"].write_string_to(big_buf)
    assert_equal(big_buf.byte_length(), 6 * 120)

    var bad_trusted = parse_toml[Mode.Trusted]('bad = "oops\\q"\n')
    var err_buf = String()
    with assert_raises():
        bad_trusted["bad"].write_string_to(err_buf)

    # Zero-allocation span iterators (items_span, keys_span, eager_items, eager_keys)
    var span_hits = 0
    var span_misses = 0
    for k_opt, val in sdoc.items_span():
        assert_true(Bool(val))
        if k_opt:
            span_hits += 1
        else:
            span_misses += 1
    assert_equal(span_hits, 4)
    assert_equal(span_misses, 1)

    var kspan_count = 0
    for _ in sdoc.keys_span():
        kspan_count += 1
    assert_equal(kspan_count, 5)

    var eager_keys_out = List[String]()
    for ks in edoc.eager_keys():
        eager_keys_out.append(String(ks))
    assert_equal(len(eager_keys_out), 5)
    assert_equal(eager_keys_out[3], "k_esc")

    var eager_idx = 0
    for ks, val in edoc.eager_items():
        assert_equal(ks, eager_keys_out[eager_idx])
        assert_true(Bool(val))
        eager_idx += 1
    assert_equal(eager_idx, 5)


def test_array_indexing_and_adaptive_key_index() raises:
    # Flat contiguous array (>8), nested small array (<=8), nested slotted array (>8), and AOT (>8)
    var s = String("flat = [")
    for i in range(25):
        if i > 0:
            s += ", "
        s += String(i * 10)
    s += "]\nsmall_nested = [[1, 2], [3, 4], [5, 6]]\nbig_nested = ["
    for i in range(14):
        if i > 0:
            s += ", "
        s += "[" + String(i) + ", " + String(i + 100) + "]"
    s += "]\n"
    for i in range(12):
        s += "[[aot]]\nid = " + String(i) + "\n"
    s += "[big_tbl]\n"
    for i in range(20):
        if i == 5:
            s += '"k\\u005f5" = 500\n'
        else:
            s += "k_" + String(i) + " = " + String(i * 100) + "\n"

    var ldoc = parse_toml[Mode.Strict](s)
    var edoc = parse_toml[Mode.Eager](s)

    for i in range(25):
        assert_equal(ldoc["flat"][i][Kind.Integer], i * 10)
        assert_equal(edoc["flat"][i][Kind.Integer], i * 10)

    assert_equal(ldoc["small_nested"][2][1][Kind.Integer], 6)
    assert_equal(edoc["small_nested"][2][1][Kind.Integer], 6)

    for i in range(14):
        assert_equal(ldoc["big_nested"][i][1][Kind.Integer], i + 100)
        assert_equal(edoc["big_nested"][i][1][Kind.Integer], i + 100)

    for i in range(12):
        assert_equal(ldoc["aot"][i]["id"][Kind.Integer], i)
        assert_equal(edoc["aot"][i]["id"][Kind.Integer], i)

    for i in range(20):
        var key = "k_" + String(i)
        assert_equal(ldoc["big_tbl"][key][Kind.Integer], i * 100)
        assert_equal(edoc["big_tbl"][key][Kind.Integer], i * 100)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
