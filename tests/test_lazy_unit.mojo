from motoml.lazy import parse_lazy, Validation, Kind
from motoml.types.toml import Toml
from std.testing import TestSuite, assert_true, assert_false, assert_equal


def test_basic_scalars() raises:
    var toml_str = """
    int_dec = 42
    int_neg = -17
    int_hex = 0x2A
    int_oct = 0o755
    int_bin = 0b1101
    int_underscore = 1_000_000
    float_val = 3.1415
    float_exp = 1e6
    float_neg_exp = -2.5e-3
    nan_val = nan
    inf_val = inf
    neg_inf_val = -inf
    bool_true = true
    bool_false = false
    str_val = "hello world"
    lit_val = 'literal string'
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    assert_equal(len(doc), 16)

    # Integer variants
    var int_dec = doc["int_dec"].value()
    assert_true(int_dec.is_int())
    assert_true(int_dec.kind() == Kind.Integer)
    assert_equal(int_dec.as_int().take(), 42)

    var int_neg = doc["int_neg"].value()
    assert_equal(int_neg.as_int().take(), -17)

    var int_hex = doc["int_hex"].value()
    assert_equal(int_hex.as_int().take(), 42)

    var int_oct = doc["int_oct"].value()
    assert_equal(int_oct.as_int().take(), 493)

    var int_bin = doc["int_bin"].value()
    assert_equal(int_bin.as_int().take(), 13)

    var int_und = doc["int_underscore"].value()
    assert_equal(int_und.as_int().take(), 1_000_000)

    # Float variants
    var fl_v = doc["float_val"].value()
    assert_true(fl_v.is_float())
    assert_true(fl_v.kind() == Kind.Float)
    assert_equal(fl_v.as_float().take(), 3.1415)

    var fl_exp = doc["float_exp"].value()
    assert_equal(fl_exp.as_float().take(), 1000000.0)

    var fl_nexp = doc["float_neg_exp"].value()
    assert_equal(fl_nexp.as_float().take(), -0.0025)

    var nan_v = doc["nan_val"].value()
    assert_true(nan_v.kind() == Kind.NaN)

    var inf_v = doc["inf_val"].value()
    assert_true(inf_v.kind() == Kind.Inf)

    var ninf_v = doc["neg_inf_val"].value()
    assert_true(ninf_v.kind() == Kind.Inf)

    # Booleans
    var b_t = doc["bool_true"].value()
    assert_true(b_t.is_bool())
    assert_true(b_t.kind() == Kind.Boolean)
    assert_true(b_t.as_bool().take())

    var b_f = doc["bool_false"].value()
    assert_false(b_f.as_bool().take())

    # Strings
    var s_v = doc["str_val"].value()
    assert_true(s_v.is_string())
    assert_true(s_v.kind() == Kind.String)
    assert_equal(s_v.as_string().take(), "hello world")
    assert_equal(s_v.as_slice().value(), "hello world")

    var lit_v = doc["lit_val"].value()
    assert_equal(lit_v.as_string().take(), "literal string")
    assert_equal(lit_v.as_slice().value(), "literal string")


def test_strings_and_escapes() raises:
    var toml_str = (
        r"""
    plain = "simple"
    escaped = "hello\tworld\nwith \"quotes\" and \\slash\\"
    unicode = "emoji \u0041"
    literal = 'C:\path\without\escapes'
    multiline = """
        + '"""\nLine 1\nLine 2"""'
        + """
    multiline_lit = '''
first line
second line
'''
    """
    )
    var doc = parse_lazy(toml_str.as_bytes()).take()

    # Plain string borrows zero-copy slice
    var plain = doc["plain"].value()
    assert_true(plain.as_slice())
    assert_equal(plain.as_slice().value(), "simple")

    # Escaped string: as_slice() returns None, as_string() resolves escapes
    var escaped = doc["escaped"].value()
    assert_false(escaped.as_slice())
    var esc_str = escaped.as_string().take()
    assert_equal(esc_str, 'hello\tworld\nwith "quotes" and \\slash\\')

    # Unicode escape
    var u_str = doc["unicode"].value().as_string().take()
    assert_equal(u_str, "emoji A")

    # Literal strings preserve backslashes
    var lit = doc["literal"].value()
    assert_true(lit.as_slice())
    assert_equal(lit.as_slice().value(), r"C:\path\without\escapes")

    # Multiline strings
    var ml = doc["multiline"].value().as_string().take()
    assert_equal(ml, "Line 1\nLine 2")

    var mll = doc["multiline_lit"].value().as_string().take()
    assert_equal(mll, "first line\nsecond line\n")


def test_dates_and_times() raises:
    var toml_str = """
    date_val = 2024-11-02
    time_val = 17:30:00
    datetime_local = 2024-11-02T17:30:00
    datetime_tz = 2024-11-02T17:30:00Z
    datetime_offset = 2024-11-02T17:30:00-05:00
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()

    var d = doc["date_val"].value()
    assert_true(d.kind() == Kind.Date)
    var date_obj = d.as_date().take()
    assert_equal(date_obj.year, 2024)
    assert_equal(date_obj.month, 11)
    assert_equal(date_obj.day, 2)

    var t = doc["time_val"].value()
    assert_true(t.kind() == Kind.Time)
    var time_obj = t.as_time().take()
    assert_equal(time_obj.hour, 17)
    assert_equal(time_obj.minute, 30)
    assert_equal(time_obj.second, 0)

    var dtl = doc["datetime_local"].value()
    assert_true(dtl.kind() == Kind.DateTime)
    var dtl_obj = dtl.as_datetime().take()
    assert_true(dtl_obj.is_local)
    assert_equal(dtl_obj.date.year, 2024)

    var dtz = doc["datetime_tz"].value()
    assert_true(dtz.kind() == Kind.DateTime)
    var dtz_obj = dtz.as_datetime().take()
    assert_false(dtz_obj.is_local)


def test_tables_and_arrays() raises:
    var toml_str = """
    [server]
    host = "127.0.0.1"
    port = 8080

    [server.database]
    name = "testdb"

    [[users]]
    name = "alice"
    role = "admin"

    [[users]]
    name = "bob"
    role = "user"
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    var srv = doc["server"].value()
    assert_true(srv.is_table())
    assert_equal(srv["host"].value().as_string().take(), "127.0.0.1")
    assert_equal(srv["port"].value().as_int().take(), 8080)

    var db = srv["database"].value()
    assert_true(db.is_table())
    assert_equal(db["name"].value().as_string().take(), "testdb")

    var users = doc["users"].value()
    assert_true(users.is_array())
    assert_equal(len(users), 2)
    assert_equal(users[0].value()["name"].value().as_string().take(), "alice")
    assert_equal(users[0].value()["role"].value().as_string().take(), "admin")
    assert_equal(users[1].value()["name"].value().as_string().take(), "bob")
    assert_equal(users[1].value()["role"].value().as_string().take(), "user")

    # Missing keys and out of bounds indices
    assert_false(srv["nonexistent"])
    assert_false(users[99])


def test_dotted_keys() raises:
    var toml_str = """
    fruit.apple.color = "red"
    fruit.apple.taste.sweet = true
    site."google.com".ip = "142.250.190.46"
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    var fruit = doc["fruit"].value()
    var apple = fruit["apple"].value()
    assert_equal(apple["color"].value().as_slice().value(), "red")
    assert_true(apple["taste"].value()["sweet"].value().as_bool().take())

    var site = doc["site"].value()
    assert_equal(
        site["google.com"].value()["ip"].value().as_slice().value(),
        "142.250.190.46",
    )


def test_inline_tables_and_arrays() raises:
    var toml_str = """
    arr = [1, 2, 3]
    empty_arr = []
    nested_arr = [[1, 2], [3, 4]]
    inline_tbl = { x = 10, y = 20, label = "coord" }
    nested_tbl = { a = { b = 42 } }
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    var arr = doc["arr"].value()
    assert_equal(len(arr), 3)
    assert_equal(arr[0].value().as_int().take(), 1)
    assert_equal(arr[1].value().as_int().take(), 2)
    assert_equal(arr[2].value().as_int().take(), 3)

    var empty_arr = doc["empty_arr"].value()
    assert_equal(len(empty_arr), 0)

    var narr = doc["nested_arr"].value()
    assert_equal(len(narr), 2)
    assert_equal(narr[0].value()[0].value().as_int().take(), 1)
    assert_equal(narr[1].value()[1].value().as_int().take(), 4)

    var tbl = doc["inline_tbl"].value()
    assert_equal(len(tbl), 3)
    assert_equal(tbl["x"].value().as_int().take(), 10)
    assert_equal(tbl["y"].value().as_int().take(), 20)
    assert_equal(tbl["label"].value().as_slice().value(), "coord")

    var nested_tbl = doc["nested_tbl"].value()
    assert_equal(nested_tbl["a"].value()["b"].value().as_int().take(), 42)


def test_validation_strict_vs_trusted() raises:
    # Valid TOML parses in both modes
    var valid_toml = "a = 1\nb = 2\n"
    var strict_res = parse_lazy[Validation.Strict](valid_toml.as_bytes())
    if case .Ok = strict_res:
        _ = strict_res^.unsafe_take_value()
    else:
        _ = strict_res^.unsafe_take_error()
        raise "Expected strict parse to succeed"

    var trusted_res = parse_lazy[Validation.Trusted](valid_toml.as_bytes())
    if case .Ok = trusted_res:
        _ = trusted_res^.unsafe_take_value()
    else:
        _ = trusted_res^.unsafe_take_error()
        raise "Expected trusted parse to succeed"

    # Duplicate key is rejected in Strict mode
    var dup_toml = "a = 1\na = 2\n"
    var dup_strict = parse_lazy[Validation.Strict](dup_toml.as_bytes())
    if case .Err = dup_strict:
        _ = dup_strict^.unsafe_take_error()
    else:
        _ = dup_strict^.unsafe_take_value()
        raise "Expected duplicate key to fail in strict mode"


def test_to_json_and_to_toml() raises:
    var toml_str = """
    title = "TOML Test"
    count = 10
    enabled = true
    items = ["a", "b"]
    inf_val = inf
    neg_inf_val = -inf
    nan_val = nan
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()

    # to_json streaming
    var json_out = String()
    doc.to_json(json_out)
    assert_true(json_out.startswith("{"))
    assert_true(json_out.endswith("}"))
    assert_true('"title"' in json_out)

    # to_toml AST conversion
    var toml_ast = doc.to_toml()
    if case .Table(ref t) = toml_ast:
        assert_equal(t["title"][String], "TOML Test")
        assert_equal(t["count"][Int], 10)
        assert_equal(t["enabled"][Bool], True)
        assert_equal(t["inf_val"][Float64], Float64.MAX)
        assert_equal(t["neg_inf_val"][Float64], Float64.MIN)
        if case .NaN = t["nan_val"]:
            pass
        else:
            raise "Expected nan_val to be NaN"
    else:
        raise "Expected root toml to be Table"


def assert_lazy_parse_error(input: String) raises:
    var res = parse_lazy(input.as_bytes())
    if case .Err = res:
        _ = res^.unsafe_take_error()
    else:
        _ = res^.unsafe_take_value()
        raise "Expected parse error for malformed input"


def test_malformed_input_returns_error() raises:
    assert_lazy_parse_error('str = "never ending')
    assert_lazy_parse_error("arr = [1, 2, ")
    assert_lazy_parse_error("[server")


def test_escaped_table_header_keys() raises:
    # ["\u0061"] and [a] refer to the same table key "a" -> duplicate in Strict mode
    assert_lazy_parse_error('["\\u0061"]\nx = 1\n[a]\ny = 2\n')
    assert_lazy_parse_error('[a]\nx = 1\n["\\u0061"]\ny = 2\n')

    # Escaped table header lookup and materialization
    var toml_str = '["\\u0061\\u0062"."c\\td"]\nval = 99\n'
    var doc = parse_lazy(toml_str.as_bytes()).take()
    var ab = doc["ab"].value()
    var cd = ab["c\td"].value()
    assert_equal(cd["val"].value().as_int().take(), 99)

    var ast = doc.to_toml()
    if case .Table(ref t) = ast:
        if case .Table(ref t_ab) = t["ab"]:
            if case .Table(ref t_cd) = t_ab["c\td"]:
                assert_equal(t_cd["val"][Int], 99)
            else:
                raise "Expected nested table c\\td"
        else:
            raise "Expected table ab"
    else:
        raise "Expected root table"


def test_spec_edge_cases() raises:
    # 64-bit signed integer boundaries
    var valid_bounds = (
        "max_i64 = 9223372036854775807\nmin_i64 = -9223372036854775808\n"
    )
    var doc = parse_lazy(valid_bounds.as_bytes()).take()
    assert_equal(doc["max_i64"].value().as_int().take(), 9223372036854775807)
    assert_equal(
        doc["min_i64"].value().as_int().take(), -9223372036854775807 - 1
    )

    assert_lazy_parse_error("overflow_pos = 9223372036854775808\n")
    assert_lazy_parse_error("overflow_neg = -9223372036854775809\n")
    assert_lazy_parse_error("overflow_hex = 0x8000000000000000\n")

    # Integer lexical rules
    assert_lazy_parse_error("neg_hex = -0x1\n")
    assert_lazy_parse_error("double_under = 1__0\n")
    assert_lazy_parse_error("leading_zero = 00\n")

    # Leap year rules (Gregorian calendar)
    var valid_dates = (
        "leap1 = 2024-02-29\nleap2 = 2000-02-29\nleap_sec = 23:59:60\n"
    )
    var ddoc = parse_lazy(valid_dates.as_bytes()).take()
    assert_equal(ddoc["leap1"].value().as_date().take().day, 29)
    assert_equal(ddoc["leap2"].value().as_date().take().day, 29)
    assert_equal(ddoc["leap_sec"].value().as_time().take().second, 60.0)

    assert_lazy_parse_error("non_leap1 = 2023-02-29\n")
    assert_lazy_parse_error("non_leap2 = 1900-02-29\n")
    assert_lazy_parse_error("bad_hour = 24:00:00\n")
    assert_lazy_parse_error("bad_leap_sec = 23:59:60.1\n")
    assert_lazy_parse_error("bad_offset = 2024-01-01T00:00:00+25:00\n")

    # Unicode surrogate and out-of-range escapes rejected at parse time
    assert_lazy_parse_error('surrogate = "\\uD800"\n')
    assert_lazy_parse_error('out_of_range = "\\U00110000"\n')


def test_children_iterator_and_validation_levels() raises:
    var toml_str = """
    arr = [10, 20, 30]
    [tbl]
    x = 1
    y = 2
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    var arr = doc["arr"].value()
    assert_equal(len(arr), 3)
    var sum_arr = 0
    for item in arr.children():
        sum_arr += item.as_int().take()
    assert_equal(sum_arr, 60)

    var tbl = doc["tbl"].value()
    assert_equal(len(tbl), 2)
    var sum_tbl = 0
    for entry in tbl.children():
        sum_tbl += entry.as_int().take()
    assert_equal(sum_tbl, 3)

    # Validation levels: Structure catches duplicates without lexical scalar overhead
    var dup = "a = 1\na = 2\n"
    var struct_res = parse_lazy[Validation.Structure](dup.as_bytes())
    if case .Err = struct_res:
        _ = struct_res^.unsafe_take_error()
    else:
        _ = struct_res^.unsafe_take_value()
        raise "Expected Structure validation to reject duplicate key"

    # Lexical catches bad scalars
    var bad_scalar = "a = 1__0\n"
    var lex_res = parse_lazy[Validation.Lexical](bad_scalar.as_bytes())
    if case .Err = lex_res:
        _ = lex_res^.unsafe_take_error()
    else:
        _ = lex_res^.unsafe_take_value()
        raise "Expected Lexical validation to reject invalid integer"


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
