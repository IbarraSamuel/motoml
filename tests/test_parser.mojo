from std.testing import assert_equal, TestSuite

from motoml.parser import parse_toml_raises
from motoml.reflection import toml_to_type_raises
from motoml.types import TomlTypes


struct SimpleStruct(Movable):
    var first_value: Int
    var second_value: Float64


def test_simple_struct() raises:
    var test_table = """
    first_value = 1
    second_value = 3.1
    """

    var toml_obj = parse_toml_raises[log=True](test_table)
    print(toml_obj)
    ref first_value = toml_obj["first_value"]
    print(first_value)
    # var simple_struct = toml_to_type_raises[SimpleStruct](toml_obj^)

    # assert_equal(simple_struct.first_value, 1)
    # assert_equal(simple_struct.second_value, 3.1)


struct AllTypes(Movable):
    var integer: Int
    var float: Float64
    var boolean: Bool
    var string: String
    var string_lit: String
    var multiline: String
    var multiline_lit: String
    var date: TomlTypes.Date
    var time: TomlTypes.Time
    var datetime: TomlTypes.DateTime
    var array: List[Int]
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
    array = [1,2,3,4]
    table = {key=32, key2=84}
    """

    var toml_obj = parse_toml_raises(test_table)
    # var at = toml_to_type_raises[AllTypes](toml_obj^)

    # assert_equal(at.integer, 1)
    # assert_equal(at.float, 3.1)
    # assert_equal(at.boolean, True)


struct StructOptional(Movable):
    var value_1: String
    var value_2: Optional[Int]


def test_struct_optional() raises:
    var toml = """
    value_1 = "hello"
    """
    var toml_obj = parse_toml_raises(toml)
    # var value = toml_to_type_raises[StructOptional](toml_obj^)

    # assert_equal(value.value_1, "hello")
    # assert_equal(Bool(value.value_2), False)


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


def test_nested() raises:
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
    var toml_obj = parse_toml_raises(TOML_CONTENT)
    # var value = toml_to_type_raises[TestBuild](toml_obj^)

    # assert_equal(value.name, "samuel")
    # assert_equal(value.age, 30)
    # assert_equal(value.language.info.name, "mojo")
    # assert_equal(value.language.current_version.value(), 0.26)
    # assert_equal(Bool(value.language.stable_version), False)


def main() raises:
    var ts = TestSuite()
    ts.test[test_simple_struct]()
    ts^.run()
    # TestSuite.discover_tests[__functions_in_module()]().run()
