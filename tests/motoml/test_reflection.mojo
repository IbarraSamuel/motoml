from motoml import read, reflection
from testing import TestSuite, assert_true
from sys.intrinsics import _type_is_eq, _type_is_eq_parse_time

comptime TOML_CONTENT = """
name = "samuel"
age = 30
other_types = [1.0, 2.0, 3.0]

[language.info]
name = "mojo"
version = "0.26.2.0"
"""


@fieldwise_init
struct Info[o: ImmutOrigin](Movable, Writable):
    var name: StringSlice[Self.o]
    var version: StringSlice[Self.o]

    fn __init__(out self):
        self.name = {}
        self.version = {}


@fieldwise_init
struct Language[o: ImmutOrigin](Movable, Writable):
    var info: Info[Self.o]

    fn __init__(out self):
        self.info = {}


# @fieldwise_init
# @explicit_destroy
struct TestBuild[o: ImmutOrigin](Movable, Writable):
    var name: StringSlice[Self.o]
    var age: Int
    var other_types: List[Float64]
    var language: Language[Self.o]

    fn __init__(out self):
        self.name = {}
        self.age = {}
        self.other_types = {}
        self.language = {}


fn test_parse_toml_type() raises:
    var toml = read.parse_toml(TOML_CONTENT)
    var test_build = reflection.parse_toml_type[TestBuild[toml.o]](toml^)

    assert_true(test_build.name == "samuel")
    assert_true(test_build.age == 30)


fn test_simple_toml_to_struct() raises:
    var string = "something"
    var toml = read.TomlType(string)
    var some_res = reflection.toml_to_struct[
        StringSlice[mut=False, origin_of(string)]
    ](toml^)
    print(some_res)
    print(some_res.value() == string)


# fn test_toml_to_struct() raises:
#     var toml = read.parse_toml(TOML_CONTENT)
#     print(toml)
#     # print("struct parsing...")
#     var info = toml["language"]["info"].copy()
#     print(info)
#     var info_struct = reflection.toml_to_struct[Info[toml.o]](info^)
#     if info_struct is None:
#         print("value: None")
#         return
#     print("value:", info_struct.unsafe_take())


# var test_build = reflection.toml_to_struct[TestBuild[toml.o]](toml^)
# print("struct parsing done!")

# assert_true(test_build)
# assert_true(test_build.value().name == "samuel")
# assert_true(test_build.value().age == 30)
# assert_true(test_build.value().language.info.name == "mojo")


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
    var res = read.parse_toml(TOML_TYPES)
    assert_true(res["string"].string() == "abcd")
    assert_true(res["string_with_scape"].string() == 'ab\\"cd')
    assert_true(res["multiline_string"].string() == desired_multiline_string)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
