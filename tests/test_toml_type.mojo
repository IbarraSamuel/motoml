from std.testing import TestSuite, assert_equal, assert_true
from motoml.types.toml import Toml
from std.sys.intrinsics import _type_is_eq


def test_string() raises:
    var toml = Toml("hello friend")
    assert_equal(toml[String], "hello friend")


def test_int() raises:
    var toml = Toml(3)
    assert_equal(toml[Int], 3)


def test_none() raises:
    var toml = Toml(Toml.NaN())
    assert_equal(toml[Toml.NaN], Toml.NaN())


def test_float() raises:
    var toml = Toml(3.14)
    assert_equal(toml[Float64], 3.14)


def test_bool() raises:
    var toml = Toml(False)
    assert_equal(toml[Bool], False)


def test_date() raises:
    var date = Toml.Date(year=2022, month=2, day=1)
    var toml = Toml(date)
    assert_equal(toml[Toml.Date], date)


def test_datetime() raises:
    var datetime = Toml.DateTime.from_string("2022-03-02 03:43:02")
    var toml = Toml(datetime)
    assert_equal(toml[Toml.DateTime], datetime)


def test_time() raises:
    var time = Toml.Time(hour=22, minute=32, second=4)
    var toml = Toml(time)
    assert_equal(toml[Toml.Time], time)


def test_array() raises:
    var array = [
        Toml(1),
        Toml(2.0),
        Toml(True),
    ]
    var toml = Toml(array^)

    ref arr = toml[List[Toml]]
    assert_equal(arr[0][Int], 1)
    assert_equal(arr[1][Float64], 2.0)
    assert_equal(arr[2][Bool], True)

    var own_arr = toml^.take[List[Toml]]()
    assert_equal(own_arr[0][Int], 1)
    assert_equal(own_arr[1][Float64], 2.0)
    assert_equal(own_arr[2][Bool], True)


def test_table() raises:
    var table = {
        "first": Toml(Int(1)),
        "second": Toml(Float64(2.0)),
        "third": Toml(Bool(True)),
    }
    var toml = Toml(table^)

    ref tb = toml[Toml.Table]
    assert_equal(tb["first"][Int], 1)
    assert_equal(tb["second"][Float64], 2.0)
    assert_equal(tb["third"][Bool], True)

    var own_tb = toml^.take[Toml.Table]()
    assert_equal(own_tb["first"][Int], 1)
    assert_equal(own_tb["second"][Float64], 2.0)
    assert_equal(own_tb["third"][Bool], True)


def test_nested_table() raises:
    var table = {
        "first": Toml({"second": Toml(1)}),
    }
    # var toml = Toml(table^)

    # print(toml)
    # ref tb = toml[Toml.Table]
    # assert_equal(tb["first"][Int], 1)
    # assert_equal(tb["second"][Float64], 2.0)
    # assert_equal(tb["third"][Bool], True)

    # var own_tb = toml^.take[Toml.Table]()
    # assert_equal(own_tb["first"][Int], 1)
    # assert_equal(own_tb["second"][Float64], 2.0)
    # assert_equal(own_tb["third"][Bool], True)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
