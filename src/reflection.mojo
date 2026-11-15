"""Internal struct, enum, and variant reflection helpers."""

from std.builtin._enum import __Enum
from std.builtin.rebind import downcast
from std.builtin.tuple import __TupleLike
from std.builtin.variadics import TypeList, _MLIR
from std.memory import Allocation, Pointer, dealloc
from std.utils import Variant


comptime _IsSinglePayloadCase[CaseTuple: AnyType]: Bool = (
    (
        conforms_to(
            TypeList[
                Trait=AnyType,
                downcast[CaseTuple, __TupleLike].__element_types,
            ]()[0],
            Movable & Deinitable,
        ) if TypeList[
            Trait=AnyType,
            downcast[CaseTuple, __TupleLike].__element_types,
        ]().length
        == 1 else False
    ) if conforms_to(CaseTuple, __TupleLike) else False
)


comptime _IsValidTomlEnum[E: __Enum]: Bool = (
    TypeList[Trait=AnyType, E._enum_case_types].length > 0
    and TypeList[Trait=AnyType, E._enum_case_types].all[_IsSinglePayloadCase]()
)


trait _VariantConstructible(Movable & Deinitable):
    """Internal trait enabling `Toml.take[T]()` for `OneOf` wrappers."""

    comptime _variant_types: _MLIR.KGENParamListType[AnyType]

    @staticmethod
    def _from_variant(
        var v: Variant[*TypeList[Trait=AnyType, Self._variant_types]()]
    ) -> Self:
        ...


def _destroy_partial_struct[
    T: Movable
](var allocation: Allocation[T], initialized_fields: Int):
    """Destroy the first `initialized_fields` fields of a partially built struct.
    """
    comptime Tr = reflect[T]
    comptime field_types = Tr.field_types()
    comptime field_count = Tr.field_count()
    var struct_ptr = allocation.unsafe_ptr()

    comptime for fi in reversed(range(field_count)):
        comptime TYPE = field_types[fi]
        comptime assert conforms_to(TYPE, Deinitable)
        if initialized_fields > fi:
            ref field = Tr.field_ref[fi](struct_ptr[])
            Pointer(to=field).unsafe_deinit_pointee()

    dealloc(allocation^)
