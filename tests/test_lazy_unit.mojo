from motoml import (
    parse_toml,
    parse_toml_file,
    Mode,
    Kind,
    KindTag,
    TomlDocument,
)
from motoml.mmap_file import MappedFile
from std.os import remove
from std.pathlib import Path
from std.reflection import call_location
from std.testing import (
    TestSuite,
    assert_true,
    assert_false,
    assert_equal,
)
from std.math import isnan


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
    var doc = parse_toml(toml_str).take()
    assert_equal(len(doc), 16)

    assert_true(doc["int_dec"].is_kind[Kind.Integer]())
    assert_equal(doc["int_dec"].kind(), KindTag.Integer)
    assert_equal(doc["int_dec"].take[Kind.Integer](), 42)
    assert_equal(doc["int_neg"][Kind.Integer], -17)
    assert_equal(doc["int_hex"][Kind.Integer], 42)
    assert_equal(doc["int_oct"][Kind.Integer], 493)
    assert_equal(doc["int_bin"][Kind.Integer], 13)
    assert_equal(doc["int_underscore"][Kind.Integer], 1_000_000)

    assert_true(doc["float_val"].is_kind[Kind.Float]())
    assert_equal(doc["float_val"].kind(), KindTag.Float)
    assert_equal(doc["float_val"][Kind.Float], 3.1415)
    assert_equal(doc["float_exp"][Kind.Float], 1000000.0)
    assert_equal(doc["float_neg_exp"][Kind.Float], -0.0025)
    assert_equal(doc["nan_val"].kind(), KindTag.Float)
    assert_true(isnan(doc["nan_val"][Kind.Float]))
    assert_true(doc["inf_val"][Kind.Float] > 1e300)
    assert_true(doc["neg_inf_val"][Kind.Float] < -1e300)

    assert_true(doc["bool_true"].is_kind[Kind.Boolean]())
    assert_equal(doc["bool_true"].kind(), KindTag.Boolean)
    assert_true(doc["bool_true"][Kind.Boolean])
    assert_false(doc["bool_false"][Kind.Boolean])

    assert_true(doc["str_val"].is_kind[Kind.String]())
    assert_equal(doc["str_val"].kind(), KindTag.String)
    assert_equal(doc["str_val"][Kind.String], "hello world")
    assert_equal(doc["str_val"].string_span().value(), "hello world")
    assert_equal(doc["lit_val"][Kind.String], "literal string")
    assert_equal(doc["lit_val"].string_span().value(), "literal string")


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
    var doc = parse_toml(toml_str).take()

    assert_true(Bool(doc["plain"].string_span()))
    assert_equal(doc["plain"].string_span().value(), "simple")

    assert_false(Bool(doc["escaped"].string_span()))
    assert_equal(
        doc["escaped"][Kind.String], 'hello\tworld\nwith "quotes" and \\slash\\'
    )
    assert_equal(doc["unicode"][Kind.String], "emoji A")
    assert_true(Bool(doc["literal"].string_span()))
    assert_equal(
        doc["literal"].string_span().value(), r"C:\path\without\escapes"
    )
    assert_equal(doc["multiline"][Kind.String], "Line 1\nLine 2")
    assert_equal(doc["multiline_lit"][Kind.String], "first line\nsecond line\n")


def test_dates_and_times() raises:
    var toml_str = """
    date_val = 2024-11-02
    time_val = 17:30:00
    datetime_local = 2024-11-02T17:30:00
    datetime_tz = 2024-11-02T17:30:00Z
    datetime_offset = 2024-11-02T17:30:00-05:00
    """
    var doc = parse_toml(toml_str).take()

    var d = doc["date_val"]
    assert_equal(d.kind(), KindTag.Date)
    var date_obj = d[Kind.Date]
    assert_equal(date_obj.year, 2024)
    assert_equal(date_obj.month, 11)
    assert_equal(date_obj.day, 2)

    var t = doc["time_val"]
    assert_equal(t.kind(), KindTag.Time)
    var time_obj = t[Kind.Time]
    assert_equal(time_obj.hour, 17)
    assert_equal(time_obj.minute, 30)
    assert_equal(time_obj.second, 0)

    var dtl = doc["datetime_local"]
    assert_equal(dtl.kind(), KindTag.DateTime)
    var dtl_obj = dtl[Kind.DateTime]
    assert_true(dtl_obj.is_local)
    assert_equal(dtl_obj.date.year, 2024)

    var dtz = doc["datetime_tz"]
    assert_equal(dtz.kind(), KindTag.DateTime)
    assert_false(dtz[Kind.DateTime].is_local)


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
    var doc = parse_toml(toml_str).take()
    var srv = doc["server"]
    assert_true(srv.is_kind[Kind.Table]())
    assert_equal(srv["host"][Kind.String], "127.0.0.1")
    assert_equal(srv["port"][Kind.Integer], 8080)

    var db = srv["database"]
    assert_true(db.is_kind[Kind.Table]())
    assert_equal(db["name"][Kind.String], "testdb")

    var users = doc["users"]
    assert_true(users.is_kind[Kind.Array]())
    assert_equal(len(users), 2)
    assert_equal(users[0]["name"][Kind.String], "alice")
    assert_equal(users[0]["role"][Kind.String], "admin")
    assert_equal(users[1]["name"][Kind.String], "bob")
    assert_equal(users[1]["role"][Kind.String], "user")

    assert_false(Bool(srv.get("nonexistent")))
    assert_true(srv["nonexistent"].is_missing())
    assert_false(Bool(users.get(99)))
    assert_true(users[99].is_missing())


def test_dotted_keys() raises:
    var toml_str = """
    fruit.apple.color = "red"
    fruit.apple.taste.sweet = true
    site."google.com".ip = "142.250.190.46"
    """
    var doc = parse_toml(toml_str).take()
    assert_equal(doc["fruit"]["apple"]["color"][Kind.String], "red")
    assert_true(doc["fruit"]["apple"]["taste"]["sweet"][Kind.Boolean])
    assert_equal(doc["site"]["google.com"]["ip"][Kind.String], "142.250.190.46")


def test_inline_tables_and_arrays() raises:
    var toml_str = """
    arr = [1, 2, 3]
    empty_arr = []
    nested_arr = [[1, 2], [3, 4]]
    inline_tbl = { x = 10, y = 20, label = "coord" }
    nested_tbl = { a = { b = 42 } }
    """
    var doc = parse_toml(toml_str).take()
    var arr = doc["arr"]
    assert_equal(len(arr), 3)
    assert_equal(arr[0][Kind.Integer], 1)
    assert_equal(arr[1][Kind.Integer], 2)
    assert_equal(arr[2][Kind.Integer], 3)

    assert_equal(len(doc["empty_arr"]), 0)

    var narr = doc["nested_arr"]
    assert_equal(len(narr), 2)
    assert_equal(narr[0][0][Kind.Integer], 1)
    assert_equal(narr[1][1][Kind.Integer], 4)

    var tbl = doc["inline_tbl"]
    assert_equal(len(tbl), 3)
    assert_equal(tbl["x"][Kind.Integer], 10)
    assert_equal(tbl["y"][Kind.Integer], 20)
    assert_equal(tbl["label"].string_span().value(), "coord")
    assert_equal(doc["nested_tbl"]["a"]["b"][Kind.Integer], 42)


def test_validation_strict_vs_trusted() raises:
    var valid_toml = "a = 1\nb = 2\n"
    var strict_res = parse_toml[Mode.Strict](valid_toml)
    if case .Ok = strict_res:
        _ = strict_res^.unsafe_take_value()
    else:
        _ = strict_res^.unsafe_take_error()
        raise "Expected strict parse to succeed"

    var trusted_res = parse_toml[Mode.Trusted](valid_toml)
    if case .Ok = trusted_res:
        _ = trusted_res^.unsafe_take_value()
    else:
        _ = trusted_res^.unsafe_take_error()
        raise "Expected trusted parse to succeed"

    var dup_toml = "a = 1\na = 2\n"
    var dup_strict = parse_toml[Mode.Strict](dup_toml)
    if case .Err = dup_strict:
        _ = dup_strict^.unsafe_take_error()
    else:
        _ = dup_strict^.unsafe_take_value()
        raise "Expected duplicate key to fail in strict mode"


def test_to_json_eager_and_lazy() raises:
    var toml_str = """
    title = "TOML Test"
    count = 10
    enabled = true
    items = ["a", "b"]
    inf_val = inf
    neg_inf_val = -inf
    nan_val = nan
    """
    var lazy_doc = parse_toml(toml_str).take()
    var eager_doc = parse_toml[Mode.Eager](toml_str).take()

    var j_lazy = String()
    var j_eager = String()
    lazy_doc.to_json(j_lazy)
    eager_doc.to_json(j_eager)
    assert_equal(j_lazy, j_eager)
    assert_true(j_lazy.startswith("{"))
    assert_true(j_lazy.endswith("}"))
    assert_true('"title"' in j_lazy)


def assert_lazy_parse_error(input: String) raises:
    var res = parse_toml(input)
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
    assert_lazy_parse_error('["\\u0061"]\nx = 1\n[a]\ny = 2\n')
    assert_lazy_parse_error('[a]\nx = 1\n["\\u0061"]\ny = 2\n')

    var toml_str = '"e\\nf" = "v\\t1"\n["\\u0061\\u0062"."c\\td"]\nval = 99\n'
    var doc = parse_toml(toml_str).take()
    assert_equal(doc["ab"]["c\td"]["val"][Kind.Integer], 99)
    assert_equal(doc["e\nf"][Kind.String], "v\t1")

    var edoc = parse_toml[Mode.Eager](toml_str).take()
    assert_equal(edoc["ab"]["c\td"]["val"][Kind.Integer], 99)
    assert_equal(edoc["e\nf"][Kind.String], "v\t1")

    var seen_keys = List[String]()
    for k in edoc.keys():
        seen_keys.append(k)
    assert_equal(len(seen_keys), 2)
    assert_equal(seen_keys[0], "e\nf")
    assert_equal(seen_keys[1], "ab")

    var j_lazy = String()
    var j_eager = String()
    doc.to_json(j_lazy)
    edoc.to_json(j_eager)
    assert_equal(j_lazy, j_eager)


def test_spec_edge_cases() raises:
    var valid_bounds = (
        "max_i64 = 9223372036854775807\nmin_i64 = -9223372036854775808\n"
    )
    var doc = parse_toml(valid_bounds).take()
    assert_equal(doc["max_i64"][Kind.Integer], 9223372036854775807)
    assert_equal(doc["min_i64"][Kind.Integer], -9223372036854775807 - 1)

    assert_lazy_parse_error("overflow_pos = 9223372036854775808\n")
    assert_lazy_parse_error("overflow_neg = -9223372036854775809\n")
    assert_lazy_parse_error("overflow_hex = 0x8000000000000000\n")
    assert_lazy_parse_error("neg_hex = -0x1\n")
    assert_lazy_parse_error("double_under = 1__0\n")
    assert_lazy_parse_error("leading_zero = 00\n")

    var valid_dates = (
        "leap1 = 2024-02-29\nleap2 = 2000-02-29\nleap_sec = 23:59:60\n"
    )
    var ddoc = parse_toml(valid_dates).take()
    assert_equal(ddoc["leap1"][Kind.Date].day, 29)
    assert_equal(ddoc["leap2"][Kind.Date].day, 29)
    assert_equal(ddoc["leap_sec"][Kind.Time].second, 60.0)

    assert_lazy_parse_error("non_leap1 = 2023-02-29\n")
    assert_lazy_parse_error("non_leap2 = 1900-02-29\n")
    assert_lazy_parse_error("bad_hour = 24:00:00\n")
    assert_lazy_parse_error("bad_leap_sec = 23:59:60.1\n")
    assert_lazy_parse_error("bad_offset = 2024-01-01T00:00:00+25:00\n")
    assert_lazy_parse_error('surrogate = "\\uD800"\n')
    assert_lazy_parse_error('out_of_range = "\\U00110000"\n')


def test_iterators_and_validation_levels() raises:
    var toml_str = """
    arr = [10, 20, 30]
    [tbl]
    x = 1
    y = 2
    """
    var doc = parse_toml(toml_str).take()
    var arr = doc["arr"]
    assert_equal(len(arr), 3)
    var sum_arr = 0
    for item in arr:
        sum_arr += item[Kind.Integer]
    assert_equal(sum_arr, 60)

    var tbl = doc["tbl"]
    assert_equal(len(tbl), 2)
    var sum_tbl = 0
    for entry in tbl:
        sum_tbl += entry[Kind.Integer]
    assert_equal(sum_tbl, 3)

    var item_sum = 0
    for _, val in tbl.items():
        item_sum += val[Kind.Integer]
    assert_equal(item_sum, 3)

    # Validation levels: Structure catches duplicates without lexical scalar overhead
    var dup = "a = 1\na = 2\n"
    var struct_res = parse_toml[Mode.Structure](dup)
    if case .Err = struct_res:
        _ = struct_res^.unsafe_take_error()
    else:
        _ = struct_res^.unsafe_take_value()
        raise "Expected Structure validation to reject duplicate key"

    # Lexical catches bad scalars
    var bad_scalar = "a = 1__0\n"
    var lex_res = parse_toml[Mode.Lexical](bad_scalar)
    if case .Err = lex_res:
        _ = lex_res^.unsafe_take_error()
    else:
        _ = lex_res^.unsafe_take_value()
        raise "Expected Lexical validation to reject invalid integer"


def _make_eager_doc_from_temporary() raises -> TomlDocument[Mode.Eager]:
    var tmp = String(
        'title = "escaped\\nvalue"\n'
        '"k\\t1" = 42\n'
        "f = -12.5\n"
        "b = true\n"
        "d = 2025-07-04\n"
        "t = 12:34:56.789\n"
        "dt = 2025-07-04T12:34:56-04:00\n"
        "[[aot]]\n"
        "n = 10\n"
        "[aot.sub]\n"
        "ok = true\n"
        "[[aot]]\n"
        "n = 20\n"
    )
    var doc = parse_toml[Mode.Eager](tmp).take()
    # Mutate/overwrite tmp in place to ensure no dangling reference exists.
    tmp = String("ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ")
    _ = tmp^
    return doc^


def test_eager_outlives_freed_source() raises:
    var doc = _make_eager_doc_from_temporary()
    assert_equal(doc["title"][Kind.String], "escaped\nvalue")
    assert_equal(doc["title"].string_span().value(), "escaped\nvalue")
    assert_equal(doc["k\t1"][Kind.Integer], 42)
    assert_equal(doc["f"][Kind.Float], -12.5)
    assert_equal(doc["b"][Kind.Boolean], True)
    assert_equal(doc["d"][Kind.Date].year, 2025)
    assert_equal(doc["t"][Kind.Time].hour, 12)
    assert_equal(doc["dt"][Kind.DateTime].offset.hour, 4)
    assert_false(doc["dt"][Kind.DateTime].offset.positive)
    assert_equal(len(doc["aot"]), 2)
    assert_equal(doc["aot"][0]["n"][Kind.Integer], 10)
    assert_true(doc["aot"][0]["sub"]["ok"][Kind.Boolean])
    assert_equal(doc["aot"][1]["n"][Kind.Integer], 20)
    var j = String()
    doc.to_json(j)
    assert_true('"title"' in j)


def test_toml_file_strict_and_eager() raises:
    var tmp_path = "/tmp/motoml_test_toml_file.toml"
    with open(tmp_path, "w") as f:
        f.write('msg = "from\\tfile"\nnums = [10, 20, 30]\n')

    var tf_lazy = parse_toml_file(tmp_path)
    assert_equal(tf_lazy["msg"][Kind.String], "from\tfile")
    assert_equal(tf_lazy["nums"][2][Kind.Integer], 30)

    var tf_eager = parse_toml_file[Mode.Eager](tmp_path)
    remove(tmp_path)
    assert_equal(tf_eager["msg"][Kind.String], "from\tfile")
    assert_equal(tf_eager["nums"][1][Kind.Integer], 20)


def test_utf8_chunk_recovery_and_toml11_cr() raises:
    var doc_s = String()
    for i in range(6):
        doc_s += (
            "pad_key_"
            + String(i)
            + ' = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n'
        )
    doc_s += 'utf8_mid = "héllo € 🚀 世界"\n'
    doc_s += "# comment with UTF-8: café 日本語 🎉\n"
    for i in range(6):
        doc_s += (
            "tail_key_"
            + String(i)
            + ' = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"\n'
        )

    var doc = parse_toml(doc_s).take()
    assert_equal(doc["utf8_mid"][Kind.String], "héllo € 🚀 世界")

    var esc_doc_s = (
        'ml = """\nhello "inner" ""double"" \\\n  '
        ' world\\e\\x01\\x00\\u20ac\\U0001f680"""\nctrl_lit ='
        " 'raw\ttab'\n\"k\\e\\x22\" = true\n"
    )
    var d_strict = parse_toml[Mode.Strict](esc_doc_s).take()
    var d_trusted = parse_toml[Mode.Trusted](esc_doc_s).take()
    var d_eager = parse_toml[Mode.Eager](esc_doc_s).take()
    var j_strict = String()
    var j_trusted = String()
    var j_eager = String()
    d_strict.to_json(j_strict)
    d_trusted.to_json(j_trusted)
    d_eager.to_json(j_eager)
    assert_equal(j_strict, j_trusted)
    assert_equal(j_strict, j_eager)

    var bad_utf8 = List[Byte](capacity=doc_s.byte_length() + 4)
    for b in doc_s.as_bytes():
        bad_utf8.append(b)
    bad_utf8.append(Byte(ord("#")))
    bad_utf8.append(Byte(0xFF))
    bad_utf8.append(Byte(ord("\n")))
    var utf8_err = parse_toml(StringSpan(unsafe_from_utf8=Span(bad_utf8)))
    if case .Err = utf8_err:
        _ = utf8_err^.unsafe_take_error()
    else:
        _ = utf8_err^.unsafe_take_value()
        raise "Expected Strict parser to reject invalid UTF-8 past 512 bytes"

    assert_lazy_parse_error("arr = [1,\r2]\n")
    var nul_arr = String("arr = [1, # bad") + "\0" + "\n2]\n"
    assert_lazy_parse_error(nul_arr)


def test_all_validation_modes_match_valid_suite() raises:
    var loc = call_location().file_name()
    var tests_dir = Path(loc[byte = : loc.rfind("/")])
    var toml_dir = tests_dir / "toml_files" / "tests"
    var manifest = MappedFile(toml_dir / "files-toml-1.1.0")
    var v11_files = manifest.unsafe_view().splitlines()

    var checked = 0
    for fpath in v11_files:
        var spath = String(t"{toml_dir}/{fpath}")
        if not spath.endswith(".toml") or "invalid/" in spath:
            continue
        var fmap = MappedFile(Path(spath))
        var view = fmap.unsafe_view()
        var de = parse_toml[Mode.Eager](view).take()
        var ds = parse_toml[Mode.Strict](view).take()
        var dl = parse_toml[Mode.Lexical](view).take()
        var dt = parse_toml[Mode.Structure](view).take()
        var dx = parse_toml[Mode.Trusted](view).take()
        var je = String()
        var js = String()
        var jl = String()
        var jt = String()
        var jx = String()
        de.to_json(je)
        ds.to_json(js)
        dl.to_json(jl)
        dt.to_json(jt)
        dx.to_json(jx)
        assert_equal(js, je)
        assert_equal(js, jl)
        assert_equal(js, jt)
        assert_equal(js, jx)
        checked += 1
    assert_true(checked >= 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
