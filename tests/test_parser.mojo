from motoml.read import parse_toml
from testing import assert_equal, TestSuite

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

comptime desired_multiline_string = """
select * from something
"""

comptime TOML_TYPES_RES = parse_toml(TOML_TYPES)

fn test_all_toml_types() raises:
    var res = materialize[TOML_TYPES_RES]()
    assert_equal(res["string"].string(), "abcd")
    assert_equal(res["string_with_scape"].string(), r'ab\"cd')
    assert_equal(res["multiline_string"].string(), desired_multiline_string)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
