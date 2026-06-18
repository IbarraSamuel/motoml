from std.testing import assert_equal, TestSuite

from motoml.parser import parse_toml_raises
from motoml.reflection import toml_to_type_raises
from motoml.types.toml import Toml


struct SimpleStruct(Movable):
    var first_value: Int
    var second_value: Float64


def test_simple_struct() raises:
    var test_table = """
    first_value = 1
    second_value = 3.1
    """

    var toml_obj = parse_toml_raises(test_table)
    # var simple_struct = toml_to_type_raises[SimpleStruct](toml_obj^)

    assert_equal(toml_obj[Toml.Table]["first_value"][Toml.Integer], 1)
    assert_equal(toml_obj[Toml.Table]["second_value"][Toml.Float], 3.1)


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

    assert_equal(toml_obj[Toml.Table]["integer"][Toml.Integer], 1)
    assert_equal(toml_obj[Toml.Table]["float"][Toml.Float], 3.1)
    assert_equal(toml_obj[Toml.Table]["boolean"][Toml.Boolean], True)
    assert_equal(
        toml_obj[Toml.Table]["table"][Toml.Table]["key2"][Toml.Integer], 84
    )


struct StructOptional(Movable):
    var value_1: String
    var value_2: Optional[Int]


def test_struct_optional() raises:
    var toml = """
    value_1 = "hello"
    """
    var toml_obj = parse_toml_raises(toml)

    assert_equal(toml_obj[Toml.Table]["value_1"][Toml.String], "hello")


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
    var value = toml_obj^.take[Toml.Table]()

    assert_equal(value["name"][Toml.String], "samuel")
    assert_equal(value["age"][Toml.Integer], 30)
    assert_equal(
        value["language"][Toml.Table]["info"][Toml.Table]["name"][Toml.String],
        "mojo",
    )
    assert_equal(
        value["language"][Toml.Table]["current_version"][Toml.Float], 0.26
    )


def main() raises:
    # var ts = TestSuite()
    # ts.test[test_simple_struct]()
    # ts^.run()
    TestSuite.discover_tests[__functions_in_module()]().run()
