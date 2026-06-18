from std.testing import TestSuite, assert_equal, assert_true
from motoml.types import TomlType, AnyTomlType, TomlTypes
from std.sys.intrinsics import _type_is_eq


def test_string() raises:
    var toml = TomlType(value="hello friend")
    assert_equal(toml[String], "hello friend")


def test_int() raises:
    var toml = TomlType(value=3)
    assert_equal(toml[Int], 3)


def test_none() raises:
    var _toml = TomlType(value=NoneType())
    assert_true(_type_is_eq[type_of(_toml[NoneType]), NoneType]())


def test_float() raises:
    var toml = TomlType(value=3.14)
    assert_equal(toml[Float64], 3.14)


def test_bool() raises:
    var toml = TomlType(value=False)
    assert_equal(toml[Bool], False)


def test_date() raises:
    var date = TomlTypes.Date(year=2022, month=2, day=1)
    var toml = TomlType(value=date)
    assert_equal(toml[TomlTypes.Date], date)


def test_datetime() raises:
    var datetime = TomlTypes.DateTime.from_string("2022-03-02 03:43:02")
    var toml = TomlType(value=datetime)
    assert_equal(toml[TomlTypes.DateTime], datetime)


def test_time() raises:
    var time = TomlTypes.Time(hour=22, minute=32, second=4)
    var toml = TomlType(value=time)
    assert_equal(toml[TomlTypes.Time], time)


def test_array() raises:
    var array = [
        TomlType(value=1),
        TomlType(value=2.0),
        TomlType(value=True),
    ]
    var toml = TomlType(value=array^)

    ref arr = toml[List[TomlType]]
    assert_equal(arr[0][Int], 1)
    assert_equal(arr[1][Float64], 2.0)
    assert_equal(arr[2][Bool], True)

    var own_arr = toml^.take[List[TomlType]]()
    assert_equal(own_arr[0][Int], 1)
    assert_equal(own_arr[1][Float64], 2.0)
    assert_equal(own_arr[2][Bool], True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
