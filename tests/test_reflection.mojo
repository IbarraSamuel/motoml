from motoml.read import parse_toml, TomlType, AnyTomlType
from motoml.reflection import toml_to_type_raises, toml_to_type
from testing import TestSuite, assert_equal
from sys.intrinsics import _type_is_eq, _type_is_eq_parse_time


@fieldwise_init
struct Info[o: ImmutOrigin](Movable, Writable, Representable):
    var name: StringSlice[Self.o]
    var version: StringSlice[Self.o]

    fn __repr__(self) -> String:
        var s = String()
        self.write_to(s)
        return s

@fieldwise_init
struct Language[o: ImmutOrigin](Movable, Writable, Representable):
    var info: Info[Self.o]
    var current_version: Optional[Float64]
    var stable_version: Optional[Float64]

    fn __repr__(self) -> String:
        var s = String()
        self.write_to(s)
        return s


@fieldwise_init
struct TestBuild[o: ImmutOrigin](Movable, Writable, Representable):
    var name: StringSlice[Self.o]
    var age: Int
    var other_types: List[Float64]
    var language: Language[Self.o]

    fn __repr__(self) -> String:
        var s = String()
        self.write_to(s)
        return s

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

comptime TOML_OBJ = parse_toml(TOML_CONTENT)


fn test_toml_to_type_raises() raises:
    var toml_obj = materialize[TOML_OBJ]()
    var value = toml_to_type_raises[TestBuild[StaticConstantOrigin]](toml_obj^)

    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)


fn test_toml_to_type() raises:
    var toml_obj = materialize[TOML_OBJ]()
    var value_or_none = toml_to_type[TestBuild[StaticConstantOrigin]](toml_obj^)

    # in case there is no value, the error will pop up into the test error.
    var is_some = Bool(value_or_none)
    try:
        assert_equal(is_some, True)
    except e:
        value_or_none^.destroy()
        raise e^

    # Cannot fail
    var value = value_or_none^.value()

    assert_equal(value.name, "samuel")
    assert_equal(value.age, 30)
    assert_equal(value.language.info.name, "mojo")
    assert_equal(value.language.current_version.value(), 0.26)
    assert_equal(Bool(value.language.stable_version), False)



fn main() raises:
    # test_toml_to_type()
    TestSuite.discover_tests[__functions_in_module()]().run()
