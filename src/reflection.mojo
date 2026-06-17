"""
TODO: Add Variant Support
TODO: Make it a single implementation.
"""

from .types import TomlType, AnyTomlType, TomlTypes
from std.sys.intrinsics import _type_is_eq, _type_is_eq_parse_time
from std.builtin.rebind import downcast
from std.reflection import reflect, Reflected
from std.utils import Variant
from std.memory import stack_allocation, alloc


@explicit_destroy("The Result must be consumed.")
struct Result[T: Movable](
    # Boolable,
    # Equatable,
    Movable,
    # Writable,
):
    var inner: Variant[Self.T, Error]

    @implicit
    def __init__(out self, var value: Self.T):
        self.inner = value^

    @implicit
    def __init__(out self, var error: Error):
        self.inner = error^

    def __bool__(self) -> Bool:
        return self.inner.isa[Self.T]()

    def ref_value(self) -> ref[self.inner] Self.T:
        return self.inner[Self.T]

    def ref_error(self) -> ref[self.inner] Error:
        return self.inner[Error]

    # -- Destroy methods --

    def destroy(deinit self):
        """Destroy the result, and not use the value inside."""
        pass

    @always_inline
    def unsafe_take_value(deinit self) -> Self.T:
        """Take the value. You must check that there is a value. If not, you will get UB.
        """
        return self.inner^.unsafe_take[Self.T]()

    @always_inline
    def unsafe_take_error(deinit self) -> Error:
        """Take the error. You must check that there is an error. If not, you will get UB.
        """
        return self.inner^.unsafe_take[Error]()

    def take_error(deinit self) raises -> Error:
        """Take the error or raises otherwise."""
        if self:
            raise "Result has a value T, not an error."
        return self^.unsafe_take_error()

    def take_value(deinit self) raises -> Self.T:
        """Take the value or raises otherwise."""
        if not self:
            raise "Result type has an error, not a value T."
        return self^.unsafe_take_value()

    def as_optional(deinit self) -> Optional[Self.T]:
        """Convert to an Optional type."""
        if not self:
            return None
        return self^.unsafe_take_value()

    def or_else[
        t: Movable & ImplicitlyDeletable, //
    ](deinit self: Result[t], var default: t) -> t:
        """Take the value or return a default value."""
        if not self:
            return default^
        return self^.unsafe_take_value()


# Result Wrapper
def toml_to_type[
    T: Movable & ImplicitlyDeletable
](var toml: TomlType) -> Result[T]:
    try:
        return toml_to_type_raises[T](toml^)
    except e:
        return e^


def toml_to_list[
    E: Movable & ImplicitlyDeletable
](var toml: TomlType) raises -> List[E]:
    if not toml.isa[TomlTypes.Array]():
        raise "Type Mismatch. Expected Array to convert to list."
    return [toml_to_type_raises[E](elem^) for var elem in toml^.array()]


def toml_to_type_raises[
    T: Movable & ImplicitlyDeletable
](var toml: TomlType) raises -> T:
    # Calculate all types that matches the type T within the AnyType type
    comptime Tr = reflect[T]

    # elif _type_is_eq_parse_time[T, StringSlice[toml.o]]():
    #     if not toml.inner.isa[toml.String]():
    #         raise "[TYPE MISMATCH]: Type defined is a StringLike but TomlType is not a String."
    #     return rebind_var[T](
    #         StringSlice(unsafe_from_utf8=toml.inner[toml.String].data)
    #     )

    comptime if AnyTomlType.Ts.contains[T]():
        if not toml.isa[T]():
            raise "[TYPE MISMATCH]: Type defined doesn't align with TomlType."
        var v = toml^.take_inner().take[T]()
        return v^

    # ========= Case the Type is a list, but not List[OpaqueArray] within AnyTomlType ==========

    comptime if reflect[T].base_name() == "List":
        if not toml.isa[TomlTypes.Array]():
            raise "[TYPE MISMATCH] Type is a list but toml value is not a list."

        # Use the fact that List is iterable, to get the inner element using the trait.

        comptime Elem = downcast[
            downcast[T, Iterator].Element, Movable & ImplicitlyDeletable
        ]
        var lst = toml_to_list[Elem](toml^)
        return rebind_var[T](lst^)

    # ========= Working with Structs here ===============

    comptime assert Tr.is_struct(), (
        "T should be a struct because is not a List and is not part of"
        " AnyTomlType Variant."
    )

    comptime field_types = Tr.field_types()
    comptime field_count = Tr.field_count()
    comptime field_names = Tr.field_names()

    var toml_tb = toml^.table()

    # ========= Check if the object is initializable before initializing it ===========

    var key_list = List[Optional[StaticString]](capacity=field_count)

    comptime for fi in range(field_count):
        comptime TYPE = field_types[fi]
        comptime NAME = field_names[fi]
        comptime assert conforms_to(
            TYPE, Movable
        ), "Each type Ti of the struct T should be Movable."
        comptime assert conforms_to(
            TYPE, ImplicitlyDeletable
        ), "Each type Ti of the struct T should be Movable."

        if NAME in toml_tb:
            key_list.append(NAME)
        else:
            comptime if reflect[TYPE].base_name() != "Optional":
                raise "A field needed on the struct is not available on the toml table, and such field is not optional."

            key_list.append(None)

    # ==== Initialize object =====

    # var inner_obj: T
    # __mlir_op.`lit.ownership.mark_initialized`(
    #     __get_mvalue_as_litref(inner_obj)
    # )
    # var struct_ptr = UnsafePointer(to=inner_obj).bitcast[Byte]()
    var struct_ptr = alloc[T](1)

    comptime for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime TYPE = downcast[
            field_types[fi], Movable & ImplicitlyDeletable
        ]  # already checked
        # comptime OFFSET = Tr.field_offset[index=fi]()
        var key = key_list[fi]
        ref field_ptr = Tr.field_ref[fi](struct_ptr[])

        comptime if reflect[TYPE].base_name() == "Optional":
            comptime Inner = downcast[
                downcast[TYPE, Iterator].Element, Movable & ImplicitlyDeletable
            ]

            if not key:  # we identify this value is not in the toml table
                field_ptr = rebind_var[TYPE](Optional[Inner](None))
            else:
                var k = String(key.unsafe_take())
                var toml_value = toml_tb.pop(k)
                field_ptr = rebind_var[TYPE](
                    toml_to_type_raises[Optional[Inner]](toml_value^)
                )
        else:
            # we know k exists.
            var toml_value = toml_tb.pop(String(key.unsafe_take()))
            field_ptr = rebind_var[TYPE](toml_to_type_raises[TYPE](toml_value^))

    return struct_ptr.take_pointee()
