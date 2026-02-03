from motoml.read import TomlType, AnyTomlType, parse_toml
from sys.intrinsics import _type_is_eq, _type_is_eq_parse_time
from builtin.rebind import downcast
from reflection import (
    is_struct_type,
    struct_field_names,
    struct_field_count,
    struct_field_types,
    offset_of,
    get_base_type_name,
    get_type_name,
    struct_field_type_by_name,
)



fn toml_to_type_raises[T: Movable](var toml: TomlType, out obj: T) raises:
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
                var e = toml_to_type_raises[Elem](vb.take_pointee())
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
        ptr[] = toml_to_type_raises[TYPE](tml_v.take_pointee())

    return obj^

# Try to make the optional workflow to work
fn toml_to_type[T: Movable](var toml: TomlType) -> Optional[T]:
    # Calculate all types that matches the type T within the AnyType type
    comptime TomlTypes = type_of(toml.inner).Ts
    comptime FilterType[toml_type: AnyType] = _type_is_eq_parse_time[toml_type, T]()
    comptime TypeMatch = Variadic.filter_types[*TomlTypes, predicate=FilterType]
    comptime MATCH_LEN = Variadic.size(TypeMatch)

    __comptime_assert MATCH_LEN <= 1, "1 or 0 types within AnyTomlType matches type T"

    @parameter
    if MATCH_LEN == 1:  # One type matches with T
        return toml.inner.take[T]()

    # ========= Case the Type is a list, but not List[OpaqueArray] within AnyTomlType ==========

    @parameter
    if get_base_type_name[T]() == "List":
        if not toml.inner.isa[toml.OpaqueArray]():
            print("Type is a list but toml value is not a list.")
            return None

        # Use the fact that List is iterable, to get the inner element using the trait.
        comptime Elem = downcast[downcast[T, Iterable].IteratorType[
            origin_of(toml)
        ].Element, Copyable]

        var lst = List[Elem]()
        ref toml_arr = toml.as_opaque_array()
        while len(toml_arr) > 0:
            var toml_elem = toml_arr.pop().bitcast[TomlType[toml.o]]()

            # parse the toml_elem to the type of the list typed on T
            var e = toml_to_type[Elem](toml_elem.take_pointee())

            if not e:
                print("Not able to parse value from list.")
                return None

            lst.append(e.unsafe_take())

        lst.reverse()
        return rebind_var[T](lst^)

    # ========= Working with Structs here ===============

    __comptime_assert is_struct_type[T](), "T should be a struct because is not a List and is not part of AnyTomlType Variant."
    comptime DT = T

    comptime field_types = struct_field_types[DT]()
    comptime field_count = struct_field_count[DT]()
    comptime field_names = struct_field_names[DT]()

    ref toml_tb = toml.inner[toml.OpaqueTable]

    # ========= Check if the object is initializable before initializing it ===========

    var key_list = List[Optional[StringSlice[toml.o]]](capacity=field_count)
    @parameter
    for fi in range(field_count):
        __comptime_assert conforms_to(field_types[fi], Movable), "Each type Ti of the struct T should be Movable."
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[fi]

        for k in toml_tb.keys():
            if NAME == k:
                key_list.append(k)
                break
        else:
            @parameter
            if get_base_type_name[TYPE]() != "Optional":
                print("A field needed on the struct is not available on the toml table, and such field is not optional.")
                return None

            key_list.append(None)

    # ==== Initialize object =====

    var inner_obj: DT
    __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(inner_obj))
    var struct_ptr = UnsafePointer(to=inner_obj).bitcast[Byte]()

    @parameter
    for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[fi] # this is already checked on previous iteration.
        comptime OFFSET = offset_of[DT, index=fi]()

        var field_ptr = struct_ptr + OFFSET
        var key = key_list[fi]

        @parameter
        if get_base_type_name[TYPE]() == "Optional":
            comptime Inner = downcast[TYPE, Iterator].Element
            if not key: # we identify this value is not in the toml table
                field_ptr.bitcast[Optional[Inner]]()[] = None
                continue

            var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[TomlType[toml.o]]() # we know k exists.
            var value_or_none = toml_to_type[Inner](toml_value.take_pointee())
            if not value_or_none:
                print("Not able to parse toml value into a struct field.")
                _destroy_obj(inner_obj^)
                return None

            field_ptr.bitcast[Optional[Inner]]()[] = value_or_none.take()
            continue

        var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[TomlType[toml.o]]() # we know k exists.
        var value_or_none = toml_to_type[TYPE](toml_value.take_pointee())

        if not value_or_none:
            print("Not able to parse toml value into a struct field.")
            _destroy_obj(inner_obj^)
            return None

        field_ptr.bitcast[TYPE]()[] = value_or_none.take()

    return inner_obj^

fn _destroy_obj[T: Movable, //, initialized_fields: Int = struct_field_count[T]()](var obj: T):
    __comptime_assert is_struct_type[T](), "we can only destroy structs."
    comptime field_types = struct_field_types[T]()

    @parameter
    for fi in range(initialized_fields):
        comptime FT = field_types[fi]
        comptime FO = offset_of[T, index=fi]()

        var field_ptr = (UnsafePointer(to=obj).bitcast[Byte]() + FO)

        @parameter
        if conforms_to(FT, ImplicitlyDestructible):
            field_ptr.bitcast[downcast[FT, ImplicitlyDestructible]]().destroy_pointee()
        elif conforms_to(FT, Movable):
            var field_obj = field_ptr.bitcast[downcast[FT, Movable]]().take_pointee()

            # NOTE: This can cause infinite loop? check if there are movable types with not Implicit Destruction.
            _destroy_obj(field_obj)           
        else:
            from os import abort
            __mlir_op.`lit.ownership.mark_destroyed`(__get_mvalue_as_litref(obj))
            abort(String("Unable to destroy struct:", get_type_name[T]()))
    
    __mlir_op.`lit.ownership.mark_destroyed`(__get_mvalue_as_litref(obj))

        
        
