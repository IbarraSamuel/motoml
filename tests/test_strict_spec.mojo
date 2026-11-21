"""TOML 1.1.0 strict-mode correctness, boundary conditions, and regression tests."""

from motoml import Kind, Mode, parse_toml, try_parse_toml
from std.memory import bitcast
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)
from std.utils.numerics import isinf, isnan


def assert_strict_rejects(content: StringSpan) raises:
    var r_strict = try_parse_toml[Mode.Strict](content)
    if r_strict.is_ok():
        _ = r_strict^.unsafe_take_value()
        raise Error(t"Strict mode should reject: {content}")
    _ = r_strict^.unsafe_take_error()

    var r_eager = try_parse_toml[Mode.Eager](content)
    if r_eager.is_ok():
        _ = r_eager^.unsafe_take_value()
        raise Error(t"Eager mode should reject: {content}")
    _ = r_eager^.unsafe_take_error()


def test_ieee754_special_floats_and_overflow() raises:
    var src = """
    p_inf = inf
    plus_inf = +inf
    n_inf = -inf
    p_nan = nan
    plus_nan = +nan
    n_nan = -nan
    neg_zero = -0.0
    neg_zero_exp = -0e0
    pos_zero = 0.0
    huge_pos = 1e1000
    huge_neg = -1e1000
    high_prec = 3.14159265358979323846
    """
    var d_strict = parse_toml[Mode.Strict](src)
    var d_eager = parse_toml[Mode.Eager](src)

    for k in ["p_inf", "plus_inf", "huge_pos"]:
        var fs = d_strict[k][Kind.Float]
        var fe = d_eager[k][Kind.Float]
        assert_true(isinf(fs) and fs > 0.0)
        assert_true(isinf(fe) and fe > 0.0)

    for k in ["n_inf", "huge_neg"]:
        var fs = d_strict[k][Kind.Float]
        var fe = d_eager[k][Kind.Float]
        assert_true(isinf(fs) and fs < 0.0)
        assert_true(isinf(fe) and fe < 0.0)

    for k in ["p_nan", "plus_nan", "n_nan"]:
        assert_true(isnan(d_strict[k][Kind.Float]))
        assert_true(isnan(d_eager[k][Kind.Float]))

    # Verify -0.0 preserves its IEEE-754 sign bit (bit 63 = 1).
    var nz_bits = bitcast[DType.uint64, 1](d_strict["neg_zero"][Kind.Float])
    var nze_bits = bitcast[DType.uint64, 1](
        d_strict["neg_zero_exp"][Kind.Float]
    )
    var pz_bits = bitcast[DType.uint64, 1](d_strict["pos_zero"][Kind.Float])
    assert_equal(nz_bits, UInt64(0x8000000000000000))
    assert_equal(nze_bits, UInt64(0x8000000000000000))
    assert_equal(pz_bits, UInt64(0))
    assert_equal(
        bitcast[DType.uint64, 1](d_eager["neg_zero"][Kind.Float]),
        UInt64(0x8000000000000000),
    )

    assert_equal(d_strict["high_prec"][Kind.Float], 3.141592653589793)
    assert_equal(d_eager["high_prec"][Kind.Float], 3.141592653589793)


def test_illegal_escapes_including_backslash_zero() raises:
    # Regression: `\0` is NOT a valid TOML 1.1 escape sequence (must use `\x00` or `\u0000`).
    assert_strict_rejects('s = "\\0"\n')
    assert_strict_rejects('s = "\\q"\n')
    assert_strict_rejects('s = "\\a"\n')
    assert_strict_rejects('s = "\\uD800"\n')
    assert_strict_rejects('s = "\\uDFFF"\n')
    assert_strict_rejects('s = "\\U00110000"\n')
    assert_strict_rejects('s = "\\x1"\n')
    assert_strict_rejects('s = "\\xGG"\n')
    assert_strict_rejects('s = "\\u123"\n')
    assert_strict_rejects('s = "\\U1234567"\n')
    assert_strict_rejects('s = "\\"\n')
    assert_strict_rejects('s = "\\ \n"')
    assert_strict_rejects('s = """hello \\   world"""\n')
    assert_strict_rejects('s = """hello \\\rworld"""\n')
    assert_strict_rejects('"k\\0" = 1\n')
    assert_strict_rejects('"k\\q" = 1\n')

    # Trusted mode defers escape validation until take[String]()
    var trusted = parse_toml[Mode.Trusted]('s = "\\0"\n')
    with assert_raises():
        _ = trusted["s"].take[String]()


def test_control_chars_and_bare_cr_rejected() raises:
    assert_strict_rejects("a = 1\rb = 2\n")
    assert_strict_rejects("arr = [1,\r2]\n")
    assert_strict_rejects("tbl = { a = 1,\rb = 2 }\n")
    assert_strict_rejects('s = "hello\x00world"\n')
    assert_strict_rejects('s = "hello\x08world"\n')
    assert_strict_rejects('s = "hello\x1fworld"\n')
    assert_strict_rejects('s = "hello\x7fworld"\n')
    assert_strict_rejects("s = 'hello\x00world'\n")
    assert_strict_rejects('s = """hello\rworld"""\n')
    assert_strict_rejects("s = '''hello\rworld'''\n")
    assert_strict_rejects("# comment with \x00 nul\n")
    assert_strict_rejects("# comment with \x7f del\n")
    assert_strict_rejects("# comment with \r bare cr\n")
    assert_strict_rejects("arr = [1, # bad\x00\n2]\n")
    assert_strict_rejects('"key\x00" = 1\n')
    assert_strict_rejects('"key\n" = 1\n')


def test_integer_and_float_strict_boundaries() raises:
    var valid = parse_toml(
        "max_i64 = 9223372036854775807\n"
        "min_i64 = -9223372036854775808\n"
        "max_hex = 0x7fffffffffffffff\n"
        "zero_neg = -0\n"
        "zero_pos = +0\n"
    )
    assert_equal(valid["max_i64"][Kind.Integer], 9223372036854775807)
    assert_equal(valid["min_i64"][Kind.Integer], -9223372036854775807 - 1)
    assert_equal(valid["max_hex"][Kind.Integer], 9223372036854775807)
    assert_equal(valid["zero_neg"][Kind.Integer], 0)
    assert_equal(valid["zero_pos"][Kind.Integer], 0)

    # Integer rejections
    assert_strict_rejects("v = 9223372036854775808\n")
    assert_strict_rejects("v = -9223372036854775809\n")
    assert_strict_rejects("v = 0x8000000000000000\n")
    assert_strict_rejects("v = -0x1\n")
    assert_strict_rejects("v = +0x1\n")
    assert_strict_rejects("v = +0b1\n")
    assert_strict_rejects("v = 0X1\n")
    assert_strict_rejects("v = 0O7\n")
    assert_strict_rejects("v = 0B1\n")
    assert_strict_rejects("v = 00\n")
    assert_strict_rejects("v = -00\n")
    assert_strict_rejects("v = 0123\n")
    assert_strict_rejects("v = 1__0\n")
    assert_strict_rejects("v = _1\n")
    assert_strict_rejects("v = 1_\n")
    assert_strict_rejects("v = 0x_1\n")
    assert_strict_rejects("v = 0x1_\n")

    # Float rejections
    assert_strict_rejects("v = 01.0\n")
    assert_strict_rejects("v = 1.\n")
    assert_strict_rejects("v = .1\n")
    assert_strict_rejects("v = 1._2\n")
    assert_strict_rejects("v = 1_.2\n")
    assert_strict_rejects("v = 1e_2\n")
    assert_strict_rejects("v = 1e+_2\n")
    assert_strict_rejects("v = 1e\n")
    assert_strict_rejects("v = 1..2\n")
    assert_strict_rejects("v = Inf\n")
    assert_strict_rejects("v = NaN\n")


def test_temporal_strict_boundaries() raises:
    var ok = parse_toml(
        "leap1 = 2024-02-29\n"
        "leap2 = 2000-02-29\n"
        "leap_sec = 23:59:60\n"
        "leap_sec_z = 23:59:60.000\n"
    )
    assert_equal(ok["leap1"][Kind.Date].day, 29)
    assert_equal(ok["leap2"][Kind.Date].day, 29)
    assert_equal(ok["leap_sec"][Kind.Time].second, 60)
    assert_equal(ok["leap_sec_z"][Kind.Time].nanosecond, 0)

    assert_strict_rejects("d = 2023-02-29\n")
    assert_strict_rejects("d = 1900-02-29\n")
    assert_strict_rejects("d = 2024-04-31\n")
    assert_strict_rejects("d = 2024-00-10\n")
    assert_strict_rejects("d = 2024-13-01\n")
    assert_strict_rejects("t = 24:00:00\n")
    assert_strict_rejects("t = 23:60:00\n")
    assert_strict_rejects("t = 23:59:61\n")
    assert_strict_rejects("t = 23:59:60.1\n")
    assert_strict_rejects("t = 23:59:00.\n")
    assert_strict_rejects("dt = 2024-01-01T00:00:00+24:00\n")
    assert_strict_rejects("dt = 2024-01-01T00:00:00+00:60\n")


def test_table_key_and_redefinition_rules() raises:
    # Empty quoted key is valid
    var empty_k = parse_toml('"" = 1\n')
    assert_equal(empty_k[""][Kind.Integer], 1)

    # Duplicate keys (plain and escape-equivalent)
    assert_strict_rejects("a = 1\na = 2\n")
    assert_strict_rejects('"\\u0061" = 1\na = 2\n')
    assert_strict_rejects('["\\u0061"]\nx = 1\n[a]\ny = 2\n')
    assert_strict_rejects('[a]\nx = 1\n["\\u0061"]\ny = 2\n')
    assert_strict_rejects("t = { a = 1, a = 2 }\n")
    assert_strict_rejects("t = { a.b = 1, a = { c = 2 } }\n")
    assert_strict_rejects("t = { a = { b = 1 }, a.c = 2 }\n")

    # Table redefinition & inline-table / static-array immutability
    assert_strict_rejects("[a]\nx = 1\n[a]\ny = 2\n")
    assert_strict_rejects("a.b = 1\n[a]\nc = 2\n")
    assert_strict_rejects("[a]\nb = 1\n[a.b]\nc = 2\n")
    assert_strict_rejects("a = { b = 1 }\na.c = 2\n")
    assert_strict_rejects("a = { b = 1 }\n[a]\nc = 2\n")
    assert_strict_rejects("a = []\n[[a]]\nb = 1\n")
    assert_strict_rejects("a = [1, 2]\na.y = 2\n")
    assert_strict_rejects("a.y = 2\n[[a]]\nx = 1\n")
    assert_strict_rejects(". = 1\n")
    assert_strict_rejects("a. = 1\n")
    assert_strict_rejects("a..b = 1\n")
    assert_strict_rejects('s = "')
    assert_strict_rejects("s = '")
    assert_strict_rejects("arr = [1, 2")
    assert_strict_rejects("tbl = { a = 1")
    assert_strict_rejects("[unclosed")


def test_nesting_depth_limit() raises:
    var deep_arr = String("a = ")
    for _ in range(520):
        deep_arr += "["
    for _ in range(520):
        deep_arr += "]"
    deep_arr += "\n"
    assert_strict_rejects(deep_arr)

    var deep_tbl = String("t = ")
    for _ in range(520):
        deep_tbl += "{ a = "
    deep_tbl += "1"
    for _ in range(520):
        deep_tbl += " }"
    deep_tbl += "\n"
    assert_strict_rejects(deep_tbl)


def test_utf8_chunk_boundaries_and_invalid_sequences() raises:
    # Build >1KB doc with multi-byte UTF-8 crossing 64-byte and 512-byte boundaries
    var doc_s = String()
    for i in range(6):
        doc_s += (
            "pad_"
            + String(i)
            + ' = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n'
        )
    doc_s += 'utf8_mid = "héllo € 🚀 世界"\n'
    doc_s += "# comment with UTF-8: café 日本語 🎉\n"
    for i in range(6):
        doc_s += (
            "tail_"
            + String(i)
            + ' = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"\n'
        )
    var parsed = parse_toml(doc_s)
    assert_equal(parsed["utf8_mid"][Kind.String], "héllo € 🚀 世界")

    # Invalid 0xFF byte past 512 bytes
    var bad_ff = List[Byte](capacity=doc_s.byte_length() + 4)
    for b in doc_s.as_bytes():
        bad_ff.append(b)
    bad_ff.append(Byte(ord("#")))
    bad_ff.append(Byte(0xFF))
    bad_ff.append(Byte(ord("\n")))
    assert_strict_rejects(StringSpan(unsafe_from_utf8=Span(bad_ff)))

    # Overlong 2-byte UTF-8 sequence (0xC0 0xAF)
    var overlong: List[Byte] = [
        Byte(ord("#")),
        Byte(ord(" ")),
        Byte(0xC0),
        Byte(0xAF),
        Byte(ord("\n")),
    ]
    assert_strict_rejects(StringSpan(unsafe_from_utf8=Span(overlong)))

    # UTF-8 encoded surrogate U+D800 (0xED 0xA0 0x80)
    var utf8_surr: List[Byte] = [
        Byte(ord("#")),
        Byte(ord(" ")),
        Byte(0xED),
        Byte(0xA0),
        Byte(0x80),
        Byte(ord("\n")),
    ]
    assert_strict_rejects(StringSpan(unsafe_from_utf8=Span(utf8_surr)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
