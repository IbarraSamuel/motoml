from motoml.read import TomlType, AnyTomlType, parse_toml
from sys.intrinsics import _type_is_eq
from builtin.rebind import downcast
from reflection import (
    is_struct_type,
    struct_field_names,
    get_type_name,
    struct_field_count,
    struct_field_types,
    offset_of,
    get_base_type_name,
    struct_field_type_by_name,
)

from sys import size_of


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


fn parse_toml_type[T: Movable](var toml: TomlType, out obj: T) raises:
    comptime o = toml.o

    # Would be great if this could be checked with Where clauses.
    @parameter
    for ti in range(Variadic.size(AnyTomlType[toml.o].Ts)):
        comptime tt = AnyTomlType[toml.o].Ts[ti]

        @parameter
        if _type_is_eq[tt, T]():
            print("found type!")
            return rebind_var[T](toml.inner.take[T]())

    @parameter
    if (
        _type_is_eq[T, toml.Integer]()
        or _type_is_eq[T, toml.Float]()
        or _type_is_eq[T, toml.Boolean]()
        or _type_is_eq[T, toml.String]()
        or _type_is_eq[T, toml.OpaqueArray]()
        or _type_is_eq[T, toml.OpaqueTable]()
    ):
        print("First check is not working somehow!")
        return toml.inner.take[T]()

    @parameter
    if get_base_type_name[T]() == "List":
        if toml.isa[TomlType[o].Array]():
            comptime Iterator = downcast[T, Iterable].IteratorType[
                origin_of(toml)
            ]

            comptime Elem = downcast[Iterator.Element, Copyable]

            var lst = List[Elem]()
            ref toml_arr = toml.as_opaque_array()
            while len(toml_arr) > 0:
                var vb = toml_arr.pop().bitcast[TomlType[o]]()
                var e = parse_toml_type[Elem](vb.take_pointee())
                lst.append(e^)

            obj = rebind_var[T](lst^)
            return
        raise Error("Type is a list, but toml value is not an array")

    __comptime_assert is_struct_type[T](), "T must be a struct"
    __comptime_assert conforms_to(
        T, ImplicitlyDestructible
    ), "We cannot handle Linear Types yet."

    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(obj))
    var obj = trait_downcast_var[ImplicitlyDestructible & Movable](obj^)

    comptime field_names = struct_field_names[T]()
    comptime field_types = struct_field_types[T]()

    @parameter
    for fi in range(struct_field_count[T]()):
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[fi]
        comptime OFFSET = offset_of[T, index=fi]()

        var kk: StringSlice[o]
        for k in toml.inner[toml.OpaqueTable].keys():
            if k == NAME:
                kk = k
                break
        else:
            raise Error("Missing field: " + NAME)

        var tml_v = toml.inner[toml.OpaqueTable].pop(kk).bitcast[TomlType[o]]()

        if not conforms_to(TYPE, Movable):
            raise Error(
                "Type should be defaultable, Movable and ImplicitlyDestrutible."
            )

        var ptr = (UnsafePointer(to=obj).bitcast[Byte]() + OFFSET).bitcast[
            TYPE
        ]()
        ptr[] = parse_toml_type[TYPE](tml_v.take_pointee())

    return obj^
