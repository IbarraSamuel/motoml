"""
TODO: Add Variant Support
TODO: Make it a single implementation.
"""

from .types.toml import Toml
from .result import Result

from std.memory import alloc, dealloc, Layout


@always_inline
def _rebind_list[T: Movable & Deinitable](var toml: Toml) -> Result[List[T]]:
    match toml:
        case .Array:
            var lst = toml^.unsafe_take[List[Toml]]()
            var new_lst = List[T](capacity=len(lst))
            for var v in lst^:
                var new_v = toml_to_type[T](v^)
                if case .Err = new_v:
                    return .Err(new_v^.unsafe_take_error())
                new_lst.append(new_v^.unsafe_take_value())

            return .Ok(new_lst^)
        case _:
            return .Err(t"[TYPE ERROR]: Toml Type is not a List")


@always_inline
def _rebind_struct[T: Movable](var toml: Toml) -> Result[T]:
    comptime Tr = reflect[T]
    comptime field_types = Tr.field_types()
    comptime field_count = Tr.field_count()
    comptime field_names = Tr.field_names()

    if case .Table = toml:
        pass
    else:
        return .Err("The toml value doesn't correspond to a Table.")

    var layout = Layout[T](length=1)
    var allocation = alloc(layout)
    ref toml_tb = toml[Dict[String, Toml]]

    # print("iterate all fields...")
    comptime for fi in range(field_count):
        comptime TYPE = field_types[fi]
        comptime RTYPE = reflect[TYPE]
        comptime NAME = field_names[fi]
        comptime assert conforms_to(TYPE, Movable & Deinitable), String(
            t"Each type TYPE of the struct T with name: {Tr.name()} should"
            t" be Movable and ImplicitlyDeletable. field name: {NAME} with"
            t" idx: {fi}"
        )

        # print("Field name:", NAME)
        ref field_ptr = Tr.field_ref[fi](allocation.unsafe_ptr()[])

        comptime if RTYPE.base_name() == "Optional":
            comptime assert conforms_to(TYPE, Iterable)
            comptime Inner = TYPE.IteratorType[origin_of()].Element
            comptime assert conforms_to(Inner, Movable & Deinitable)

            if NAME not in toml_tb:
                field_ptr = rebind_var[TYPE](Optional[Inner](None))
            else:
                # NOTE: NAN because default should never happen
                var value = toml_tb.pop(NAME, materialize[Toml.NaN]())
                var inner = toml_to_type[Inner](value^)

                if case .Err = inner:
                    # TODO: Destroy properly
                    dealloc(allocation^)
                    # struct_ptr.unsafe_free()
                    return .Err(inner^.unsafe_take_error())

                field_ptr = rebind_var[TYPE](
                    Optional[Inner](inner^.unsafe_take_value())
                )
        else:
            if NAME not in toml_tb:
                # TODO: Destroy properly
                dealloc(allocation^)
                # struct_ptr.unsafe_free()
                # dealloc(struct_ptr^)
                return .Err("Struct field doesn't exists in toml table.")

            var value = toml_tb.pop(NAME, materialize[Toml.NaN]())

            var inner = toml_to_type[TYPE](value^)
            if case .Err = inner:
                # TODO: Destroy properly
                dealloc(allocation^)
                # dealloc(struct_ptr^)
                return .Err(inner^.unsafe_take_error())
            field_ptr = inner^.unsafe_take_value()
        # print(t"Field {NAME} done!")

    # print("struct done!")
    return .Ok(allocation^.unsafe_leak().unsafe_take_pointee())


def toml_to_type[T: Movable & Deinitable](var toml: Toml) -> Result[T]:
    comptime Tr = reflect[T]
    # print(
    #     t"Syntetize type {Tr.name()} from toml type: {toml.get_type_name()}."
    #     t" Base is: {Tr.base_name()}"
    # )

    comptime if T == Toml:
        return .Ok(rebind_var[T](toml^))

    elif TypeList[Toml._enum_case_types].contains[T]():
        return .Ok(toml^.unsafe_take[T]())

    elif Tr.base_name() == "List":
        comptime assert conforms_to(T, Iterable)
        comptime Elem = T.IteratorType[origin_of()].Element
        comptime assert conforms_to(Elem, Movable & Deinitable)
        var lst = _rebind_list[Elem](toml^)
        if case .Err = lst:
            return .Err(lst^.unsafe_take_error())
        return .Ok(rebind_var[T](lst^.unsafe_take_value()))

    elif Tr.is_struct():
        return _rebind_struct[T](toml^)

    elif Tr.base_name() == "Variant":
        return .Err("Variant types not supported yet!")

    else:
        return .Err("Type Not Supported!")


# Result Wrapper
def toml_to_type_raises[T: Movable & Deinitable](var toml: Toml) raises -> T:
    var res = toml_to_type[T](toml^)
    if case .Err = res:
        raise res^.unsafe_take_error()
    return res^.unsafe_take_value()
