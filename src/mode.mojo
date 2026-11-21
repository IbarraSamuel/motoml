"""Parsing and access modes for `motoml`."""


@fieldwise_init
struct _Mode[id: Int](
    Equatable, ImplicitlyCopyable, TrivialRegisterPassable, Writable
):
    """Compile-time mode token (`Mode.Eager`, `Mode.Strict`, `Mode.Trusted`)."""

    @always_inline
    def __eq__[other_id: Int](self, other: _Mode[other_id]) -> Bool:
        return Self.id == other_id

    @always_inline
    def __ne__[other_id: Int](self, other: _Mode[other_id]) -> Bool:
        return Self.id != other_id

    def write_to(self, mut w: Some[Writer]):
        comptime match Self.id:
            case 0:
                w.write("Eager")
            case 1:
                w.write("Strict")
            case 2:
                w.write("Trusted")
            case _:
                w.write("Unknown")


struct Mode:
    """Parsing and access modes for `parse_toml` and `Toml`.

    - `Mode.Strict` (default): Lazy zero-copy parser with full TOML 1.1 compliance.
    - `Mode.Eager`: Strict TOML 1.1 validation + owned materialized storage.
    - `Mode.Trusted`: Lazy zero-copy parser skipping validation for maximum speed.
    """

    comptime Eager = _Mode[0]()
    comptime Strict = _Mode[1]()
    comptime Trusted = _Mode[2]()


@always_inline
def _is_eager[mode_id: Int]() -> Bool:
    """Return True when `mode_id` corresponds to `Mode.Eager`."""
    return mode_id == 0


@always_inline
def _is_strict[mode_id: Int]() -> Bool:
    """Return True when `mode_id` validates strictly at parse time (`Eager` or `Strict`).
    """
    return mode_id != 2
