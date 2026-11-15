from std.testing import TestSuite, assert_equal, assert_raises
from std.collections import List, Optional

from motoml import parse_toml, Mode, _Mode, Date, Time, DateTime


def test_scalar_and_temporal_take() raises:
    var src = """
    i = 1
    f = 3.14
    b = true
    s = "hello world"
    d = 2023-02-01
    t = 23:01:01
    dt = 2023-02-01T23:01:01
    """
    var doc = parse_toml(src).take()
    assert_equal(doc["i"].take[Int](), 1)
    assert_equal(doc["f"].take[Float64](), 3.14)
    assert_equal(doc["b"].take[Bool](), True)
    assert_equal(doc["s"].take[String](), "hello world")
    assert_equal(doc["d"].take[Date](), Date(year=2023, month=2, day=1))
    assert_equal(doc["t"].take[Time](), Time(hour=23, minute=1, second=1))
    var expected_dt = DateTime(
        date=Date(year=2023, month=2, day=1),
        time=Time(hour=23, minute=1, second=1),
        offset={},
        is_local=True,
    )
    assert_equal(doc["dt"].take[DateTime](), expected_dt)

    var edoc = parse_toml[Mode.Eager](src).take()
    assert_equal(edoc["i"].take[Int](), 1)
    assert_equal(edoc["f"].take[Float64](), 3.14)
    assert_equal(edoc["b"].take[Bool](), True)
    assert_equal(edoc["s"].take[String](), "hello world")
    assert_equal(edoc["dt"].take[DateTime](), expected_dt)


def test_lists() raises:
    var src = """
    floats = [3.12, 1.5e14, -2.5]
    ints = [3, 4, 5]
    strings = ["hello", "hello", "hello", "hello"]
    """
    var doc = parse_toml(src).take()
    var rf = doc["floats"].take[List[Float64]]()
    assert_equal(rf[0], 3.12)
    assert_equal(rf[1], 1.5e14)
    assert_equal(rf[2], -2.5)

    var ri = doc["ints"].take[List[Int]]()
    assert_equal(ri[0], 3)
    assert_equal(ri[1], 4)
    assert_equal(ri[2], 5)

    var rs = doc["strings"].take[List[String]]()
    assert_equal(rs[0], "hello")
    assert_equal(rs[3], "hello")


struct SimpleStruct(Movable):
    var first_value: Int
    var second_value: Float64


def test_simple_struct() raises:
    var src = "first_value = 1\nsecond_value = 3.1\n"
    var doc = parse_toml(src).take()
    var simple_struct = doc.take[SimpleStruct]()
    assert_equal(simple_struct.first_value, 1)
    assert_equal(simple_struct.second_value, 3.1)

    var edoc = parse_toml[Mode.Eager](src).take()
    var eager_struct = edoc.take[SimpleStruct]()
    assert_equal(eager_struct.first_value, 1)
    assert_equal(eager_struct.second_value, 3.1)


struct Table(Movable):
    var key: Int
    var key2: Int


struct AllTypes(Movable):
    var integer: Int
    var float: Float64
    var boolean: Bool
    var string: String
    var date: Date
    var time: Time
    var datetime: DateTime
    var list: List[Int]
    var table: Table


struct StringThenMissingField(Movable):
    var owned_string: String
    var missing_integer: Int


def test_struct_conversion_failure_cleans_initialized_fields() raises:
    var src = 'owned_string = "owned value"\n'
    var doc = parse_toml(src).take()
    with assert_raises():
        _ = doc.take[StringThenMissingField]()


def test_struct_all_types() raises:
    var src = """
    integer = 1
    float = 3.1
    boolean = true
    string = "hello"
    date = 2024-02-21
    time = 22:01:04
    datetime = 2026-02-01T22:01:38-05:00
    list = [1, 2, 3, 4]
    [table]
    key = 32
    key2 = 84
    """
    var doc = parse_toml(src).take()
    var at = doc.take[AllTypes]()
    assert_equal(at.integer, 1)
    assert_equal(at.float, 3.1)
    assert_equal(at.boolean, True)
    assert_equal(at.string, "hello")
    assert_equal(at.datetime.date.day, 1)
    assert_equal(at.list[2], 3)
    assert_equal(at.table.key, 32)
    assert_equal(at.table.key2, 84)

    var edoc = parse_toml[Mode.Eager](src).take()
    var eat = edoc.take[AllTypes]()
    assert_equal(eat.integer, 1)
    assert_equal(eat.list[3], 4)
    assert_equal(eat.table.key2, 84)


struct StructOptional(Movable):
    var value_1: String
    var value_2: Optional[Int]


def test_struct_optional() raises:
    var src = 'value_1 = "hello"\n'
    var doc = parse_toml(src).take()
    var value = doc.take[StructOptional]()
    assert_equal(value.value_1, "hello")
    assert_equal(Bool(value.value_2), False)


struct Info(Movable):
    var name: String
    var version: String


struct Language(Movable):
    var current_version: Optional[Float64]
    var stable_version: Optional[Float64]
    var info: Info


struct TestBuild(Movable):
    var name: String
    var age: Int
    var other_types: List[Float64]
    var language: Language


def test_nested() raises:
    var src = """
    name = "samuel"
    age = 30
    other_types = [1.0, 2.0, 3.0]
    [language]
    current_version = 0.26
    [language.info]
    name = "mojo"
    version = "0.26.2.0"
    """
    var doc = parse_toml(src).take()
    var value = doc.take[TestBuild]()

    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)

    var edoc = parse_toml[Mode.Eager](src).take()
    var evalue = edoc.take[TestBuild]()
    assert_equal(evalue.name, "samuel")
    assert_equal(evalue.language.info.version, "0.26.2.0")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
