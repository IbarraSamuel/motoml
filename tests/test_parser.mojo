from motoml.read import parse_toml
from motoml.read_v2 import parse_toml_v2
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

fn test_parse_toml_improvement() raises:
    """Test if new iterations really work better than old versions."""
    from benchmark import run
    from testing import assert_true

    fn old_impl():
        _ = parse_toml(TOML_TYPES)

    fn new_impl():
        _ = parse_toml_v2(TOML_TYPES)

    var old_report = run[func2=old_impl](max_iters=1000)
    var new_report = run[func2=new_impl](max_iters=1000)

    var old_time = old_report.duration()
    var new_time = new_report.duration()

    assert_true(new_time <= old_time)


fn test_all_toml_types() raises:
    var res = materialize[TOML_TYPES_RES]()
    assert_equal(res["string"].string(), "abcd")
    assert_equal(res["string_with_scape"].string(), r'ab\"cd')
    assert_equal(res["multiline_string"].string(), desired_multiline_string)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
