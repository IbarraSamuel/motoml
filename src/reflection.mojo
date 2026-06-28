"""
TODO: Add Variant Support
TODO: Make it a single implementation.
"""

from .types.toml import Toml
from .result import Result

from std.sys import size_of
from std.sys.intrinsics import _type_is_eq, _type_is_eq_parse_time
from std.builtin.rebind import downcast
from std.reflection import reflect, Reflected
from std.utils import Variant
from std.memory import stack_allocation, alloc, dealloc, Layout


@always_inline
def _rebind_toml_type[
    T: Movable & ImplicitlyDeletable
](var toml: Toml) -> Result[T] where Toml.AllTypes.contains[T]():
    if not toml.isa[T]():
        return Error(
            "[TYPE ERROR]: Toml Type is {toml.get_type_name()} but rebind type"
            " is {reflect[T].name()}"
        )

    return toml^.unsafe_take[T]()


@always_inline
def _rebind_list[
    T: Movable & ImplicitlyDeletable
](var toml: Toml) -> Result[List[T]]:
    if not toml.isa[Toml.Array]():
        return Error(
            t"[TYPE ERROR]: Toml Type is {toml.get_type_name()} but rebind type"
            t" is a List"
        )
    var lst = toml^.unsafe_take[Toml.Array]()
    var new_lst = List[T](capacity=len(lst))
    for var v in lst^:
        var new_v = toml_to_type[T](v^)
        if not new_v:
            return new_v^.unsafe_take_error()
        new_lst.append(new_v^.unsafe_take_value())

    return new_lst^


@always_inline
def _rebind_struct[T: Movable](var toml: Toml) -> Result[T]:
    comptime Tr = reflect[T]
    comptime field_types = Tr.field_types()
    comptime field_count = Tr.field_count()
    comptime field_names = Tr.field_names()

    if not toml.isa[Toml.Table]():
        return Error("The toml value doesn't correspond to a Table.")

    # print(t"building struct allocation for struct : {Tr.name()}")
    var struct_ptr = alloc[T](1)
    # print("allocation done")
    # var struct_ptr = stack_allocation[1, T]()
    var toml_tb = toml^.unsafe_take[Toml.Table]()

    # print("iterate all fields...")
    comptime for fi in range(field_count):
        comptime TYPE = field_types[fi]
        comptime RTYPE = reflect[TYPE]
        comptime NAME = field_names[fi]
        comptime assert conforms_to(
            TYPE, Movable & ImplicitlyDeletable
        ), String(
            t"Each type TYPE of the struct T with name: {Tr.name()} should"
            t" be Movable and ImplicitlyDeletable. field name: {NAME} with"
            t" idx: {fi}"
        )

        # print("Field name:", NAME)
        ref field_ptr = Tr.field_ref[fi](struct_ptr[])

        comptime if RTYPE.base_name() == "Optional":
            comptime assert conforms_to(TYPE, Iterator)
            comptime Inner = TYPE.Element
            comptime assert conforms_to(Inner, Movable & ImplicitlyDeletable)

            if NAME not in toml_tb:
                field_ptr = rebind_var[TYPE](Optional[Inner](None))
            else:
                # NOTE: NAN because default should never happen
                var value = toml_tb.pop(NAME, {Toml.NaN()})
                var inner = toml_to_type[Inner](value^)

                if not inner:
                    # TODO: Destroy properly
                    struct_ptr.free()
                    return inner^.unsafe_take_error()

                field_ptr = rebind_var[TYPE](
                    Optional[Inner](inner^.unsafe_take_value())
                )
        else:
            if NAME not in toml_tb:
                # TODO: Destroy properly
                struct_ptr.free()
                # dealloc(struct_ptr^)
                return Error("Struct field doesn't exists in toml table.")

            var value = toml_tb.pop(NAME, {Toml.NaN()})

            var inner = toml_to_type[TYPE](value^)
            if not inner:
                # TODO: Destroy properly
                _ = struct_ptr.free()
                # dealloc(struct_ptr^)
                return inner^.unsafe_take_error()
            field_ptr = inner^.unsafe_take_value()
        # print(t"Field {NAME} done!")

    # print("struct done!")
    return struct_ptr.take_pointee()


def toml_to_type[T: Movable & ImplicitlyDeletable](var toml: Toml) -> Result[T]:
    comptime Tr = reflect[T]
    # print(
    #     t"Syntetize type {Tr.name()} from toml type: {toml.get_type_name()}."
    #     t" Base is: {Tr.base_name()}"
    # )

    comptime if _type_is_eq[T, Toml]():
        return rebind_var[T](toml^)

    elif Toml.AllTypes.contains[T]():
        return _rebind_toml_type[T](toml^)

    elif Tr.base_name() == "List":
        comptime assert conforms_to(T, Iterable)
        comptime Elem = T.IteratorType[origin_of()].Element
        comptime assert conforms_to(Elem, Movable & ImplicitlyDeletable)
        var lst = _rebind_list[Elem](toml^)
        if not lst:
            return lst^.unsafe_take_error()
        return rebind_var[T](lst^.unsafe_take_value())

    elif Tr.is_struct():
        return _rebind_struct[T](toml^)

    elif Tr.base_name() == "Variant":
        return Error("Variant types not supported yet!")

    else:
        return Error("Type Not Supported!")


# Result Wrapper
def toml_to_type_raises[
    T: Movable & ImplicitlyDeletable
](var toml: Toml) raises -> T:
    var res = toml_to_type[T](toml^)
    if not res:
        raise res^.unsafe_take_error()
    return res^.unsafe_take_value()
