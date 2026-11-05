from motoml.lazy import parse_lazy, Validation
from std.testing import assert_true, assert_equal


def test_basic_scalars() raises:
    var toml_str = """
    int_val = 42
    hex_val = 0x2A
    float_val = 3.1415
    bool_val = true
    str_val = "hello world"
    lit_val = 'literal string'
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    assert_equal(len(doc), 6)

    var int_v = doc["int_val"].value()
    assert_true(int_v.is_int())
    assert_equal(int_v.as_int().take(), 42)

    var hex_v = doc["hex_val"].value()
    assert_equal(hex_v.as_int().take(), 42)

    var fl_v = doc["float_val"].value()
    assert_true(fl_v.is_float())
    assert_equal(fl_v.as_float().take(), 3.1415)

    var b_v = doc["bool_val"].value()
    assert_true(b_v.is_bool())
    assert_true(b_v.as_bool().take())

    var s_v = doc["str_val"].value()
    assert_true(s_v.is_string())
    assert_equal(s_v.as_string().take(), "hello world")
    assert_equal(s_v.as_slice().value(), "hello world")

    var lit_v = doc["lit_val"].value()
    assert_equal(lit_v.as_string().take(), "literal string")
    print("test_basic_scalars passed!")


def test_tables_and_arrays() raises:
    var toml_str = """
    [server]
    host = "127.0.0.1"
    port = 8080

    [server.database]
    name = "testdb"

    [[users]]
    name = "alice"

    [[users]]
    name = "bob"
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    var srv = doc["server"].value()
    assert_equal(srv["host"].value().as_string().take(), "127.0.0.1")
    assert_equal(srv["port"].value().as_int().take(), 8080)

    var db = srv["database"].value()
    assert_equal(db["name"].value().as_string().take(), "testdb")

    var users = doc["users"].value()
    assert_true(users.is_array())
    assert_equal(len(users), 2)
    assert_equal(users[0].value()["name"].value().as_string().take(), "alice")
    assert_equal(users[1].value()["name"].value().as_string().take(), "bob")
    print("test_tables_and_arrays passed!")


def test_inline_tables_and_arrays() raises:
    var toml_str = """
    arr = [1, 2, 3]
    inline_tbl = { x = 10, y = 20 }
    """
    var doc = parse_lazy(toml_str.as_bytes()).take()
    var arr = doc["arr"].value()
    assert_equal(len(arr), 3)
    assert_equal(arr[0].value().as_int().take(), 1)
    assert_equal(arr[1].value().as_int().take(), 2)
    assert_equal(arr[2].value().as_int().take(), 3)

    var tbl = doc["inline_tbl"].value()
    assert_equal(len(tbl), 2)
    assert_equal(tbl["x"].value().as_int().take(), 10)
    assert_equal(tbl["y"].value().as_int().take(), 20)
    print("test_inline_tables_and_arrays passed!")


def main() raises:
    test_basic_scalars()
    test_tables_and_arrays()
    test_inline_tables_and_arrays()
    print("All lazy unit tests passed!")
