"""Validation levels for lazy TOML parsing.
"""


__enum Validation(Equatable):
    case Trusted  # No validation; assume valid TOML 1.1; maximum speed
    case Structure  # Validate structural TOML syntax, delimiters, duplicate keys
    case Lexical  # Validate number formats, escape syntax, date/time shapes
    case Strict  # Spec-conformant semantic checks (overflow, unicode scalars, etc.)
