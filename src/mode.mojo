"""Parsing and access modes for `motoml`."""

from .lazy.validation import Validation


@fieldwise_init
struct _Mode[id: Int](
    Equatable, ImplicitlyCopyable, TrivialRegisterPassable, Writable
):
    """Compile-time mode token (`Mode.Eager`, `Mode.Strict`, ...)."""

    @always_inline
    def __eq__[other_id: Int](self, other: _Mode[other_id]) -> Bool:
        return Self.id == other_id

    @always_inline
    def __ne__[other_id: Int](self, other: _Mode[other_id]) -> Bool:
        return Self.id != other_id

    def write_to(self, mut w: Some[Writer]):
        comptime if Self.id == 0:
            w.write("Eager")
        elif Self.id == 1:
            w.write("Strict")
        elif Self.id == 2:
            w.write("Lexical")
        elif Self.id == 3:
            w.write("Structure")
        elif Self.id == 4:
            w.write("Trusted")
        else:
            w.write("Unknown")


struct Mode:
    """Parsing and access modes for `parse_toml` and `Toml`."""

    comptime Eager = _Mode[0]()
    comptime Strict = _Mode[1]()
    comptime Lexical = _Mode[2]()
    comptime Structure = _Mode[3]()
    comptime Trusted = _Mode[4]()


@always_inline
def _validation_of[mode_id: Int]() -> Validation:
    """Map a `Mode` discriminant to the internal tape parser `Validation`."""
    comptime if mode_id == 0 or mode_id == 1:
        return Validation.Strict
    elif mode_id == 2:
        return Validation.Lexical
    elif mode_id == 3:
        return Validation.Structure
    return Validation.Trusted
