from std.testing import TestSuite, assert_equal

# from motoml.parser import parse_toml, parse_toml_raises
from motoml.types.toml import Toml
from motoml.reflection import toml_to_type_raises


# comptime TOML_OBJ = parse_toml(TOML_CONTENT)


def test_int() raises:
    var init_v = 1
    var toml_obj = Toml.Integer(init_v)
    var result = toml_to_type_raises[Int](toml_obj^)
    assert_equal(result, init_v)


def test_float() raises:
    var init_v = 3.14
    var toml_obj = Toml.Float(init_v)
    var result = toml_to_type_raises[Float64](toml_obj^)
    assert_equal(result, init_v)


def test_bool() raises:
    var init_v = True
    var toml_obj = Toml.Boolean(init_v)
    var result = toml_to_type_raises[Bool](toml_obj^)
    assert_equal(result, init_v)


def test_date() raises:
    var init_v = Toml.Types.Date(year=2023, month=2, day=1)
    var toml_obj = Toml.Date(init_v)
    var result = toml_to_type_raises[Toml.Types.Date](toml_obj^)
    assert_equal(result, init_v)


def test_time() raises:
    var init_v = Toml.Types.Time(hour=23, minute=1, second=1)
    var toml_obj = Toml.Time(init_v)
    var result = toml_to_type_raises[Toml.Types.Time](toml_obj^)
    assert_equal(result, init_v)


def test_datetime() raises:
    var date = Toml.Types.Date(year=2023, month=2, day=1)
    var time = Toml.Types.Time(hour=23, minute=1, second=1)
    var init_v = Toml.Types.DateTime(
        date=date, time=time, offset={}, is_local=True
    )
    var toml_obj = Toml.DateTime(init_v)
    var result = toml_to_type_raises[Toml.Types.DateTime](toml_obj^)
    assert_equal(result, init_v)


def test_string() raises:
    var init_string = "hello world"
    var toml_obj = Toml.String(init_string)
    var result = toml_to_type_raises[String](toml_obj^)
    assert_equal(result, init_string)


# TODO: Add Variant into this, to be able to store a list of distinct types.
def test_float_list() raises:
    var f = Toml.Float(3.12)
    var f2 = Toml.Float(Float64.MAX)
    var f3 = Toml.Float(3e14)
    var l: List = [f^, f2^, f3^]
    var toml_list = Toml.Array(l^)
    var result = toml_to_type_raises[List[Float64]](toml_list^)
    assert_equal(result[0], 3.12)
    assert_equal(result[1], Float64.MAX)
    assert_equal(result[2], 3e14)


def test_int_list() raises:
    var l = [Toml.Integer(i) for i in range(3, 6)]
    var toml_list = Toml.Array(l^)
    var result = toml_to_type_raises[List[Int]](toml_list^)
    assert_equal(result[0], 3)
    assert_equal(result[1], 4)
    assert_equal(result[2], 5)


def test_string_list() raises:
    var string_v = String("hello")
    var l: List = [
        Toml.String(string_v),
        Toml.String(string_v),
        Toml.String(string_v),
        Toml.String(string_v),
    ]

    var toml_list = Toml.Array(l^)
    var result = toml_to_type_raises[List[String]](toml_list^)
    assert_equal(result[0], string_v)
    assert_equal(result[1], string_v)
    assert_equal(result[2], string_v)
    assert_equal(result[3], string_v)


def test_toml_list() raises:
    var string_v = Toml.String("hello")
    var l: List = [
        Toml.String("hello"),
        Toml.String("hello"),
        Toml.String("hello"),
        Toml.String("hello"),
    ]

    var toml_list = Toml.Array(l^)
    var result = toml_to_type_raises[List[Toml]](toml_list^)
    assert_equal(result[0], string_v)
    assert_equal(result[1], string_v)
    assert_equal(result[2], string_v)
    assert_equal(result[3], string_v)


def test_toml_table() raises:
    var dct = Dict[String, Toml]()
    dct["first_value"] = Toml.Integer(1)
    dct["second_value"] = Toml.Float(3.1)
    var toml_obj = Toml.Table(dct^)

    var simple_struct = toml_to_type_raises[Dict[String, Toml]](toml_obj^)

    assert_equal(simple_struct["first_value"][Int], 1)
    assert_equal(simple_struct["second_value"][Float64], 3.1)


struct SimpleStruct(Movable):
    var first_value: Int
    var second_value: Float64


def test_simple_struct() raises:
    var dct = Dict[String, Toml]()
    dct["first_value"] = Toml.Integer(1)
    dct["second_value"] = Toml.Float(3.1)
    var toml_obj = Toml.Table(dct^)

    var simple_struct = toml_to_type_raises[SimpleStruct](toml_obj^)

    assert_equal(simple_struct.first_value, 1)
    assert_equal(simple_struct.second_value, 3.1)


struct AllTypes(Movable):
    var integer: Int
    var float: Float64
    var boolean: Bool
    var string: String
    var date: Toml.Types.Date
    var time: Toml.Types.Time
    var datetime: Toml.Types.DateTime
    var list: List[Toml]
    var table: Table


struct Table(Movable):
    var key: Int
    var key2: Int


def test_struct_all_types() raises:
    var inner_dct = Dict[String, Toml]()
    inner_dct["key"] = Toml.Integer(32)
    inner_dct["key2"] = Toml.Integer(84)
    var inner_tb = Toml.Table(inner_dct^)
    var date = Toml.Date(Toml.Types.Date.from_string("2024-02-21").take())
    var time = Toml.Time(Toml.Types.Time.from_string("22:01:04").take())
    var datetime = Toml.DateTime(
        Toml.Types.DateTime.from_string("2026-02-01T22:01:38-05:00").take()
    )

    var _tb = Dict[String, Toml]()
    _tb["integer"] = Toml.Integer(1)
    _tb["float"] = Toml.Float(3.1)
    _tb["boolean"] = Toml.Boolean(True)
    _tb["string"] = Toml.String("hello")
    _tb["nan"] = materialize[Toml.NaN]()
    _tb["date"] = date^
    _tb["time"] = time^
    _tb["datetime"] = datetime^
    _tb["list"] = Toml.Array(
        [Toml.Integer(1), Toml.Integer(2), Toml.Integer(3), Toml.Integer(4)]
    )
    _tb["table"] = inner_tb^
    var _toml_obj = Toml.Table(_tb^)

    ref tb = _toml_obj[Dict[String, Toml]]
    assert_equal(tb["integer"][Int], 1)
    assert_equal(tb["float"][Float64], 3.1)
    assert_equal(tb["boolean"][Bool], True)
    assert_equal(tb["datetime"][Toml.Types.DateTime].date.day, 1)
    assert_equal(tb["list"][List[Toml]][2][Int], 3)
    assert_equal(tb["table"][Dict[String, Toml]]["key"][Int], 32)

    var at = toml_to_type_raises[AllTypes](_toml_obj^)

    assert_equal(at.integer, 1)
    assert_equal(at.float, 3.1)
    assert_equal(at.boolean, True)
    assert_equal(at.datetime.date.day, 1)
    assert_equal(at.list[2][Int], 3)
    assert_equal(at.table.key, 32)


struct StructOptional(Movable):
    var value_1: String
    var value_2: Optional[Int]


def test_struct_optional() raises:
    var _dct = Dict[String, Toml]()
    _dct["value_1"] = Toml.String("hello")
    var toml_obj = Toml.Table(_dct^)
    var value = toml_to_type_raises[StructOptional](toml_obj^)

    assert_equal(value.value_1, "hello")
    assert_equal(Bool(value.value_2), False)


struct TestBuild(Movable):
    var name: String
    var age: Int
    var other_types: List[Float64]
    var language: Language


struct Language(Movable):
    var current_version: Optional[Float64]
    var stable_version: Optional[Float64]
    var info: Info


struct Info(Movable):
    var name: String
    var version: String


def test_nested() raises:
    var _info = Dict[String, Toml]()
    _info["name"] = Toml.String("mojo")
    _info["version"] = Toml.String("0.26.2.0")

    var _language = Dict[String, Toml]()
    _language["current_version"] = Toml.Float(0.26)
    _language["info"] = Toml.Table(_info^)

    var _tb = Dict[String, Toml]()
    _tb["name"] = Toml.String("samuel")
    _tb["age"] = Toml.Integer(30)
    _tb["other_types"] = Toml.Array(
        [Toml.Float(1.0), Toml.Float(2.0), Toml.Float(3.0)]
    )
    _tb["language"] = Toml.Table(_language^)

    var toml_obj = Toml.Table(_tb^)

    var value = toml_to_type_raises[TestBuild](toml_obj^)

    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
