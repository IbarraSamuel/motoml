from motoml.read import TomlType, AnyTomlType, parse_toml
from sys.intrinsics import _type_is_eq
from builtin.rebind import downcast
from reflection import (
    is_struct_type,
    struct_field_names,
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

fn toml_to_struct[T: Movable](var toml: TomlType) -> Optional[T]:

    # Would be great if this could be checked with Where clauses.
    @parameter
    for ti in range(Variadic.size(AnyTomlType[toml.o].Ts)):
        @parameter
        if _type_is_eq[AnyTomlType[toml.o].Ts[ti], T]():
            print("direct type...")
            return toml.inner.take[T]()

    # @parameter
    # if (
    #     _type_is_eq[T, toml.Integer]()
    #     or _type_is_eq[T, toml.Float]()
    #     or _type_is_eq[T, toml.Boolean]()
    #     or _type_is_eq[T, toml.String]()
    #     or _type_is_eq[T, toml.OpaqueArray]()
    #     or _type_is_eq[T, toml.OpaqueTable]()
    # ):
    #     return toml.inner.take[T]()
        # import os
        # os.abort("This should not happen since should be covered by first loop")

    @parameter
    if get_base_type_name[T]() == "List":
        if not toml.isa[toml.Array]():
            return None

        comptime Iterator = downcast[T, Iterable].IteratorType[
            origin_of(toml)
        ]

        # This is the element typed on the Type provided (T)
        comptime Elem = downcast[Iterator.Element, Copyable]

        var lst = List[Elem]()
        ref toml_arr = toml.as_opaque_array()
        while len(toml_arr) > 0:
            var vb = toml_arr.pop().bitcast[TomlType[toml.o]]()
            var e = toml_to_struct[Elem](vb.take_pointee())
            if not e:
                return None
            lst.append(e.unsafe_take())

        return rebind_var[T](lst^)

    # Work directly on T type, but not on obj type. Because Obj is Optional[T].
    @parameter
    if not is_struct_type[T]() or not conforms_to(T, ImplicitlyDestructible):
        return None

    comptime DT = downcast[T, ImplicitlyDestructible & Movable]
    comptime field_names = struct_field_names[DT]()
    comptime field_types = struct_field_types[DT]()
    comptime field_count = struct_field_count[DT]()
    # Check that the toml value is a struct
    if not toml.inner.isa[toml.OpaqueTable]():
        return None

    # print(toml)
    ref toml_tb = toml.inner[toml.OpaqueTable]
    # print(toml)
    # for kv in toml_tb.items():
    #     print("key:", kv.key, ", value:", kv.value.bitcast[TomlType[toml.o]]()[])



    # Check and compile a mapping of values that you require to add into the struct.
    var key_list = List[Optional[StringSlice[toml.o]]](capacity=field_count)
    @parameter
    for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[fi]

        for k in toml_tb:
            if NAME == k:
                key_list.append(k)
                break
        else:
            @parameter
            if get_base_type_name[TYPE]() == "Optional":
                # If it's an optional value in the struct, just leave a None there.
                key_list.append(None)
            else:
                # in case the field is not optional and it's not in the dict
                return None

    # Only if we still didn't return anything from past loop then do this.
    # Why? Because you already know you will be able to initialize the object completely.
    # Still parsing the value could be wrong, but this could be handled in next fixes.

    # print(key_list)
    var inner_obj: DT
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(inner_obj))

    @parameter
    for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime FTYPE= field_types[fi]
        comptime OFFSET = offset_of[T, index=fi]()

        var ptr = (UnsafePointer(to=inner_obj).bitcast[Byte]() + OFFSET).bitcast[FTYPE]()

        # TODO: try to avoid the default opaque pointer here.
        var key = key_list[fi]

        # print("on idx:", fi)
        # print(key)
        # print(toml_tb)
        var tml_v = toml_tb.pop(key.value(), {}).bitcast[TomlType[toml.o]]()
        # print(tml_v.take_pointee())

        # continue
        # Need to do parameter so compiler doesn't use this path when the type is not optional
        @parameter
        if get_base_type_name[FTYPE]() == "Optional":
            comptime Inner = downcast[FTYPE, Iterator].Element
            if not key:
                # Optional is defaultable, so let's use that.
                ptr.bitcast[Optional[Inner]]()[] = None
                continue

            # if it's optional and there is some value when parsed, then try to parse the inner value, and then
            # just try to fill the optional with the value

            # Take advantage of Optional beign an Iterator, to take T.Element, which is the inner T itself.
            var result = toml_to_struct[Inner](tml_v.take_pointee())
            ptr.bitcast[Optional[Inner]]()[] = result^
            continue

        var field_obj = toml_to_struct[FTYPE](tml_v.take_pointee())

        if not field_obj:
            return None

        var field: FTYPE = rebind[Optional[FTYPE]](field_obj).take()
        ptr[] = field
        
    return inner_obj^
