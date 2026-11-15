from std.testing import assert_equal, assert_true, assert_false, TestSuite

from motoml import parse_toml, parse_toml_file, Mode, Kind, KindTag
from motoml.types.string_ref import parse_string_escape


def test_empty_table() raises:
    var empty_data = ""
    var empty_toml = parse_toml(empty_data).take()
    assert_equal(empty_toml.root().kind(), KindTag.Table)
    assert_equal(len(empty_toml), 0)

    var empty_eager = parse_toml[Mode.Eager](empty_data).take()
    assert_equal(empty_eager.root().kind(), KindTag.Table)
    assert_equal(len(empty_eager), 0)


def assert_parse_error(content: StringSpan) raises:
    var result = parse_toml(content)
    if case .Err = result:
        _ = result^.unsafe_take_error()
    else:
        _ = result^.unsafe_take_value()
        raise "Malformed TOML input should return a parse error."

    var eager_res = parse_toml[Mode.Eager](content)
    if case .Err = eager_res:
        _ = eager_res^.unsafe_take_error()
    else:
        _ = eager_res^.unsafe_take_value()
        raise "Malformed TOML input should return an Eager parse error."


def assert_parse_success(content: StringSpan) raises:
    var result = parse_toml(content)
    if case .Ok = result:
        _ = result^.unsafe_take_value()
    else:
        _ = result^.unsafe_take_error()
        raise "Valid TOML input should parse successfully."


def test_truncated_quoted_strings() raises:
    assert_parse_error(r'value = "')
    assert_parse_error(r"value = '")
    assert_parse_success(r'value = ""')
    assert_parse_success(r"value = ''")


def test_incomplete_escape_returns_error() raises:
    var result = parse_string_escape("\\")
    if case .Err = result:
        _ = result^.unsafe_take_error()
    else:
        _ = result^.unsafe_take_value()
        raise "An incomplete escape should return a parse error."


def test_simple_struct() raises:
    var test_table = """
    first_value = 1
    second_value = 3.1
    """

    var toml_obj = parse_toml(test_table).take()
    assert_equal(toml_obj["first_value"][Kind.Integer], 1)
    assert_equal(toml_obj["second_value"][Kind.Float], 3.1)

    var eager_obj = parse_toml[Mode.Eager](test_table).take()
    assert_equal(eager_obj["first_value"][Kind.Integer], 1)
    assert_equal(eager_obj["second_value"][Kind.Float], 3.1)


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

    var toml_obj = parse_toml(test_table).take()
    assert_equal(toml_obj["integer"][Kind.Integer], 1)
    assert_equal(toml_obj["float"][Kind.Float], 3.1)
    assert_equal(toml_obj["boolean"][Kind.Boolean], True)
    assert_equal(toml_obj["table"]["key2"][Kind.Integer], 84)


def test_struct_optional() raises:
    var toml = """
    value_1 = "hello"
    """
    var toml_obj = parse_toml(toml).take()
    assert_equal(toml_obj["value_1"][Kind.String], "hello")


def test_plain_unicode_strings() raises:
    var toml = """
    basic = "Café 🔥"
    literal = 'A plain literal'
    """
    var parsed = parse_toml(toml).take()
    assert_equal(parsed["basic"][Kind.String], "Café 🔥")
    assert_equal(parsed["literal"][Kind.String], "A plain literal")


def test_multiline_quote_escapes() raises:
    var test_content = r'''
    str4 = """Here are two quotation marks: "". Simple enough."""
    str5 = """Here are three quotation marks: ""\"."""
    str6 = """Here are fifteen quotation marks: ""\"""\"""\"""\"""\"."""
    str7 = """"This," she said, "is just a pointless statement.""""
    '''
    var toml_obj = parse_toml(test_content).take()

    assert_equal(
        toml_obj["str4"][Kind.String],
        """Here are two quotation marks: \"\". Simple enough.""",
    )
    assert_equal(
        toml_obj["str5"][Kind.String],
        """Here are three quotation marks: \"\"\".""",
    )
    assert_equal(
        toml_obj["str6"][Kind.String],
        """Here are fifteen quotation marks: \"\"\"\"\"\"\"\"\"\"\"\"\"\"\".""",
    )
    assert_equal(
        toml_obj["str7"][Kind.String],
        """\"This,\" she said, \"is just a pointless statement.\"""",
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
    var doc = parse_toml(TOML_CONTENT).take()

    assert_equal(doc["name"].kind(), KindTag.String)
    assert_equal(doc["name"][Kind.String], "samuel")
    assert_equal(doc["age"][Kind.Integer], 30)
    assert_equal(doc["language"]["info"]["name"][Kind.String], "mojo")
    assert_equal(doc["language"]["current_version"][Kind.Float], 0.26)
    assert_equal(doc["other_types"][1][Kind.Float], 2.0)

    var eager = parse_toml[Mode.Eager](TOML_CONTENT).take()
    assert_equal(eager["name"][Kind.String], "samuel")
    assert_equal(eager["language"]["info"]["version"][Kind.String], "0.26.2.0")
    assert_equal(eager["other_types"][2][Kind.Float], 3.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
