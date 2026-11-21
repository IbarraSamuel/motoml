"""Core parsing tests: scalars, strings, temporals, containers, modes, files, Result, errors."""

from motoml import (
    Date,
    DateTime,
    Kind,
    KindTag,
    Mode,
    Offset,
    Time,
    TomlDocument,
    _Mode,
    parse_toml,
    parse_toml_file,
    try_parse_toml,
)
from motoml.mmap_file import MappedFile
from std.os import remove
from std.pathlib import Path
from std.reflection import call_location
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_true,
)
from std.utils.numerics import isinf, isnan


def test_empty_and_comments_only() raises:
    for src in ["", "   \t\n\r\n# just a comment\n# second\r\n"]:
        var d_strict = parse_toml[Mode.Strict](src)
        assert_equal(d_strict.root().kind(), KindTag.Table)
        assert_equal(len(d_strict), 0)

        var d_eager = parse_toml[Mode.Eager](src)
        assert_equal(d_eager.root().kind(), KindTag.Table)
        assert_equal(len(d_eager), 0)

        var d_trusted = parse_toml[Mode.Trusted](src)
        assert_equal(d_trusted.root().kind(), KindTag.Table)
        assert_equal(len(d_trusted), 0)


def test_basic_scalars_all_modes() raises:
    var src = """
    int_dec = 42
    int_neg = -17
    int_plus = +99
    int_hex = 0x2A
    int_oct = 0o755
    int_bin = 0b1101
    int_underscore = 1_000_000
    float_val = 3.1415
    float_exp = 1e6
    float_neg_exp = -2.5e-3
    float_under = 1_234.56_78
    nan_val = nan
    inf_val = inf
    pos_inf_val = +inf
    neg_inf_val = -inf
    bool_true = true
    bool_false = false
    str_val = "hello world"
    lit_val = 'literal string'
    """

    def check[
        mode_id: Int, //, mode: _Mode[mode_id]
    ](doc: TomlDocument[mode, _]) raises:
        assert_equal(len(doc), 19)
        assert_equal(doc["int_dec"][Kind.Integer], 42)
        assert_equal(doc["int_neg"][Kind.Integer], -17)
        assert_equal(doc["int_plus"][Kind.Integer], 99)
        assert_equal(doc["int_hex"][Kind.Integer], 42)
        assert_equal(doc["int_oct"][Kind.Integer], 493)
        assert_equal(doc["int_bin"][Kind.Integer], 13)
        assert_equal(doc["int_underscore"][Kind.Integer], 1_000_000)

        assert_equal(doc["float_val"][Kind.Float], 3.1415)
        assert_equal(doc["float_exp"][Kind.Float], 1000000.0)
        assert_equal(doc["float_neg_exp"][Kind.Float], -0.0025)
        assert_equal(doc["float_under"][Kind.Float], 1234.5678)
        assert_true(isnan(doc["nan_val"][Kind.Float]))
        assert_true(
            isinf(doc["inf_val"][Kind.Float])
            and doc["inf_val"][Kind.Float] > 0.0
        )
        assert_true(
            isinf(doc["pos_inf_val"][Kind.Float])
            and doc["pos_inf_val"][Kind.Float] > 0.0
        )
        assert_true(
            isinf(doc["neg_inf_val"][Kind.Float])
            and doc["neg_inf_val"][Kind.Float] < 0.0
        )

        assert_true(doc["bool_true"][Kind.Boolean])
        assert_false(doc["bool_false"][Kind.Boolean])
        assert_equal(doc["str_val"][Kind.String], "hello world")
        assert_equal(doc["lit_val"][Kind.String], "literal string")

    check(parse_toml[Mode.Strict](src))
    check(parse_toml[Mode.Eager](src))
    check(parse_toml[Mode.Trusted](src))


def test_strings_unicode_and_multiline_quotes() raises:
    var src = (
        r'''
    plain = "Café 🔥"
    escaped = "hello\tworld\nwith \"quotes\" and \\slash\\"
    unicode = "emoji \u0041 \x42 \U0001F680 \e"
    literal = 'C:\path\without\escapes'
    str4 = """Here are two quotation marks: "". Simple enough."""
    str5 = """Here are three quotation marks: ""\"."""
    str6 = """Here are fifteen quotation marks: ""\"""\"""\"""\"""\"."""
    str7 = """"This," she said, "is just a pointless statement.""""
    ml_trim = """
The quick brown \
    fox"""
    '''
        + "ml_lit = '''\nfirst line\nsecond line\n'''\n"
    )
    var d_strict = parse_toml[Mode.Strict](src)
    var d_eager = parse_toml[Mode.Eager](src)

    assert_equal(d_strict["plain"][Kind.String], "Café 🔥")
    assert_equal(
        d_strict["escaped"][Kind.String],
        'hello\tworld\nwith "quotes" and \\slash\\',
    )
    assert_equal(d_strict["unicode"][Kind.String], "emoji A B 🚀 \x1b")
    assert_equal(d_strict["literal"][Kind.String], r"C:\path\without\escapes")
    assert_equal(
        d_strict["str4"][Kind.String],
        'Here are two quotation marks: "". Simple enough.',
    )
    assert_equal(
        d_strict["str5"][Kind.String], 'Here are three quotation marks: """.'
    )
    assert_equal(
        d_strict["str6"][Kind.String],
        'Here are fifteen quotation marks: """"""""""""""".',
    )
    assert_equal(
        d_strict["str7"][Kind.String],
        '"This," she said, "is just a pointless statement."',
    )
    assert_equal(d_strict["ml_trim"][Kind.String], "The quick brown fox")
    assert_equal(d_strict["ml_lit"][Kind.String], "first line\nsecond line\n")

    var j_strict = String()
    var j_eager = String()
    d_strict.to_json(j_strict)
    d_eager.to_json(j_eager)
    assert_equal(j_strict, j_eager)


def test_dates_times_and_datetimes() raises:
    var src = """
    d = 2024-11-02
    t_full = 17:30:05
    t_short = 17:30
    t_frac = 17:30:05.123456789
    t_over_ns = 17:30:05.123456789999
    dt_local = 2024-11-02T17:30:00
    dt_space = 2024-11-02 17:30:00
    dt_utc = 2024-11-02T17:30:00Z
    dt_offset = 2024-11-02T17:30:00.5-05:30
    dt_short_off = 2024-11-02T17:30+01:00
    """
    var d_strict = parse_toml[Mode.Strict](src)
    var d_eager = parse_toml[Mode.Eager](src)

    assert_equal(d_strict["d"][Kind.Date], Date(year=2024, month=11, day=2))
    assert_equal(
        d_strict["t_full"][Kind.Time], Time(hour=17, minute=30, second=5)
    )
    assert_equal(
        d_strict["t_short"][Kind.Time], Time(hour=17, minute=30, second=0)
    )
    assert_equal(
        d_strict["t_frac"][Kind.Time],
        Time(hour=17, minute=30, second=5, nanosecond=123_456_789),
    )
    assert_equal(
        d_strict["t_over_ns"][Kind.Time],
        Time(hour=17, minute=30, second=5, nanosecond=123_456_789),
    )
    assert_true(d_strict["dt_local"][Kind.DateTime].is_local)
    assert_true(d_strict["dt_space"][Kind.DateTime].is_local)
    assert_false(d_strict["dt_utc"][Kind.DateTime].is_local)
    assert_equal(d_strict["dt_utc"][Kind.DateTime].offset, Offset.utc)

    var dto = d_strict["dt_offset"][Kind.DateTime]
    assert_false(dto.is_local)
    assert_equal(dto.time.nanosecond, 500_000_000)
    assert_equal(dto.offset, Offset(hour=5, minute=30, positive=False))

    var dts = d_strict["dt_short_off"][Kind.DateTime]
    assert_equal(dts.time, Time(hour=17, minute=30, second=0))
    assert_equal(dts.offset, Offset(hour=1, minute=0, positive=True))

    # Eager matches Strict
    assert_equal(d_eager["t_frac"][Kind.Time], d_strict["t_frac"][Kind.Time])
    assert_equal(d_eager["dt_offset"][Kind.DateTime], dto)


def test_tables_arrays_dotted_and_inline() raises:
    var src = """
    fruit.apple.color = "red"
    fruit.apple.taste.sweet = true
    site."google.com".ip = "142.250.190.46"

    arr = [1, 2, 3,]
    empty_arr = []
    nested_arr = [[1, 2], [3, 4]]
    inline_tbl = {
        x = 10, # TOML 1.1 multiline inline table & comment
        y.z = 20,
        label = "coord", # trailing comma allowed in TOML 1.1
    }

    [server]
    host = "127.0.0.1"
    port = 8080

    [server.database]
    name = "testdb"

    [[users]]
    name = "alice"
    [[users]]
    name = "bob"
    """
    var doc = parse_toml(src)
    assert_equal(doc["fruit"]["apple"]["color"][Kind.String], "red")
    assert_true(doc["fruit"]["apple"]["taste"]["sweet"][Kind.Boolean])
    assert_equal(doc["site"]["google.com"]["ip"][Kind.String], "142.250.190.46")
    assert_equal(len(doc["arr"]), 3)
    assert_equal(len(doc["empty_arr"]), 0)
    assert_equal(doc["nested_arr"][1][1][Kind.Integer], 4)
    assert_equal(doc["inline_tbl"]["x"][Kind.Integer], 10)
    assert_equal(doc["inline_tbl"]["y"]["z"][Kind.Integer], 20)
    assert_equal(doc["inline_tbl"]["label"][Kind.String], "coord")
    assert_equal(doc["server"]["database"]["name"][Kind.String], "testdb")
    assert_equal(len(doc["users"]), 2)
    assert_equal(doc["users"][0]["name"][Kind.String], "alice")
    assert_equal(doc["users"][1]["name"][Kind.String], "bob")


def test_escaped_keys_in_headers_and_entries() raises:
    var src = '"e\\nf" = "v\\t1"\n["\\u0061\\u0062"."c\\td"]\nval = 99\n'
    var d_strict = parse_toml[Mode.Strict](src)
    var d_eager = parse_toml[Mode.Eager](src)
    var d_trusted = parse_toml[Mode.Trusted](src)

    assert_equal(d_strict["ab"]["c\td"]["val"][Kind.Integer], 99)
    assert_equal(d_strict["e\nf"][Kind.String], "v\t1")
    assert_equal(d_eager["ab"]["c\td"]["val"][Kind.Integer], 99)
    assert_equal(d_eager["e\nf"][Kind.String], "v\t1")

    var seen_keys = List[String]()
    for k in d_eager.keys():
        seen_keys.append(k)
    assert_equal(len(seen_keys), 2)
    assert_equal(seen_keys[0], "e\nf")
    assert_equal(seen_keys[1], "ab")

    var j_s = String()
    var j_e = String()
    var j_t = String()
    d_strict.to_json(j_s)
    d_eager.to_json(j_e)
    d_trusted.to_json(j_t)
    assert_equal(j_s, j_e)
    assert_equal(j_s, j_t)


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
    var doc = parse_toml[Mode.Eager](tmp)
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
    assert_equal(doc["t"][Kind.Time].nanosecond, 789_000_000)
    assert_equal(doc["dt"][Kind.DateTime].offset.hour, 4)
    assert_false(doc["dt"][Kind.DateTime].offset.positive)
    assert_equal(len(doc["aot"]), 2)
    assert_equal(doc["aot"][0]["n"][Kind.Integer], 10)
    assert_true(doc["aot"][0]["sub"]["ok"][Kind.Boolean])
    assert_equal(doc["aot"][1]["n"][Kind.Integer], 20)


def test_parse_toml_file_all_modes() raises:
    var tmp_path = "/tmp/motoml_test_toml_file.toml"
    with open(tmp_path, "w") as f:
        f.write('msg = "from\\tfile"\nnums = [10, 20, 30]\n')

    var tf_strict = parse_toml_file[Mode.Strict](tmp_path)
    assert_equal(tf_strict["msg"][Kind.String], "from\tfile")
    assert_equal(tf_strict["nums"][2][Kind.Integer], 30)
    assert_true("msg" in tf_strict)
    assert_equal(len(tf_strict), 2)

    var tf_trusted = parse_toml_file[Mode.Trusted](tmp_path)
    assert_equal(tf_trusted["nums"][0][Kind.Integer], 10)

    var tf_eager = parse_toml_file[Mode.Eager](tmp_path)
    remove(tmp_path)
    # Eager releases mmap immediately, so reading after file deletion works.
    assert_equal(tf_eager["msg"][Kind.String], "from\tfile")
    assert_equal(tf_eager["nums"][1][Kind.Integer], 20)


def test_try_parse_toml_and_result_api() raises:
    var ok_res = try_parse_toml("x = 7\n")
    var ok_is_ok = ok_res.is_ok()
    var ok_is_err = ok_res.is_err()
    var doc = ok_res^.take()
    assert_true(ok_is_ok)
    assert_false(ok_is_err)
    assert_equal(doc["x"][Kind.Integer], 7)

    var err_res = try_parse_toml("a = 1\na = 2\n")
    var err_is_err = err_res.is_err()
    var err_is_ok = err_res.is_ok()
    var err = err_res^.take_error()
    assert_true(err_is_err)
    assert_false(err_is_ok)
    assert_true("2:1" in String(err))
    assert_true("Duplicate key" in String(err))

    # as_optional / or_else / forget
    var opt_ok = try_parse_toml[Mode.Eager]("k = 1\n").as_optional()
    assert_true(Bool(opt_ok))
    var opt_err = try_parse_toml[Mode.Eager]("k = \n").as_optional()
    assert_false(Bool(opt_err))

    var default_doc = parse_toml[Mode.Eager]("fallback = 99\n")
    var fallback = try_parse_toml[Mode.Eager]("bad = [").or_else(default_doc^)
    assert_equal(fallback["fallback"][Kind.Integer], 99)

    try_parse_toml("a = 1\n").forget()


def test_error_line_and_column_reporting() raises:
    def expect_err_contains(src: StringSpan, needle: StringSpan) raises:
        var res = try_parse_toml(src)
        var is_err = res.is_err()
        var msg = String(res^.take_error())
        assert_true(is_err)
        assert_true(needle in msg, String(t"Expected '{needle}' in '{msg}'"))

    expect_err_contains("a = 1\nb = 2\nc = [1, 2", "3:")
    expect_err_contains("a = 1\r\na = 2\r\n", "2:1")
    expect_err_contains("a = 1\n\n  bad = 00\n", "3:9")
    expect_err_contains('x = "unclosed', "1:")


def test_all_modes_match_valid_suite() raises:
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
        var ds = parse_toml[Mode.Strict](view)
        var de = parse_toml[Mode.Eager](view)
        var dt = parse_toml[Mode.Trusted](view)
        var js = String()
        var je = String()
        var jt = String()
        ds.to_json(js)
        de.to_json(je)
        dt.to_json(jt)
        assert_equal(js, je)
        assert_equal(js, jt)
        checked += 1
    assert_true(checked >= 200)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
