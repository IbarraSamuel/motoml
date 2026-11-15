from std.testing import assert_equal, TestSuite

from motoml import parse_toml, Mode, Kind


comptime TOML_TYPES = r'''
string = "abcd"
string_with_scape = "ab\"cd"
multiline_string = """
select * from something
"""
positive_integer = 30
negative_integer = -30
positive_float = 3.45
negative_float = -3.45
boolean_true = true 
boolean_false = false
list = [1, -3.4, "some", true, [1,2], {a=1, b=2}]
table = {first=1, second=2}

nested.table = {val=2}

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

comptime desired_multiline_string = "select * from something\n"


def test_all_toml_types() raises:
    comptime TOML_TYPES_RES = parse_toml[Mode.Eager](TOML_TYPES)
    var res = materialize[TOML_TYPES_RES]()

    if case .Err = res:
        var err = res^.take_error()
        raise err

    var doc = res^.take()
    assert_equal(doc["string"][Kind.String], "abcd")
    assert_equal(doc["string_with_scape"][Kind.String], 'ab"cd')
    assert_equal(doc["multiline_string"][Kind.String], desired_multiline_string)
    assert_equal(doc["positive_integer"][Kind.Integer], 30)
    assert_equal(doc["negative_integer"][Kind.Integer], -30)
    assert_equal(doc["table"]["first"][Kind.Integer], 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
