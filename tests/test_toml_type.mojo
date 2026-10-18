from std.testing import TestSuite, assert_equal, assert_true
from motoml.types.toml import Toml
from motoml.types import tempo


def test_string() raises:
    var toml = Toml.String("hello friend")
    if case .String(s) = toml:
        assert_equal(s, "hello friend")
    else:
        raise "Toml should be a string"


def test_int() raises:
    var toml = Toml.Integer(3)
    if case .Integer(i) = toml:
        assert_equal(i, 3)
    else:
        raise "toml should be a integer."


def test_float() raises:
    var toml = Toml.Float(3.14)
    assert_equal(toml[Float64], 3.14)


def test_bool() raises:
    var toml = Toml.Boolean(False)
    assert_equal(toml[Bool], False)


def test_date() raises:
    var date = tempo.Date(year=2022, month=2, day=1)
    var toml = Toml.Date(date)
    assert_equal(toml[tempo.Date], date)


def test_datetime() raises:
    var datetime = tempo.DateTime.from_string("2022-03-02 03:43:02").take()
    var toml = Toml.DateTime(datetime)
    assert_equal(toml[tempo.DateTime], datetime)


def test_time() raises:
    var time = tempo.Time(hour=22, minute=32, second=4)
    var toml = Toml.Time(time)
    assert_equal(toml[tempo.Time], time)


def test_array() raises:
    var array: List = [
        Toml.Integer(1),
        Toml.Float(2.0),
        Toml.Boolean(True),
    ]
    var toml = Toml.Array(array^)

    ref arr = toml[List[Toml]]
    assert_equal(arr[0][Int], 1)
    assert_equal(arr[1][Float64], 2.0)
    assert_equal(arr[2][Bool], True)

    var own_arr = toml^.unsafe_take[List[Toml]]()
    assert_equal(own_arr[0][Int], 1)
    assert_equal(own_arr[1][Float64], 2.0)
    assert_equal(own_arr[2][Bool], True)


def test_table() raises:
    var table = Dict[String, Toml]()
    table["first"] = Toml.Integer(1)
    table["second"] = Toml.Float(2.0)
    table["third"] = Toml.Boolean(True)

    var toml = Toml.Table(table^)

    ref tb = toml[Dict[String, Toml]]
    assert_equal(tb["first"][Int], 1)
    assert_equal(tb["second"][Float64], 2.0)
    assert_equal(tb["third"][Bool], True)

    var own_tb = toml^.unsafe_take[Dict[String, Toml]]()
    assert_equal(own_tb["first"][Int], 1)
    assert_equal(own_tb["second"][Float64], 2.0)
    assert_equal(own_tb["third"][Bool], True)


def test_nested_table() raises:
    var inner_tb = Dict[String, Toml]()
    inner_tb["second"] = Toml.Integer(1)
    var outer_tb = Dict[String, Toml]()
    outer_tb["first"] = Toml.Table(inner_tb^)
    var toml = Toml.Table(outer_tb^)

    assert_equal(
        toml[Dict[String, Toml]]["first"][Dict[String, Toml]]["second"][Int], 1
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
