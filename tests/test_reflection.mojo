"""Reflection tests: scalars, temporals, lists, structs, Optional, OneOf, __union, Variant."""

from std.builtin.variadics import TypeList
from std.collections import List, Optional
from std.os import remove
from std.testing import (
    TestSuite,
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
)
from std.utils import Variant

from motoml import (
    Date,
    DateTime,
    Mode,
    OneOf,
    Time,
    parse_toml,
    parse_toml_file,
)


def test_scalar_and_temporal_take() raises:
    var src = """
    i = 1
    f = 3.14
    b = true
    s = "hello world"
    d = 2023-02-01
    t = 23:01:01.25
    dt = 2023-02-01T23:01:01
    """
    var doc = parse_toml(src)
    assert_equal(doc["i"].take[Int](), 1)
    assert_equal(doc["f"].take[Float64](), 3.14)
    assert_equal(doc["b"].take[Bool](), True)
    assert_equal(doc["s"].take[String](), "hello world")
    assert_equal(doc["d"].take[Date](), Date(year=2023, month=2, day=1))
    assert_equal(
        doc["t"].take[Time](),
        Time(hour=23, minute=1, second=1, nanosecond=250_000_000),
    )
    var expected_dt = DateTime(
        date=Date(year=2023, month=2, day=1),
        time=Time(hour=23, minute=1, second=1),
        offset={},
        is_local=True,
    )
    assert_equal(doc["dt"].take[DateTime](), expected_dt)

    var edoc = parse_toml[Mode.Eager](src)
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
    var doc = parse_toml(src)
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
    var doc = parse_toml(src)
    var simple_struct = doc.take[SimpleStruct]()
    assert_equal(simple_struct.first_value, 1)
    assert_equal(simple_struct.second_value, 3.1)

    var edoc = parse_toml[Mode.Eager](src)
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
    var doc = parse_toml(src)
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
    var doc = parse_toml(src)
    var at = doc.take[AllTypes]()
    assert_equal(at.integer, 1)
    assert_equal(at.float, 3.1)
    assert_equal(at.boolean, True)
    assert_equal(at.string, "hello")
    assert_equal(at.datetime.date.day, 1)
    assert_equal(at.list[2], 3)
    assert_equal(at.table.key, 32)
    assert_equal(at.table.key2, 84)

    var edoc = parse_toml[Mode.Eager](src)
    var eat = edoc.take[AllTypes]()
    assert_equal(eat.integer, 1)
    assert_equal(eat.list[3], 4)
    assert_equal(eat.table.key2, 84)


struct StructOptional(Movable):
    var value_1: String
    var value_2: Optional[Int]


def test_struct_optional() raises:
    var src = 'value_1 = "hello"\n'
    var doc = parse_toml(src)
    var value = doc.take[StructOptional]()
    assert_equal(value.value_1, "hello")
    assert_equal(Bool(value.value_2), False)

    # Wrong type on present optional field must fail and clean up earlier fields
    var bad_opt = parse_toml('value_1 = "hello"\nvalue_2 = "not_an_int"\n')
    with assert_raises():
        _ = bad_opt.take[StructOptional]()


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
    var doc = parse_toml(src)
    var value = doc.take[TestBuild]()

    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)

    var edoc = parse_toml[Mode.Eager](src)
    var evalue = edoc.take[TestBuild]()
    assert_equal(evalue.name, "samuel")
    assert_equal(evalue.language.info.version, "0.26.2.0")


struct EndpointA(Equatable, Movable):
    var label: String
    var port: Int


struct EndpointB(Equatable, Movable):
    var label: String
    var host: String


__union ValueEnum(Movable):
    case integer(Int)
    case float(Float64)
    case text(String)
    case endpoint_a(EndpointA)
    case endpoint_b(EndpointB)


struct EnumContainer(Movable):
    var primary: ValueEnum
    var secondary: Optional[ValueEnum]
    var missing_opt: Optional[ValueEnum]
    var items: List[ValueEnum]


struct OneOfContainer(Movable):
    var port_or_host: OneOf[Int, String]
    var opt_present: Optional[OneOf[Int, String]]
    var opt_missing: Optional[OneOf[Int, String]]
    var mixed: List[OneOf[Int, EndpointB]]


def test_take_variadic_variant() raises:
    var src = """
    i = 42
    f = 2.5
    s = "hello"
    [ep]
    label = "api"
    host = "localhost"
    """
    var doc = parse_toml(src)
    var vi = doc["i"].take[Int, Float64, String]()
    assert_true(vi.isa[Int]())
    assert_equal(vi[Int], 42)

    var vf = doc["f"].take[Int, Float64, String]()
    assert_true(vf.isa[Float64]())
    assert_equal(vf[Float64], 2.5)

    var vs = doc["s"].take[Int, Float64, String]()
    assert_true(vs.isa[String]())
    assert_equal(vs[String], "hello")

    # EndpointA initializes `label` then fails on missing `port` and falls back to EndpointB.
    var vep = doc["ep"].take[EndpointA, EndpointB, Int]()
    assert_true(vep.isa[EndpointB]())
    assert_equal(vep[EndpointB].label, "api")
    assert_equal(vep[EndpointB].host, "localhost")

    with assert_raises():
        _ = doc["s"].take[Int, Float64]()
    with assert_raises():
        _ = doc["missing"].take[Int, String]()

    var root_src = 'label = "root"\nhost = "0.0.0.0"\n'
    var root_doc = parse_toml[Mode.Eager](root_src)
    var vroot = root_doc.take[EndpointA, EndpointB]()
    assert_true(vroot.isa[EndpointB]())
    assert_equal(vroot[EndpointB].host, "0.0.0.0")


def test_take_typelist() raises:
    var src = """
    i = 7
    s = "typelist"
    [ep]
    label = "svc"
    port = 8080
    """
    comptime AnyTypes = TypeList.of[Int, String, EndpointA]()
    comptime MovableTypes = TypeList.of[
        Trait=Movable & Deinitable, Int, String
    ]()

    var doc = parse_toml(src)
    var vi = doc["i"].take[AnyTypes]()
    assert_true(vi.isa[Int]())
    assert_equal(vi[Int], 7)

    var vep = doc["ep"].take[AnyTypes]()
    assert_true(vep.isa[EndpointA]())
    assert_equal(vep[EndpointA].label, "svc")
    assert_equal(vep[EndpointA].port, 8080)

    var vs = doc["s"].take[MovableTypes]()
    assert_true(vs.isa[String]())
    assert_equal(vs[String], "typelist")

    var edoc = parse_toml[Mode.Eager](src)
    var evep = edoc["ep"].take[AnyTypes]()
    assert_true(evep.isa[EndpointA]())
    assert_equal(evep[EndpointA].port, 8080)


def test_enum_reflection() raises:
    var arr_src = """
    primary = "fast"
    secondary = 99
    items = [1, 2.5, "ok", { label = "inline", host = "db" }]
    """
    var doc = parse_toml(arr_src)
    var c = doc.take[EnumContainer]()

    if case .text(s) = c.primary:
        assert_equal(s, "fast")
    else:
        assert_true(False, "expected ValueEnum.text")

    assert_true(Bool(c.secondary))
    if case .Some(.integer(n)) = c.secondary:
        assert_equal(n, 99)
    else:
        assert_true(False, "expected ValueEnum.integer")

    assert_false(Bool(c.missing_opt))
    assert_equal(len(c.items), 4)

    if case .integer(v0) = c.items[0]:
        assert_equal(v0, 1)
    else:
        assert_true(False, "expected ValueEnum.integer at index 0")

    if case .float(v1) = c.items[1]:
        assert_equal(v1, 2.5)
    else:
        assert_true(False, "expected ValueEnum.float at index 1")

    if case .text(v2) = c.items[2]:
        assert_equal(v2, "ok")
    else:
        assert_true(False, "expected ValueEnum.text at index 2")

    if case .endpoint_b(ep) = c.items[3]:
        assert_equal(ep.label, "inline")
        assert_equal(ep.host, "db")
    else:
        assert_true(False, "expected ValueEnum.endpoint_b at index 3")

    with assert_raises():
        _ = parse_toml("b = true\n")["b"].take[ValueEnum]()

    var edoc = parse_toml[Mode.Eager](arr_src)
    var ec = edoc.take[EnumContainer]()
    if case .endpoint_b(ep) = ec.items[3]:
        assert_equal(ep.host, "db")
    else:
        assert_true(False, "expected ValueEnum.endpoint_b in Eager mode")


def test_one_of_wrapper() raises:
    var src = """
    port_or_host = 8080
    opt_present = "localhost"
    mixed = [10, { label = "web", host = "example.com" }]
    """
    var doc = parse_toml(src)
    var direct = doc["port_or_host"].take[OneOf[Int, String]]()
    assert_true(direct.isa[Int]())
    assert_equal(direct[Int], 8080)
    assert_equal(direct, OneOf[Int, String](8080))
    var as_variant = direct^.into_variant()
    assert_equal(as_variant[Int], 8080)

    var c = doc.take[OneOfContainer]()
    assert_true(c.port_or_host.isa[Int]())
    assert_equal(c.port_or_host[Int], 8080)
    assert_true(Bool(c.opt_present))
    assert_true(c.opt_present.value().isa[String]())
    assert_equal(c.opt_present.value()[String], "localhost")
    assert_false(Bool(c.opt_missing))

    assert_equal(len(c.mixed), 2)
    assert_true(c.mixed[0].isa[Int]())
    assert_equal(c.mixed[0][Int], 10)
    assert_true(c.mixed[1].isa[EndpointB]())
    assert_equal(c.mixed[1][EndpointB].label, "web")
    assert_equal(c.mixed[1][EndpointB].host, "example.com")

    var edoc = parse_toml[Mode.Eager](src)
    var ec = edoc.take[OneOfContainer]()
    assert_equal(ec.mixed[1][EndpointB].host, "example.com")

    with assert_raises():
        _ = parse_toml("flag = true\n")["flag"].take[OneOf[Int, String]]()

    with assert_raises():
        _ = doc["port_or_host"].take[Variant[Int, String]]()


def test_toml_file_reflection() raises:
    var tmp_path = "/tmp/motoml_test_reflection.toml"
    with open(tmp_path, "w") as f:
        f.write("first_value = 7\nsecond_value = 2.5\n")
    var tf = parse_toml_file(tmp_path)
    var cfg = tf.take[SimpleStruct]()
    remove(tmp_path)
    assert_equal(cfg.first_value, 7)
    assert_equal(cfg.second_value, 2.5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
