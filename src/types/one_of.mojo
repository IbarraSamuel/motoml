"""Reflectable `Variant` wrapper (`OneOf`) for TOML deserialization."""

from std.builtin.variadics import TypeList
from std.utils import Variant
from ..reflection import _VariantConstructible


struct OneOf[*Ts: Movable & Deinitable](
    Copyable where Ts.all_conforms_to[Copyable](),
    Equatable where Ts.all_conforms_to[Equatable](),
    ImplicitlyCopyable where Ts.all_conforms_to[ImplicitlyCopyable](),
    Movable,
    Writable where Ts.all_conforms_to[Writable](),
    _VariantConstructible,
):
    """Reflectable union wrapper around `Variant[*Ts]` for TOML struct fields.

    `std.utils.Variant` does not expose its type parameters through Mojo's
    `reflect[T]` API. `OneOf` exposes its type list via `_VariantConstructible`
    so `Toml.take[OneOf[...]]()` and struct fields of type `OneOf[...]`
    deserialize automatically.
    """

    comptime _variant_types = Self.Ts.values
    var value: Variant[*Self.Ts]

    @implicit
    def __init__[T: Movable](out self, var value: T):
        self.value = Variant[*Self.Ts](value^)

    @implicit
    def __init__(out self, var value: Variant[*Self.Ts]):
        self.value = value^

    @staticmethod
    def _from_variant(
        var v: Variant[*TypeList[Trait=AnyType, Self._variant_types]()]
    ) -> Self:
        return Self(rebind_var[Variant[*Self.Ts]](v^))

    @always_inline
    def isa[T: AnyType](self) -> Bool:
        return self.value.isa[T]()

    @__unsafe_nested_origins_read_only
    @always_inline
    def __getitem_param__[
        T: AnyType
    ](ref self) -> ref[origin_of(self.value)._get_owned_interior["value"]] T:
        return self.value[T]

    @always_inline
    def unwrap[T: Movable](deinit self) -> T:
        return self.value^.unwrap[T]()

    @always_inline
    def into_variant(deinit self) -> Variant[*Self.Ts]:
        return self.value^

    def __eq__(
        self, other: Self
    ) -> Bool where Self.Ts.all_conforms_to[Equatable]():
        return self.value == other.value

    def __ne__(
        self, other: Self
    ) -> Bool where Self.Ts.all_conforms_to[Equatable]():
        return self.value != other.value

    def write_to(
        self, mut writer: Some[Writer]
    ) where Self.Ts.all_conforms_to[Writable]():
        self.value.write_to(writer)

    def write_repr_to(
        self, mut writer: Some[Writer]
    ) where Self.Ts.all_conforms_to[Writable]():
        self.value.write_repr_to(writer)
