"""
TODO: Add Variant Support
TODO: Make it a single implementation.
"""

from .toml_types import TomlType, AnyTomlType, TableKey
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


from utils import Variant
from os import abort


@explicit_destroy("The Result must be consumed.")
struct Result[T: Movable](Boolable):
    var inner: Variant[Self.T, Error]

    @implicit
    fn __init__(out self, var value: Self.T):
        self.inner = value^

    @implicit
    fn __init__(out self, var error: Error):
        self.inner = error^

    fn __bool__(self) -> Bool:
        return self.inner.isa[Self.T]()

    fn ref_value(self) -> ref[self.inner] Self.T:
        return self.inner[Self.T]

    fn ref_error(self) -> ref[self.inner] Error:
        return self.inner[Error]

    # -- Destroy methods --

    fn destroy(deinit self):
        """Destroy the result, and not use the value inside."""
        pass

    @always_inline
    fn unsafe_take_value(deinit self) -> Self.T:
        """Take the value. You must check that there is a value. If not, you will get UB.
        """
        return self.inner.unsafe_take[Self.T]()

    @always_inline
    fn unsafe_take_error(deinit self) -> Error:
        """Take the error. You must check that there is an error. If not, you will get UB.
        """
        return self.inner.unsafe_take[Error]()

    fn error(deinit self) raises -> Error:
        """Take the error or raises otherwise."""
        if self:
            raise "Result has a value T, not an error."
        return self^.unsafe_take_error()

    fn value(deinit self) raises -> Self.T:
        """Take the value or raises otherwise."""
        if not self:
            raise "Result type has an error, not a value T."
        return self^.unsafe_take_value()

    fn as_optional(deinit self) -> Optional[Self.T]:
        """Convert to an Optional type."""
        if not self:
            return None
        return self^.unsafe_take_value()

    fn or_else(
        deinit self,
        var default: downcast[Self.T, ImplicitlyDestructible & Movable],
    ) -> Self.T where conforms_to(Self.T, ImplicitlyDestructible):
        """Take the value or return a default value."""
        if not self:
            return default^
        return self^.unsafe_take_value()


# Try to make the optional workflow to work
fn toml_to_type[T: Movable](var toml: TomlType) -> Result[T]:
    # Calculate all types that matches the type T within the AnyType type
    comptime TomlTypes = type_of(toml.inner).Ts
    comptime FilterType[toml_type: AnyType] = _type_is_eq_parse_time[
        toml_type, T
    ]()
    comptime TypeMatch = Variadic.filter_types[*TomlTypes, predicate=FilterType]
    comptime MATCH_LEN = Variadic.size(TypeMatch)

    comptime assert (
        MATCH_LEN <= 1
    ), "1 or 0 types within AnyTomlType matches type T"

    @parameter
    if MATCH_LEN == 1:  # One type matches with T
        return toml.inner.take[T]()

    # ========= Case the Type is a list, but not List[OpaqueArray] within AnyTomlType ==========

    @parameter
    if get_base_type_name[T]() == "List":
        if not toml.inner.isa[toml.OpaqueArray]():
            return Error("Type is a list but toml value is not a list.")

        # Use the fact that List is iterable, to get the inner element using the trait.
        comptime Elem = downcast[
            downcast[T, Iterable].IteratorType[origin_of(toml)].Element,
            Copyable,
        ]

        var lst = List[Elem]()
        ref toml_arr = toml.as_opaque_array()
        while len(toml_arr) > 0:
            var toml_elem = toml_arr.pop().bitcast[TomlType[toml.o]]()

            # parse the toml_elem to the type of the list typed on T
            var e = toml_to_type[Elem](toml_elem.take_pointee())

            if not e:
                return e^.unsafe_take_error()

            lst.append(e^.unsafe_take_value())

        lst.reverse()
        return rebind_var[T](lst^)

    # ========= Working with Structs here ===============

    comptime assert is_struct_type[T](), (
        "T should be a struct because is not a List and is not part of"
        " AnyTomlType Variant."
    )
    comptime DT = T

    comptime field_types = struct_field_types[DT]()
    comptime field_count = struct_field_count[DT]()
    comptime field_names = struct_field_names[DT]()

    ref toml_tb = toml.inner[toml.OpaqueTable]

    # ========= Check if the object is initializable before initializing it ===========

    var key_list = List[Optional[TableKey[toml.o]]](capacity=field_count)

    @parameter
    for fi in range(field_count):
        comptime assert conforms_to(
            field_types[fi], Movable
        ), "Each type Ti of the struct T should be Movable."
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[fi]

        for k in toml_tb.keys():
            if NAME == StringSlice(unsafe_from_utf8=k.value):
                key_list.append(k.copy())
                break
        else:

            @parameter
            if get_base_type_name[TYPE]() != "Optional":
                return Error(
                    "A field needed on the struct is not available on the toml"
                    " table, and such field is not optional."
                )

            key_list.append(None)

    # ==== Initialize object =====

    var inner_obj: DT
    __mlir_op.`lit.ownership.mark_initialized`(
        __get_mvalue_as_litref(inner_obj)
    )
    var struct_ptr = UnsafePointer(to=inner_obj).bitcast[Byte]()

    @parameter
    for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[
            fi
        ]  # this is already checked on previous iteration.
        comptime OFFSET = offset_of[DT, index=fi]()

        var field_ptr = struct_ptr + OFFSET
        var key = key_list[fi]

        @parameter
        if get_base_type_name[TYPE]() == "Optional":
            comptime Inner = downcast[TYPE, Iterator].Element
            if not key:  # we identify this value is not in the toml table
                field_ptr.bitcast[Optional[Inner]]()[] = None
                continue

            var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[
                TomlType[toml.o]
            ]()  # we know k exists.
            var value_or_none = toml_to_type[Inner](toml_value.take_pointee())
            if not value_or_none:
                _destroy_obj(inner_obj^)
                return value_or_none^.unsafe_take_error()

            field_ptr.bitcast[Optional[Inner]]()[] = (
                value_or_none^.unsafe_take_value()
            )
            continue

        var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[
            TomlType[toml.o]
        ]()  # we know k exists.
        var value_or_none = toml_to_type[TYPE](toml_value.take_pointee())

        if not value_or_none:
            _destroy_obj(inner_obj^)
            return value_or_none^.unsafe_take_error()

        field_ptr.bitcast[TYPE]()[] = value_or_none^.unsafe_take_value()

    return inner_obj^


# Raises workflow
fn toml_to_type_raises[T: Movable](var toml: TomlType) raises -> T:
    # Calculate all types that matches the type T within the AnyType type
    comptime TomlTypes = type_of(toml.inner).Ts
    comptime FilterType[toml_type: AnyType] = _type_is_eq_parse_time[
        toml_type, T
    ]()
    comptime TypeMatch = Variadic.filter_types[*TomlTypes, predicate=FilterType]
    comptime MATCH_LEN = Variadic.size(TypeMatch)

    comptime assert (
        MATCH_LEN <= 1
    ), "1 or 0 types within AnyTomlType matches type T"

    @parameter
    if MATCH_LEN == 1:  # One type matches with T
        return toml.inner.take[T]()

    # ========= Case the Type is a list, but not List[OpaqueArray] within AnyTomlType ==========

    @parameter
    if get_base_type_name[T]() == "List":
        if not toml.inner.isa[toml.OpaqueArray]():
            raise "Type is a list but toml value is not a list."

        # Use the fact that List is iterable, to get the inner element using the trait.
        comptime Elem = downcast[
            downcast[T, Iterable].IteratorType[origin_of(toml)].Element,
            Copyable,
        ]

        var lst = List[Elem]()
        ref toml_arr = toml.as_opaque_array()
        while len(toml_arr) > 0:
            var toml_elem = toml_arr.pop().bitcast[TomlType[toml.o]]()

            # parse the toml_elem to the type of the list typed on T
            var e = toml_to_type[Elem](toml_elem.take_pointee())

            # if not e:
            #     raise "Not able to parse value from list."

            lst.append(e^.value())

        lst.reverse()
        return rebind_var[T](lst^)

    # ========= Working with Structs here ===============

    comptime assert is_struct_type[T](), (
        "T should be a struct because is not a List and is not part of"
        " AnyTomlType Variant."
    )
    comptime DT = T

    comptime field_types = struct_field_types[DT]()
    comptime field_count = struct_field_count[DT]()
    comptime field_names = struct_field_names[DT]()

    ref toml_tb = toml.inner[toml.OpaqueTable]

    # ========= Check if the object is initializable before initializing it ===========

    var key_list = List[Optional[TableKey[toml.o]]](capacity=field_count)

    @parameter
    for fi in range(field_count):
        comptime assert conforms_to(
            field_types[fi], Movable
        ), "Each type Ti of the struct T should be Movable."
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[fi]

        for k in toml_tb.keys():
            if NAME == StringSlice(unsafe_from_utf8=k.value):
                key_list.append(k.copy())
                break
        else:

            @parameter
            if get_base_type_name[TYPE]() != "Optional":
                raise "A field needed on the struct is not available on the toml table, and such field is not optional."

            key_list.append(None)

    # ==== Initialize object =====

    var inner_obj: DT
    __mlir_op.`lit.ownership.mark_initialized`(
        __get_mvalue_as_litref(inner_obj)
    )
    var struct_ptr = UnsafePointer(to=inner_obj).bitcast[Byte]()

    @parameter
    for fi in range(field_count):
        comptime NAME = field_names[fi]
        comptime TYPE = field_types[
            fi
        ]  # this is already checked on previous iteration.
        comptime OFFSET = offset_of[DT, index=fi]()

        var field_ptr = struct_ptr + OFFSET
        var key = key_list[fi]

        @parameter
        if get_base_type_name[TYPE]() == "Optional":
            comptime Inner = downcast[TYPE, Iterator].Element
            if not key:  # we identify this value is not in the toml table
                field_ptr.bitcast[Optional[Inner]]()[] = None
                continue

            var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[
                TomlType[toml.o]
            ]()  # we know k exists.
            var value_or_none = toml_to_type[Inner](toml_value.take_pointee())
            if not value_or_none:
                _destroy_obj(inner_obj^)
                raise value_or_none^.unsafe_take_error()

            field_ptr.bitcast[Optional[Inner]]()[] = (
                value_or_none^.unsafe_take_value()
            )
            continue

        var toml_value = toml_tb.pop(key.unsafe_take(), {}).bitcast[
            TomlType[toml.o]
        ]()  # we know k exists.
        var value_or_none = toml_to_type[TYPE](toml_value.take_pointee())

        if not value_or_none:
            _destroy_obj(inner_obj^)
            raise value_or_none^.unsafe_take_error()

        field_ptr.bitcast[TYPE]()[] = value_or_none^.unsafe_take_value()

    return inner_obj^


fn _destroy_obj[
    T: Movable, //, initialized_fields: Int = struct_field_count[T]()
](var obj: T):
    comptime assert is_struct_type[T](), "we can only destroy structs."
    comptime field_types = struct_field_types[T]()

    @parameter
    for fi in range(initialized_fields):
        comptime FT = field_types[fi]
        comptime FO = offset_of[T, index=fi]()

        var field_ptr = UnsafePointer(to=obj).bitcast[Byte]() + FO

        @parameter
        if conforms_to(FT, ImplicitlyDestructible):
            field_ptr.bitcast[
                downcast[FT, ImplicitlyDestructible]
            ]().destroy_pointee()
        elif conforms_to(FT, Movable):
            var field_obj = field_ptr.bitcast[
                downcast[FT, Movable]
            ]().take_pointee()

            # NOTE: This can cause infinite loop? check if there are movable types with not Implicit Destruction.
            _destroy_obj(field_obj)
        else:
            from os import abort

            __mlir_op.`lit.ownership.mark_destroyed`(
                __get_mvalue_as_litref(obj)
            )
            abort(String("Unable to destroy struct:", get_type_name[T]()))

    __mlir_op.`lit.ownership.mark_destroyed`(__get_mvalue_as_litref(obj))
