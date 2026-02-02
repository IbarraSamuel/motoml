from motoml import read, reflection
from testing import TestSuite

comptime TOML_CONTENT = """
name = "samuel"
age = 30
other_types = [1.0, 2.0, 3.0]

[language.info]
name = "mojo"
version = "0.26.2.0"
"""


@fieldwise_init
struct Info[o: ImmutOrigin](Movable, Writable):
    var name: StringSlice[Self.o]
    var version: StringSlice[Self.o]

    fn __init__(out self):
        self.name = {}
        self.version = {}


@fieldwise_init
struct Language[o: ImmutOrigin](Movable, Writable):
    var info: Info[Self.o]

    fn __init__(out self):
        self.info = {}


# @fieldwise_init
# @explicit_destroy
struct TestBuild[o: ImmutOrigin](Movable, Writable):
    var name: StringSlice[Self.o]
    var age: Int
    var other_types: List[Float64]
    var language: Language[Self.o]

    fn __init__(out self):
        self.name = {}
        self.age = {}
        self.other_types = {}
        self.language = {}


fn test_toml_to_struct() raises:
    from testing import assert_true

    var toml = read.parse_toml(TOML_CONTENT)
    var test_build = reflection.parse_toml_type[TestBuild[toml.o]](toml^)

    assert_true(test_build.name == "samuel")
    assert_true(test_build.age == 30)


fn main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
