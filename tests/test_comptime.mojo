"""Compile-time TOML parsing tests using `try_parse_toml[Mode.Eager]`."""

from motoml import Date, Kind, Mode, Time, try_parse_toml
from std.testing import TestSuite, assert_equal, assert_false, assert_true

comptime TOML_TYPES = r'''
string = "abcd"
string_with_escape = "ab\"cd"
multiline_string = """
select * from something
"""
positive_integer = 30
negative_integer = -30
positive_float = 3.45
negative_float = -3.45
boolean_true = true
boolean_false = false
date_val = 2026-05-12
time_val = 08:15:30.25
list = [1, -3.4, "some", true, [1, 2], { a = 1, b = 2 }]
table = { first = 1, second = 2 }

nested.table = { val = 2 }

[multiline]
first = 1
second = 2

[[multiline_list]]
some_v = 1

[nested.multiline]
first = 1
second = 2

[[nested.multiline_list]]
some_v = 1
'''

comptime DESIRED_MULTILINE = "select * from something\n"


def test_comptime_eager_parse() raises:
    comptime PARSED_RES = try_parse_toml[Mode.Eager](TOML_TYPES)
    var res = materialize[PARSED_RES]()
    var doc = res^.take()

    assert_equal(doc["string"][Kind.String], "abcd")
    assert_equal(doc["string_with_escape"][Kind.String], 'ab"cd')
    assert_equal(doc["multiline_string"][Kind.String], DESIRED_MULTILINE)
    assert_equal(doc["positive_integer"][Kind.Integer], 30)
    assert_equal(doc["negative_integer"][Kind.Integer], -30)
    assert_equal(doc["positive_float"][Kind.Float], 3.45)
    assert_equal(doc["negative_float"][Kind.Float], -3.45)
    assert_true(doc["boolean_true"][Kind.Boolean])
    assert_false(doc["boolean_false"][Kind.Boolean])
    assert_equal(doc["date_val"][Kind.Date], Date(year=2026, month=5, day=12))
    assert_equal(
        doc["time_val"][Kind.Time],
        Time(hour=8, minute=15, second=30, nanosecond=250_000_000),
    )
    assert_equal(doc["table"]["first"][Kind.Integer], 1)
    assert_equal(doc["nested"]["table"]["val"][Kind.Integer], 2)
    assert_equal(doc["multiline_list"][0]["some_v"][Kind.Integer], 1)
    assert_equal(doc["nested"]["multiline"]["second"][Kind.Integer], 2)


def test_comptime_parse_error() raises:
    comptime BAD_RES = try_parse_toml[Mode.Eager]("dup = 1\ndup = 2\n")
    var res = materialize[BAD_RES]()
    var is_err = res.is_err()
    var err = res^.take_error()
    assert_true(is_err)
    assert_true("Duplicate key" in String(err))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
