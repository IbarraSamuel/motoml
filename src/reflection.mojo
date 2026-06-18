"""
TODO: Add Variant Support
TODO: Make it a single implementation.
"""

from .types.toml import Toml
from .result import Result

from std.sys.intrinsics import _type_is_eq, _type_is_eq_parse_time
from std.builtin.rebind import downcast
from std.reflection import reflect
from std.utils import Variant
from std.memory import stack_allocation, alloc


# Result Wrapper
def toml_to_type[T: Movable & ImplicitlyDeletable](var toml: Toml) -> Result[T]:
    try:
        return toml_to_type_raises[T](toml^)
    except e:
        return e^


def toml_to_type_raises[
    T: Movable & ImplicitlyDeletable
](var toml: Toml) raises -> T:
    # Calculate all types that matches the type T within the AnyType type
    comptime Tr = reflect[T]

    # elif _type_is_eq_parse_time[T, StringSlice[toml.o]]():
    #     if not toml.inner.isa[toml.String]():
    #         raise "[TYPE MISMATCH]: Type defined is a StringLike but TomlType is not a String."
    #     return rebind_var[T](
    #         StringSlice(unsafe_from_utf8=toml.inner[toml.String].data)
    #     )

    comptime if Toml.AllTypes.contains[T]():
        if not toml.isa[T]():
            raise "[TYPE MISMATCH]: Type defined doesn't align with TomlType."
        return toml^.take[T]()

    # ========= Case the Type is a list, but not List[OpaqueArray] within AnyTomlType ==========

    comptime if Tr.base_name() == "List":
        comptime assert conforms_to(T, Iterable)
        comptime Elem = T.IteratorType[origin_of()].Element
        comptime assert conforms_to(Elem, Movable & ImplicitlyDeletable)

        if not toml.isa[Toml.Array]():
            raise "[TYPE MISMATCH] Type is a list but toml value is not a list."
        var lst = [
            toml_to_type_raises[Elem](elem^)
            for var elem in toml^.take[Toml.Array]()
        ]
        return rebind_var[T](lst^)

    # ========= Working with Structs here ===============

    comptime assert Tr.is_struct(), (
        "T should be a struct because is not a List and is not a direct Toml"
        " Type"
    )

    comptime field_types = Tr.field_types()
    comptime field_count = Tr.field_count()
    comptime field_names = Tr.field_names()

    if not toml.isa[Toml.Table]():
        raise "The toml value doesn't correspond to a Table."

    var toml_tb = toml^.take[Toml.Table]()
    var struct_ptr = stack_allocation[1, T]()

    # ========= Check if the object is initializable before initializing it ===========

    comptime for fi in range(field_count):
        comptime TYPE = field_types[fi]
        comptime NAME = field_names[fi]
        comptime assert conforms_to(TYPE, Movable & ImplicitlyDeletable), (
            "Each type Ti of the struct T should be Movable and"
            " ImplicitlyDeletable."
        )

        ref field_ptr = Tr.field_ref[fi](struct_ptr[])
        var key_in_toml = NAME in toml_tb
        comptime if reflect[TYPE].base_name() == "Optional":
            comptime assert conforms_to(TYPE, Iterator)
            comptime Inner = TYPE.Element
            comptime assert conforms_to(Inner, Movable & ImplicitlyDeletable)

            if key_in_toml:
                field_ptr = rebind_var[TYPE](Optional[Inner](None))
            else:
                var inner = toml_to_type_raises[Inner](toml_tb.pop(NAME))
                field_ptr = rebind_var[TYPE](Optional[Inner](inner^))
        else:
            if not key_in_toml:
                raise "Struct field doesn't exists in toml table."

            var value = toml_tb.pop(NAME)
            field_ptr = toml_to_type_raises[TYPE](value^)

    return struct_ptr.take_pointee()
