"""Validation levels for lazy TOML parsing.
"""


__enum Validation(Equatable, ImplicitlyCopyable):
    """Validation level parameter for lazy TOML parsing.

    Attributes:
        Trusted: No validation; assumes valid TOML 1.1 for maximum parsing speed.
        Structure: Validates structural TOML syntax, UTF-8, delimiters, and duplicate keys.
        Lexical: Validates number formats, escape syntax, and date/time shapes at parse time.
        Strict: Full spec-conformant semantic checks (overflow, calendar ranges, unicode scalars) at parse time.
    """

    case Trusted
    case Structure
    case Lexical
    case Strict


@always_inline
def validation_level(v: Validation) -> Int:
    """Return integer ordering level (0=Trusted, 1=Structure, 2=Lexical, 3=Strict).
    """
    if v == Validation.Trusted:
        return 0
    if v == Validation.Structure:
        return 1
    if v == Validation.Lexical:
        return 2
    return 3
