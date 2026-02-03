from reflection import (
    is_struct_type,
    struct_field_names,
    struct_field_types,
    struct_field_count,
    offset_of,
)
from sys.intrinsics import _type_is_eq_parse_time
from builtin.rebind import downcast


struct SomeType(Movable, Writable):
    var val: String


fn main():
    var s = String("hey")
    var some_type = val_to_struct[SomeType](s)

    if not some_type:
        print("None")
    else:
        print(some_type.value().val)


fn val_to_struct[
    T: Movable & ImplicitlyDestructible
](var str: String) -> Optional[T]:
    # Work directly on T type, but not on obj type. Because Obj is Optional[T].
    @parameter
    if _type_is_eq_parse_time[T, String]():
        return rebind_var[T](str)

    @parameter
    if not is_struct_type[T]() or not conforms_to(T, ImplicitlyDestructible):
        return None

    comptime DT = downcast[T, ImplicitlyDestructible & Movable]
    comptime field_names = struct_field_names[DT]()
    comptime field_types = struct_field_types[DT]()
    comptime field_count = struct_field_count[DT]()
    # Check that the toml value is a struct
    # if not toml.inner.isa[toml.OpaqueTable]():
    #     return None

    # print(toml)
    # ref toml_tb = toml.inner[toml.OpaqueTable]
    # print(toml)
    # for kv in toml_tb.items():
    #     print("key:", kv.key, ", value:", kv.value.bitcast[TomlType[toml.o]]()[])

    # Check and compile a mapping of values that you require to add into the struct.
    # var key_list = List[Optional[StringSlice[toml.o]]](capacity=field_count)

    # @parameter
    # for fi in range(field_count):
    #     comptime NAME = field_names[fi]
    #     comptime TYPE = field_types[fi]

    #     for k in toml_tb:
    #         if NAME == k:
    #             key_list.append(k)
    #             break
    #     else:

    #         @parameter
    #         if get_base_type_name[TYPE]() == "Optional":
    #             # If it's an optional value in the struct, just leave a None there.
    #             key_list.append(None)
    #         else:
    #             # in case the field is not optional and it's not in the dict
    #             return None

    # Only if we still didn't return anything from past loop then do this.
    # Why? Because you already know you will be able to initialize the object completely.
    # Still parsing the value could be wrong, but this could be handled in next fixes.

    # print(key_list)
    var inner_obj: DT
    __mlir_op.`lit.ownership.mark_initialized`(
        __get_mvalue_as_litref(inner_obj)
    )

    @parameter
    for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime FTYPE = field_types[fi]
        comptime OFFSET = offset_of[T, index=fi]()

        var ptr = (
            UnsafePointer(to=inner_obj).bitcast[Byte]() + OFFSET
        ).bitcast[FTYPE]()

        # TODO: try to avoid the default opaque pointer here.
        # var key = key_list[fi]

        # print("on idx:", fi)
        # print(key)
        # print(toml_tb)
        # var tml_v = toml_tb.pop(key.value(), {}).bitcast[TomlType[toml.o]]()
        # print(tml_v.take_pointee())

        # continue
        # Need to do parameter so compiler doesn't use this path when the type is not optional
        # @parameter
        # if get_base_type_name[FTYPE]() == "Optional":
        #     comptime Inner = downcast[FTYPE, Iterator].Element
        #     if not key:
        #         # Optional is defaultable, so let's use that.
        #         ptr.bitcast[Optional[Inner]]()[] = None
        #         continue

        # if it's optional and there is some value when parsed, then try to parse the inner value, and then
        # just try to fill the optional with the value

        # Take advantage of Optional beign an Iterator, to take T.Element, which is the inner T itself.
        # var result = toml_to_struct[Inner](tml_v.take_pointee())
        # ptr.bitcast[Optional[Inner]]()[] = result^
        # continue

        var field_obj = val_to_struct[FTYPE](str.copy())

        # if not field_obj:
        #     return None

        var field = field_obj.take()
        ptr[] = field

    return inner_obj^
