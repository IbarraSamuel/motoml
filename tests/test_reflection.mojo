from std.testing import TestSuite, assert_equal
from std.sys.intrinsics import _type_is_eq, _type_is_eq_parse_time

# from motoml.parser import parse_toml, parse_toml_raises
from motoml.types.toml import Toml
from motoml.reflection import toml_to_type_raises


# comptime TOML_OBJ = parse_toml(TOML_CONTENT)


def test_int() raises:
    var init_v = 1
    var toml_obj = Toml(init_v)
    var result = toml_to_type_raises[Int](toml_obj^)
    assert_equal(result, init_v)


def test_float() raises:
    var init_v = 3.14
    var toml_obj = Toml(init_v)
    var result = toml_to_type_raises[Float64](toml_obj^)
    assert_equal(result, init_v)


def test_bool() raises:
    var init_v = True
    var toml_obj = Toml(init_v)
    var result = toml_to_type_raises[Bool](toml_obj^)
    assert_equal(result, init_v)


def test_date() raises:
    var init_v = Toml.Date(year=2023, month=2, day=1)
    var toml_obj = Toml(init_v)
    var result = toml_to_type_raises[Toml.Date](toml_obj^)
    assert_equal(result, init_v)


def test_time() raises:
    var init_v = Toml.Time(hour=23, minute=1, second=1)
    var toml_obj = Toml(init_v)
    var result = toml_to_type_raises[Toml.Time](toml_obj^)
    assert_equal(result, init_v)


def test_datetime() raises:
    var date = Toml.Date(year=2023, month=2, day=1)
    var time = Toml.Time(hour=23, minute=1, second=1)
    var init_v = Toml.DateTime(date=date, time=time, offset={}, is_local=True)
    var toml_obj = Toml(init_v)
    var result = toml_to_type_raises[Toml.DateTime](toml_obj^)
    assert_equal(result, init_v)


def test_string() raises:
    var init_string = "hello world"
    var toml_obj = Toml(init_string)
    var result = toml_to_type_raises[String](toml_obj^)
    assert_equal(result, init_string)


# TODO: Add Variant into this, to be able to store a list of distinct types.
def test_float_list() raises:
    var f = Toml(3.12)
    var f2 = Toml(Toml.Float.MAX)
    var f3 = Toml(3e14)
    var l = [f^, f2^, f3^]
    var toml_list = Toml(l^)
    var result = toml_to_type_raises[List[Float64]](toml_list^)
    assert_equal(result[0], 3.12)
    assert_equal(result[1], Float64.MAX)
    assert_equal(result[2], 3e14)


def test_int_list() raises:
    var l = [Toml(i) for i in range(3, 6)]
    var toml_list = Toml(l^)
    var result = toml_to_type_raises[List[Int]](toml_list^)
    assert_equal(result[0], 3)
    assert_equal(result[1], 4)
    assert_equal(result[2], 5)


def test_string_list() raises:
    var string_v = String("hello")
    var l = [
        Toml(string_v),
        Toml(string_v),
        Toml(string_v),
        Toml(string_v),
    ]
    var toml_list = Toml(l^)
    var result = toml_to_type_raises[List[String]](toml_list^)
    assert_equal(result[0], string_v)
    assert_equal(result[1], string_v)
    assert_equal(result[2], string_v)
    assert_equal(result[3], string_v)


def test_toml_list() raises:
    var string_v = Toml("hello")
    var l = [
        string_v.copy(),
        string_v.copy(),
        string_v.copy(),
        string_v.copy(),
    ]
    var toml_list = Toml(l^)
    var result = toml_to_type_raises[List[Toml]](toml_list^)
    assert_equal(result[0], string_v)
    assert_equal(result[1], string_v)
    assert_equal(result[2], string_v)
    assert_equal(result[3], string_v)


def test_toml_table() raises:
    var toml_obj = Toml({"first_value": Toml(1), "second_value": Toml(3.1)})

    var simple_struct = toml_to_type_raises[Dict[String, Toml]](toml_obj^)

    assert_equal(simple_struct["first_value"][Int], 1)
    assert_equal(simple_struct["second_value"][Float64], 3.1)


struct SimpleStruct(Movable):
    var first_value: Int
    var second_value: Float64


def test_simple_struct() raises:
    var toml_obj = Toml({"first_value": Toml(1), "second_value": Toml(3.1)})

    var simple_struct = toml_to_type_raises[SimpleStruct](toml_obj^)

    assert_equal(simple_struct.first_value, 1)
    assert_equal(simple_struct.second_value, 3.1)


# struct AllTypes(Movable):
#     var integer: Int
#     var float: Float64
#     var boolean: Bool
#     var string: String
#     var date: Toml.Date
#     var time: Toml.Time
#     var datetime: Toml.DateTime
#     var list: List[Int]
#     var table: Table


# struct Table(Movable):
#     var key: Int
#     var key2: Int


def test_struct_all_types() raises:
    var tb = Toml({"key": Toml(32), "key2": Toml("other_type")})
    var other_t = Toml({"keyval": tb^})
    # var _toml_obj = Toml(
    #     {
    #         "integer": Toml(1),
    #         "float": Toml(3.1),
    #         "boolean": Toml(True),
    #         "string": Toml("hello"),
    #         "nan": Toml(Toml.NaN()),
    #         "date": Toml(Toml.Date.from_string("2024-21-02")),
    #         "time": Toml(Toml.Time.from_string("22:01:04")),
    #         "datetime": Toml(
    #             Toml.DateTime.from_string("2026-02-01T22:01:38-05:00")
    #         ),
    #         "list": Toml([Toml(1), Toml(2), Toml(3), Toml(4)]),
    #         "table": tb^,
    #     }
    # )

    # var at = toml_to_type_raises[AllTypes](toml_obj^)

    # assert_equal(at.integer, 1)
    # assert_equal(at.float, 3.1)
    # assert_equal(at.boolean, True)
    # assert_equal(at.datetime.date.day, 2)
    # assert_equal(at.table.key, 32)


# struct StructOptional(Movable):
#     var value_1: String
#     var value_2: Int


# def test_struct_optional() raises:
#     var toml_obj = Toml({"value_1": Toml("hello")})
#     var value = toml_to_type_raises[StructOptional](toml_obj^)

#     assert_equal(value.value_1, "hello")
#     assert_equal(Bool(value.value_2), False)


# struct TestBuild(Movable):
#     var name: String
#     var age: Int
#     var other_types: List[Float64]
#     var language: Language


# struct Language(Movable):
#     # var current_version: Optional[Float64]
#     # var stable_version: Optional[Float64]
#     var info: Info


# struct Info(Movable):
#     var name: String
#     var version: String


# def test_nested() raises:
#     var toml_obj = Toml(
#         {
#             "name": Toml("samuel"),
#             "age": Toml(30),
#             "other_types": Toml(
#                 [
#                     Toml(1.0),
#                     Toml(2.0),
#                     Toml(3.0),
#                 ]
#             ),
#             "language": Toml(
#                 {
#                     "current_version": Toml(0.26),
#                     "info": Toml(
#                         {
#                             "name": Toml("mojo"),
#                             "version": Toml("0.26.2.0"),
#                         }
#                     ),
#                 }
#             ),
#         }
#     )
#     var value = toml_to_type_raises[TestBuild](toml_obj^)

#     assert_equal(value.name, "samuel")
#     assert_equal(value.age, 30)
#     assert_equal(value.language.info.name, "mojo")
#     # assert_equal(value.language.current_version.value(), 0.26)
#     # assert_equal(Bool(value.language.stable_version), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
