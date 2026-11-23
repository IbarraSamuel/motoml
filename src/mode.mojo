"""Parsing and access modes for `motoml`."""


__enum Mode(Writable):
    """Parsing and access modes for `parse_toml` and `Toml`.

    - `Mode.Strict` (default): Lazy zero-copy parser with full TOML 1.1 compliance.
    - `Mode.Eager`: Strict TOML 1.1 validation + owned materialized storage.
    - `Mode.Trusted`: Lazy zero-copy parser skipping validation for maximum speed.
    """

    case Eager
    case Strict
    case Trusted
