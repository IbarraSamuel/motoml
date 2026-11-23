"""Parsing and access modes for `motoml`."""

from std.builtin.enum_like import EnumLike
from std.builtin.variadics import ParameterList, TypeList


struct Mode(
    EnumLike, Equatable, ImplicitlyCopyable, TrivialRegisterPassable, Writable
):
    """Parsing and access modes for `parse_toml` and `Toml`.

    - `Mode.Strict` (default): Lazy zero-copy parser with full TOML 1.1 compliance.
    - `Mode.Eager`: Strict TOML 1.1 validation + owned materialized storage.
    - `Mode.Trusted`: Lazy zero-copy parser skipping validation for maximum speed.
    """

    var _value: Int

    @always_inline("builtin")
    def __init__(out self, _value: Int):
        self._value = _value

    comptime Eager = Self(0)
    comptime Strict = Self(1)
    comptime Trusted = Self(2)

    comptime _enum_case_names = ParameterList.of[
        "Eager".value, "Strict".value, "Trusted".value
    ].values
    comptime _enum_case_types = TypeList.splat[3, Tuple[]].values

    @always_inline
    def _get_enum_discriminant(self) -> Int:
        return self._value

    @always_inline
    def _unsafe_get_enum_payload[
        id: Int
    ](ref self) -> ref[self] TypeList[Trait=AnyType, Self._enum_case_types]()[
        id
    ]:
        comptime assert False, "Mode has no payload"

    @always_inline("builtin")
    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    @always_inline("builtin")
    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value

    def write_to(self, mut w: Some[Writer]):
        match self:
            case .Eager:
                w.write("Eager")
            case .Strict:
                w.write("Strict")
            case .Trusted:
                w.write("Trusted")
