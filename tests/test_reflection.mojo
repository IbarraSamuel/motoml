from std.testing import TestSuite, assert_equal
from std.sys.intrinsics import _type_is_eq, _type_is_eq_parse_time

from motoml.types.string_ref import StringRef
from motoml.types.tempo import Date, DateTime, Time
from motoml.parser import parse_toml, parse_toml_raises
from motoml.toml_types import TomlType, AnyTomlType
from motoml.reflection import toml_to_type_raises


@fieldwise_init
struct Info[o: ImmutOrigin](Movable, Writable):
    var name: StringSlice[Self.o]
    var version: StringSlice[Self.o]


@fieldwise_init
struct Language[o: ImmutOrigin](Movable, Writable):
    var info: Info[Self.o]
    var current_version: Optional[Float64]
    var stable_version: Optional[Float64]


@fieldwise_init
struct TestBuild[o: ImmutOrigin](Movable, Writable):
    var name: StringSlice[Self.o]
    var age: Int
    var other_types: List[Float64]
    var language: Language[Self.o]


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


@fieldwise_init
struct TestBuild2[o: ImmutOrigin](Movable, Writable):
    var name: StringSlice[Self.o]
    var age: Int
    var other_types: List[Float64]
    var language: Language2[Self.o]


@fieldwise_init
struct Language2[o: ImmutOrigin](Movable, Writable):
    # var info: Info[Self.o]
    var current_version: Optional[Float64]
    var stable_version: Optional[Float64]


comptime TOML_CONTENT_2 = """
name = "samuel"
age = 30
other_types = [1.0, 2.0, 3.0]

[language]
current_version = 0.26
stable_version = 2.12
"""

# comptime TOML_OBJ = parse_toml(TOML_CONTENT)


fn test_int() raises:
    var init_v = 1
    var toml_obj = TomlType[origin_of()](integer=init_v)
    var result = toml_to_type_raises[Int](toml_obj^)
    assert_equal(result, init_v)


fn test_float() raises:
    var init_v = 3.14
    var toml_obj = TomlType[origin_of()](float=init_v)
    var result = toml_to_type_raises[Float64](toml_obj^)
    assert_equal(result, init_v)


fn test_bool() raises:
    var init_v = True
    var toml_obj = TomlType[origin_of()](boolean=init_v)
    var result = toml_to_type_raises[Bool](toml_obj^)
    assert_equal(result, init_v)


fn test_date() raises:
    var init_v = Date(year=2023, month=2, day=1)
    var toml_obj = TomlType[origin_of()](date=init_v)
    var result = toml_to_type_raises[Date](toml_obj^)
    assert_equal(result, init_v)


fn test_time() raises:
    var init_v = Time(hour=23, minute=1, second=1)
    var toml_obj = TomlType[origin_of()](time=init_v)
    var result = toml_to_type_raises[Time](toml_obj^)
    assert_equal(result, init_v)


fn test_datetime() raises:
    var date = Date(year=2023, month=2, day=1)
    var time = Time(hour=23, minute=1, second=1)
    var init_v = DateTime(date=date, time=time, offset={}, is_local=True)
    var toml_obj = TomlType[origin_of()](datetime=init_v)
    var result = toml_to_type_raises[DateTime](toml_obj^)
    assert_equal(result, init_v)


fn test_toml_stringref() raises:
    var init_v = StringRef(
        "hello world".as_bytes(), literal=True, multiline=False
    )
    var toml_obj = TomlType(string=init_v)
    # NOTE: StringSlice will not provide any std formatting from toml.
    var result = toml_to_type_raises[StringRef[init_v.origin]](toml_obj^)
    assert_equal(result, init_v)


fn test_string_ref() raises:
    var init_string = StaticString("hello world")
    var strref = StringRef(
        init_string.as_bytes(), literal=True, multiline=False
    )
    var toml_obj = TomlType(string=strref)
    # NOTE: StringSlice will not provide any std formatting from toml.
    var result = toml_to_type_raises[StringSlice[init_string.origin]](toml_obj^)
    assert_equal(result, init_string)


fn test_string() raises:
    var init_string = "hello world"
    var strref = StringRef(
        init_string.as_bytes(), literal=True, multiline=False
    )
    var toml_obj = TomlType(string=strref)
    var result = toml_to_type_raises[String](toml_obj^)
    assert_equal(result, init_string)


# TODO: Add Variant into this, to be able to store a list of distinct types.
fn test_float_list() raises:
    comptime Toml = TomlType[origin_of()]
    var f = Toml(float=3.12)
    var f2 = Toml(float=Toml.Float.MAX)
    var f3 = Toml(float=3e14)
    var l = [f^.move_to_addr(), f2^.move_to_addr(), f3^.move_to_addr()]
    var toml_list = Toml(array=l^)
    var result = toml_to_type_raises[List[Float64]](toml_list^)
    assert_equal(result[0], 3.12)
    assert_equal(result[1], Float64.MAX)
    assert_equal(result[2], 3e14)


fn test_int_list() raises:
    comptime Toml = TomlType[origin_of()]
    var f1 = Toml(integer=3)
    var f2 = Toml(integer=4)
    var f3 = Toml(integer=5)
    var l = [f1^.move_to_addr(), f2^.move_to_addr(), f3^.move_to_addr()]
    var toml_list = Toml(array=l^)
    var result = toml_to_type_raises[List[Int]](toml_list^)
    assert_equal(result[0], 3)
    assert_equal(result[1], 4)
    assert_equal(result[2], 5)


fn test_string_list() raises:
    var string_v = StringSlice("hello")
    comptime Toml = TomlType[string_v.origin]
    var strref0 = StringRef(string_v.as_bytes(), literal=True, multiline=False)
    var strref1 = StringRef(string_v.as_bytes(), literal=False, multiline=False)
    var strref2 = StringRef(string_v.as_bytes(), literal=True, multiline=True)
    var strref3 = StringRef(string_v.as_bytes(), literal=False, multiline=True)
    var l = [
        Toml(string=strref0).move_to_addr(),
        Toml(string=strref1).move_to_addr(),
        Toml(string=strref2).move_to_addr(),
        Toml(string=strref3).move_to_addr(),
    ]
    var toml_list = Toml(array=l^)
    var result = toml_to_type_raises[List[String]](toml_list^)
    assert_equal(result[0], strref0.calc_value())
    assert_equal(result[1], strref1.calc_value())
    assert_equal(result[2], strref2.calc_value())
    assert_equal(result[3], strref3.calc_value())


struct SimpleStruct(Movable):
    var first_value: Int
    var second_value: Float64


fn test_simple_struct() raises:
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


fn test_struct_all_types() raises:
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


fn test_struct_optional() raises:
    var toml = """
    value_1 = "hello"
    """
    var toml_obj = parse_toml_raises(toml)
    var value = toml_to_type_raises[StructOptional](toml_obj^)

    assert_equal(value.value_1, "hello")
    assert_equal(Bool(value.value_2), False)


fn test_nested() raises:
    var toml_obj = parse_toml_raises(TOML_CONTENT)
    var value = toml_to_type_raises[TestBuild[StaticConstantOrigin]](toml_obj^)

    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)


# fn test_toml_to_type() raises:
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


# fn test_toml_to_type() raises:
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


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
