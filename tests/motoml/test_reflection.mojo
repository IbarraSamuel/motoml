from motoml.read import parse_toml, TomlType, AnyTomlType
from motoml.reflection import toml_to_type_raises, toml_to_type
from testing import TestSuite, assert_equal
from sys.intrinsics import _type_is_eq, _type_is_eq_parse_time


@fieldwise_init
struct Info[o: ImmutOrigin](Movable, Writable, Representable):
    var name: StringSlice[Self.o]
    var version: StringSlice[Self.o]

    fn __repr__(self) -> String:
        var s = String()
        self.write_to(s)
        return s

@fieldwise_init
struct Language[o: ImmutOrigin](Movable, Writable, Representable):
    var info: Info[Self.o]
    var current_version: Optional[Float64]
    var stable_version: Optional[Float64]

    fn __repr__(self) -> String:
        var s = String()
        self.write_to(s)
        return s


@fieldwise_init
struct TestBuild[o: ImmutOrigin](Movable, Writable, Representable):
    var name: StringSlice[Self.o]
    var age: Int
    var other_types: List[Float64]
    var language: Language[Self.o]

    fn __repr__(self) -> String:
        var s = String()
        self.write_to(s)
        return s

comptime TOML_CONTENT = """
name = "samuel"
age = 30
other_types = [1.0, 2.0, 3.0]

[language]
current_version = 0.26

[language.info]
name = "mojo"
version = "0.26.2.0"
"""

comptime TOML_OBJ = parse_toml(TOML_CONTENT)


fn test_toml_to_type_raises() raises:
    var toml_obj = materialize[TOML_OBJ]()
    var test_build = toml_to_type_raises[TestBuild[StaticConstantOrigin]](toml_obj^)

    assert_equal(test_build.name, "samuel")
    assert_equal(test_build.age, 30)


fn test_toml_to_type() raises:
    var toml_obj = materialize[TOML_OBJ]()
    var value_or_none = toml_to_type[TestBuild[StaticConstantOrigin]](toml_obj^)
    assert_equal(Bool(value_or_none), True)

    ref value = value_or_none.value()
    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)

# TODO: Test nested keys..
comptime TOML_TYPES = '''
string = "abcd"
string_with_scape = "ab\\"cd"
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


fn test_all_toml_types() raises:
    var res = parse_toml(TOML_TYPES)
    assert_equal(res["string"].string(), "abcd")
    assert_equal(res["string_with_scape"].string(), 'ab\\"cd')
    assert_equal(res["multiline_string"].string(), desired_multiline_string)


fn main() raises:
    # test_toml_to_type()
    TestSuite.discover_tests[__functions_in_module()]().run()
