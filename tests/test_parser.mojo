from std.testing import assert_equal, TestSuite, assert_true

from motoml.mmap_file import MappedFile
from motoml.parser import parse_toml_file, parse_toml_raises
from motoml.types.toml import Toml


# struct SimpleStruct(Movable):
#     var first_value: Int
#     var second_value: Float64


def test_empty_table() raises:
    var empty_data = ""
    var empty_toml = parse_toml_raises[log=False](empty_data)
    if case .Table = empty_toml:
        pass
    else:
        raise "Value is expected to be a table"
    assert_equal(len(empty_toml[Dict[String, Toml]]), 0)


def test_parse_mapped_file() raises:
    var mapped_file = MappedFile("toml_files/valid/example.toml")
    assert_true(len(mapped_file.bytes()) > 0)
    mapped_file.close()
    assert_equal(len(mapped_file), 0)
    mapped_file.close()

    var empty_file = MappedFile("toml_files/valid/empty-nothing.toml")
    assert_equal(len(empty_file.bytes()), 0)
    empty_file.close()

    var result = parse_toml_file("toml_files/valid/example.toml")
    var toml_obj = result^.take()
    assert_equal(
        toml_obj[Dict[String, Toml]]["numtheory"][Dict[String, Toml]]["boring"][
            Bool
        ],
        False,
    )


def test_simple_struct() raises:
    var test_table = """
    first_value = 1
    second_value = 3.1
    """

    var toml_obj = parse_toml_raises(test_table)
    assert_equal(toml_obj[Dict[String, Toml]]["first_value"][Int], 1)
    assert_equal(toml_obj[Dict[String, Toml]]["second_value"][Float64], 3.1)


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
    date = 2024-11-02
    time = 22:01:04
    datetime = 2026-02-01T22:01:38-05:00
    array = [1,2,3,4]
    table = {key=32, key2=84}
    """

    var toml_obj = parse_toml_raises[log=False](test_table)
    # var at = toml_to_type_raises[AllTypes](toml_obj^)

    assert_equal(toml_obj[Dict[String, Toml]]["integer"][Int], 1)
    assert_equal(toml_obj[Dict[String, Toml]]["float"][Float64], 3.1)
    assert_equal(toml_obj[Dict[String, Toml]]["boolean"][Bool], True)
    assert_equal(
        toml_obj[Dict[String, Toml]]["table"][Dict[String, Toml]]["key2"][Int],
        84,
    )


def test_struct_optional() raises:
    var toml = """
    value_1 = "hello"
    """
    var toml_obj = parse_toml_raises(toml)

    assert_equal(toml_obj[Dict[String, Toml]]["value_1"][String], "hello")


def test_multiline_quote_escapes() raises:
    var test_content = r'''
    str4 = """Here are two quotation marks: "". Simple enough."""
    str5 = """Here are three quotation marks: ""\"."""
    str6 = """Here are fifteen quotation marks: ""\"""\"""\"""\"""\"."""
    str7 = """"This," she said, "is just a pointless statement.""""
    '''
    var toml_obj = parse_toml_raises(test_content)
    ref values = toml_obj[Dict[String, Toml]]

    assert_equal(
        values["str4"][String],
        r"Here are two quotation marks: \"\". Simple enough.",
    )
    assert_equal(
        values["str5"][String],
        r"Here are three quotation marks: \"\"\".",
    )
    assert_equal(
        values["str6"][String],
        r"Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\".",
    )
    assert_equal(
        values["str7"][String],
        r"\"This,\" she said, \"is just a pointless statement.\"",
    )


def test_nested() raises:
    var TOML_CONTENT = """
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
    var value = toml_obj^.unsafe_take[Dict[String, Toml]]()

    if case .String(name) = value["name"]:
        assert_equal(name, "samuel")
    else:
        raise "match not found"

    assert_equal(value["name"][String], "samuel")

    if case .Integer(age) = value["age"]:
        assert_equal(age, 30)
    else:
        raise "match not found"

    assert_equal(value["age"][Int], 30)

    if case .Table(lang) = value["language"]:
        if case .Table(info) = lang["info"]:
            if case .String(name) = info["name"]:
                assert_equal(name, "mojo")
            else:
                raise "match not found"
        else:
            raise "match not found"
    else:
        raise "match not found"

    assert_equal(
        value["language"][Dict[String, Toml]]["info"][Dict[String, Toml]][
            "name"
        ][String],
        "mojo",
    )

    if case .Table(lang) = value["language"]:
        if case .Float(version) = lang["current_version"]:
            assert_equal(version, 0.26)

    assert_equal(
        value["language"][Dict[String, Toml]]["current_version"][Float64],
        0.26,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
