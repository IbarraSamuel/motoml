from std.testing import assert_equal, TestSuite

from motoml.types.toml import Toml
from motoml.parser import parse_toml


# TODO: Test nested keys..
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

comptime desired_multiline_string = "select * from something\\n"


def test_all_toml_types() raises:
    # Materialize compile time values.
    comptime TOML_TYPES_RES = parse_toml(TOML_TYPES)
    # var res = parse_toml(TOML_TYPES)
    var res = materialize[TOML_TYPES_RES]()
    if not res:
        var err = res^.take_error()
        raise err^

    var r = res^.take_value()
    print("Parsed and saved!")
    ref tb = r[Toml.Table]
    assert_equal(tb["string"][Toml.String], "abcd")
    assert_equal(tb["string_with_scape"][Toml.String], r"ab\"cd")
    assert_equal(tb["multiline_string"][Toml.String], desired_multiline_string)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
