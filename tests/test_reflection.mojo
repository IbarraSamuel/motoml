from std.testing import TestSuite, assert_equal
from std.sys.intrinsics import _type_is_eq, _type_is_eq_parse_time

from motoml.types.string_ref import StringRef
from motoml.types.tempo import Date, DateTime, Time
from motoml.parser import parse_toml, parse_toml_raises
from motoml.types import TomlType, AnyTomlType
from motoml.reflection import toml_to_type_raises


@fieldwise_init
struct Info(Movable, Writable):
    var name: String
    var version: String


@fieldwise_init
struct Language(Movable, Writable):
    var info: Info
    var current_version: Optional[Float64]
    var stable_version: Optional[Float64]


@fieldwise_init
struct TestBuild(Movable, Writable):
    var name: String
    var age: Int
    var other_types: List[Float64]
    var language: Language


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

# comptime TOML_OBJ = parse_toml(TOML_CONTENT)


def test_int() raises:
    var init_v = 1
    var toml_obj = TomlType(integer=init_v)
    var result = toml_to_type_raises[Int](toml_obj^)
    assert_equal(result, init_v)


def test_float() raises:
    var init_v = 3.14
    var toml_obj = TomlType(float=init_v)
    var result = toml_to_type_raises[Float64](toml_obj^)
    assert_equal(result, init_v)


def test_bool() raises:
    var init_v = True
    var toml_obj = TomlType(boolean=init_v)
    var result = toml_to_type_raises[Bool](toml_obj^)
    assert_equal(result, init_v)


def test_date() raises:
    var init_v = Date(year=2023, month=2, day=1)
    var toml_obj = TomlType(date=init_v)
    var result = toml_to_type_raises[Date](toml_obj^)
    assert_equal(result, init_v)


def test_time() raises:
    var init_v = Time(hour=23, minute=1, second=1)
    var toml_obj = TomlType(time=init_v)
    var result = toml_to_type_raises[Time](toml_obj^)
    assert_equal(result, init_v)


def test_datetime() raises:
    var date = Date(year=2023, month=2, day=1)
    var time = Time(hour=23, minute=1, second=1)
    var init_v = DateTime(date=date, time=time, offset={}, is_local=True)
    var toml_obj = TomlType(datetime=init_v)
    var result = toml_to_type_raises[DateTime](toml_obj^)
    assert_equal(result, init_v)


def test_string() raises:
    var init_string = "hello world"
    var toml_obj = TomlType(string=init_string)
    var result = toml_to_type_raises[String](toml_obj^)
    assert_equal(result, init_string)


# TODO: Add Variant into this, to be able to store a list of distinct types.
def test_float_list() raises:
    var f = TomlType(float=3.12)
    var f2 = TomlType(float=TomlType.Float.MAX)
    var f3 = TomlType(float=3e14)
    var l = [f^.move_to_addr(), f2^.move_to_addr(), f3^.move_to_addr()]
    var toml_list = TomlType(array=l^)
    var result = toml_to_type_raises[List[Float64]](toml_list^)
    assert_equal(result[0], 3.12)
    assert_equal(result[1], Float64.MAX)
    assert_equal(result[2], 3e14)


def test_int_list() raises:
    var f1 = TomlType(integer=3)
    var f2 = TomlType(integer=4)
    var f3 = TomlType(integer=5)
    var l = [f1^.move_to_addr(), f2^.move_to_addr(), f3^.move_to_addr()]
    var toml_list = TomlType(array=l^)
    var result = toml_to_type_raises[List[Int]](toml_list^)
    assert_equal(result[0], 3)
    assert_equal(result[1], 4)
    assert_equal(result[2], 5)


def test_string_list() raises:
    var string_v = StringSlice("hello")
    var l = [
        TomlType(string=string_v).move_to_addr(),
        TomlType(string=string_v).move_to_addr(),
        TomlType(string=string_v).move_to_addr(),
        TomlType(string=string_v).move_to_addr(),
    ]
    var toml_list = TomlType(array=l^)
    var result = toml_to_type_raises[List[String]](toml_list^)
    assert_equal(result[0], string_v)
    assert_equal(result[1], string_v)
    assert_equal(result[2], string_v)
    assert_equal(result[3], string_v)


struct SimpleStruct(Movable):
    var first_value: Int
    var second_value: Float64


def test_simple_struct() raises:
    var test_table = """
    first_value = 1
    second_value = 3.1
    """

    var toml_obj = parse_toml_raises(test_table)
    var simple_struct = toml_to_type_raises[SimpleStruct](toml_obj^)

    assert_equal(simple_struct.first_value, 1)
    assert_equal(simple_struct.second_value, 3.1)


struct AllTypes(Movable):
    var integer: Int
    var float: Float64
    var boolean: Bool
    var string: String
    var string_lit: String
    var multiline: String
    var multiline_lit: String
    var date: Date
    var time: Time
    var datetime: DateTime
    var list: List[Int]
    var table: SimpleTable


struct SimpleTable(Equatable, Movable, Writable):
    var key: Int
    var key2: Int


def test_struct_all_types() raises:
    var test_table = """
    integer = 1
    float = 3.1
    boolean = true
    string = "hello"
    string_lit = 'hello'
    multiline = \"""
    hi my friend.
    \"""
    multiline_lit = '''
    hi my friend.
    '''
    date = 2024-21-02
    time = 22:01:04
    datetime = 2026-02-01T22:01:38-05:00
    list = [1,2,3,4]
    table = {key=32, key2=84}
    """

    var toml_obj = parse_toml_raises(test_table)
    var at = toml_to_type_raises[AllTypes](toml_obj^)

    assert_equal(at.integer, 1)
    assert_equal(at.float, 3.1)
    assert_equal(at.boolean, True)


struct StructOptional(Movable):
    var value_1: String
    var value_2: Optional[Int]


def test_struct_optional() raises:
    var toml = """
    value_1 = "hello"
    """
    var toml_obj = parse_toml_raises(toml)
    var value = toml_to_type_raises[StructOptional](toml_obj^)

    assert_equal(value.value_1, "hello")
    assert_equal(Bool(value.value_2), False)


def test_nested() raises:
    var toml_obj = parse_toml_raises(TOML_CONTENT)
    var value = toml_to_type_raises[TestBuild](toml_obj^)

    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)


# def test_toml_to_type() raises:
#     var test_int = "val = 1"
#     var toml_obj = materialize[TOML_OBJ]()
#     if not toml_obj:
#         raise "Failed to parse toml object."
#     var value = toml_to_type_raises[TestBuild[StaticConstantOrigin]](
#         toml_obj.take()
#     )

# assert_equal(value.name, "samuel")
# assert_equal(value.age, 30)
# assert_equal(value.language.info.name, "mojo")
# assert_equal(value.language.current_version.value(), 0.26)
# assert_equal(Bool(value.language.stable_version), False)


# def test_toml_to_type() raises:
#     var toml_obj = materialize[TOML_OBJ]()
# if not toml_obj:
#     raise "failed to parse toml object."
# var value_or_none = toml_to_type[TestBuild[StaticConstantOrigin]](
#     toml_obj.take()
# )

# # in case there is no value, the error will pop up into the test error.
# var is_some = Bool(value_or_none)
# try:
#     assert_equal(is_some, True)
# except e:
#     value_or_none^.destroy()
#     raise e^

# # Cannot fail
# var value = value_or_none^.value()

# assert_equal(value.name, "samuel")
# assert_equal(value.age, 30)
# assert_equal(value.language.info.name, "mojo")
# assert_equal(value.language.current_version.value(), 0.26)
# assert_equal(Bool(value.language.stable_version), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
