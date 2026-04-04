"""
TODO: Add Variant Support
TODO: Make it a single implementation.
"""

from .types import TomlType, AnyTomlType
from std.sys.intrinsics import _type_is_eq, _type_is_eq_parse_time
from std.builtin.rebind import downcast
from std.reflection import (
    is_struct_type,
    struct_field_names,
    struct_field_count,
    struct_field_types,
    offset_of,
    get_base_type_name,
    get_type_name,
    struct_field_type_by_name,
)


from std.utils import Variant
from std.os import abort


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
        t: Movable & ImplicitlyDestructible, //
    ](deinit self: Result[t], var default: t) -> t:
        """Take the value or return a default value."""
        if not self:
            return default^
        return self^.unsafe_take_value()


# Result Wrapper
def toml_to_type[T: Movable](var toml: TomlType) -> Result[T]:
    try:
        return toml_to_type_raises[T](toml^)
    except e:
        return e^


def toml_to_type_raises[T: Movable](var toml: TomlType) raises -> T:
    # Calculate all types that matches the type T within the AnyType type

    comptime if _type_is_eq_parse_time[T, String]():
        if not toml.inner.isa[toml.String]():
            raise "[TYPE MISMATCH]: Type defined is a String but TomlType is not a String."
        return rebind_var[T](toml.inner[toml.String])

    # elif _type_is_eq_parse_time[T, StringSlice[toml.o]]():
    #     if not toml.inner.isa[toml.String]():
    #         raise "[TYPE MISMATCH]: Type defined is a StringLike but TomlType is not a String."
    #     return rebind_var[T](
    #         StringSlice(unsafe_from_utf8=toml.inner[toml.String].data)
    #     )

    comptime TomlTypes = type_of(toml.inner).Ts
    comptime FilterType[toml_type: AnyType] = _type_is_eq_parse_time[
        toml_type, T
    ]()
    comptime TypeMatch = Variadic.filter_types[
        T=AnyType, *TomlTypes, predicate=FilterType
    ]
    comptime MATCH_LEN = Variadic.size_types[TypeMatch]

    comptime assert (
        MATCH_LEN <= 1
    ), "1 or 0 types within AnyTomlType matches type T"

    comptime if MATCH_LEN == 1:  # One type matches with T
        var v = toml^.take_inner().take[T]()
        return v^

    # ========= Case the Type is a list, but not List[OpaqueArray] within AnyTomlType ==========

    comptime if get_base_type_name[T]() == "List":
        if not toml.inner.isa[toml.OpaqueArray]():
            raise "[TYPE MISMATCH] Type is a list but toml value is not a list."

        # Use the fact that List is iterable, to get the inner element using the trait.
        comptime Elem = downcast[
            downcast[T, Iterable].IteratorType[origin_of(toml)].Element,
            Copyable,
        ]

        var lst = List[Elem]()
        ref toml_arr = toml.as_opaque_array()
        while len(toml_arr) > 0:
            var toml_elem = toml_arr.pop().bitcast[TomlType]()

            # parse the toml_elem to the type of the list typed on T
            var e = toml_to_type_raises[Elem](toml_elem.take_pointee())

            # if not e:
            #     raise "Not able to parse value from list."

            lst.append(e^)

        lst.reverse()
        return rebind_var[T](lst^)

    # ========= Working with Structs here ===============

    comptime assert is_struct_type[T](), (
        "T should be a struct because is not a List and is not part of"
        " AnyTomlType Variant."
    )
    comptime assert conforms_to(T, ImplicitlyDestructible), (
        "In case the struct is not completely initialized, we should be able to"
        " safely destroy the struct."
    )
    comptime DT = downcast[T, Movable & ImplicitlyDestructible]

    comptime field_types = struct_field_types[DT]()
    comptime field_count = struct_field_count[DT]()
    comptime field_names = struct_field_names[DT]()

    ref toml_tb = toml.inner[toml.OpaqueTable]

    # ========= Check if the object is initializable before initializing it ===========

    var key_list = List[Optional[StaticString]](capacity=field_count)

    comptime for fi in range(field_count):
        comptime TYPE = field_types[fi]
        comptime NAME = field_names[fi]
        comptime assert conforms_to(
            TYPE, Movable
        ), "Each type Ti of the struct T should be Movable."
        comptime assert conforms_to(
            TYPE, ImplicitlyDestructible
        ), "Each type Ti of the struct T should be Movable."

        if NAME in toml_tb:
            key_list.append(NAME)
        else:
            comptime if get_base_type_name[TYPE]() != "Optional":
                raise "A field needed on the struct is not available on the toml table, and such field is not optional."

            key_list.append(None)

    # ==== Initialize object =====

    var inner_obj: DT
    __mlir_op.`lit.ownership.mark_initialized`(
        __get_mvalue_as_litref(inner_obj)
    )
    var struct_ptr = UnsafePointer(to=inner_obj).bitcast[Byte]()

    comptime for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime TYPE = downcast[
            field_types[fi], Movable & ImplicitlyDestructible
        ]  # already checked
        comptime OFFSET = offset_of[DT, index=fi]()

        var field_ptr = struct_ptr + OFFSET
        var key = key_list[fi]

        comptime if get_base_type_name[TYPE]() == "Optional":
            comptime Inner = downcast[TYPE, Iterator].Element
            if not key:  # we identify this value is not in the toml table
                field_ptr.bitcast[Optional[Inner]]()[] = None
            else:
                var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[
                    TomlType
                ]()  # we know k exists.
                field_ptr.bitcast[Optional[Inner]]()[] = toml_to_type_raises[
                    Inner
                ](toml_value.take_pointee())
        else:
            # we know k exists.
            var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[
                TomlType
            ]()

            field_ptr.bitcast[TYPE]()[] = toml_to_type_raises[TYPE](
                toml_value.take_pointee()
            )

    return inner_obj^
