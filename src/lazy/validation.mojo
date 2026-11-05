"""Validation levels for lazy TOML parsing.
"""


__enum Validation(Equatable):
    """Validation level parameter for lazy TOML parsing.

    Attributes:
        Trusted: No validation; assumes valid TOML 1.1 for maximum parsing speed.
        Structure: Validates structural TOML syntax, delimiters, and duplicate keys.
        Lexical: Validates number formats, escape syntax, and date/time shapes.
        Strict: Spec-conformant semantic checks (overflow, unicode scalars, etc.).
    """

    case Trusted  # No validation; assume valid TOML 1.1; maximum speed
    case Structure  # Validate structural TOML syntax, delimiters, duplicate keys
    case Lexical  # Validate number formats, escape syntax, date/time shapes
    case Strict  # Spec-conformant semantic checks (overflow, unicode scalars, etc.)
