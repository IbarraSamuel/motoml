"""Low-level scanner and lexing helpers for lazy TOML parsing.
"""

from .node import Kind, NodeFlags
from std.collections import Span

comptime SquareBracketOpen = Byte(ord("["))
comptime SquareBracketClose = Byte(ord("]"))
comptime CurlyBracketOpen = Byte(ord("{"))
comptime CurlyBracketClose = Byte(ord("}"))
comptime NewLine = Byte(ord("\n"))
comptime Enter = Byte(ord("\r"))
comptime Space = Byte(ord(" "))
comptime Tab = Byte(ord("\t"))
comptime Comment = Byte(ord("#"))
comptime Comma = Byte(ord(","))
comptime Equal = Byte(ord("="))
comptime Period = Byte(ord("."))
comptime DoubleQuote = Byte(ord('"'))
comptime SingleQuote = Byte(ord("'"))
comptime Escape = Byte(ord("\\"))


@always_inline
def is_bare_key_byte(b: Byte) -> Bool:
    """Determine whether a byte is allowed in an unquoted TOML bare key.

    Bare keys only permit ASCII letters, digits, underscores, and dashes
    (`[A-Za-z0-9_-]`).

    Args:
        b: Byte to check.

    Returns:
        `True` if `b` is a valid bare key byte.
    """
    return (
        Byte(ord("a")) <= b <= Byte(ord("z"))
        or Byte(ord("A")) <= b <= Byte(ord("Z"))
        or Byte(ord("0")) <= b <= Byte(ord("9"))
        or b == Byte(ord("_"))
        or b == Byte(ord("-"))
    )


@always_inline
def skip_spaces_and_tabs(data: Span[Byte, _], mut idx: Int):
    """Advance index past horizontal whitespace (ASCII spaces and tabs).

    Args:
        data: Document byte buffer.
        idx: In-out scanning index.
    """
    while idx < len(data):
        var b = data[idx]
        if b == Space or b == Tab:
            idx += 1
        else:
            return


@always_inline
def skip_to_newline(data: Span[Byte, _], mut idx: Int):
    """Advance index until reaching a newline byte (`\\n`) or EOF.

    Args:
        data: Document byte buffer.
        idx: In-out scanning index.
    """
    while idx < len(data) and data[idx] != NewLine:
        idx += 1


@always_inline
def skip_comment(data: Span[Byte, _], mut idx: Int) -> Bool:
    """Advance index to the end of a comment line, checking for illegal characters.

    Enforces TOML specification rules: control characters (other than tab) and
    bare carriage returns are forbidden within comments.

    Args:
        data: Document byte buffer.
        idx: In-out scanning index pointing to comment content.

    Returns:
        `True` if the comment was well-formed; `False` if an invalid control
        character or bare CR was encountered.
    """
    while idx < len(data):
        var b = data[idx]
        if b == NewLine:
            return True
        elif b == Enter:
            if idx + 1 < len(data) and data[idx + 1] == NewLine:
                return True
            return False
        if (b < 0x20 and b != 0x09) or b == 0x7F:
            return False
        idx += 1
    return True


@always_inline
def skip_whitespace_and_comments(data: Span[Byte, _], mut idx: Int):
    """Advance index through arbitrary sequences of whitespace and comments.

    Handles spaces, tabs, CR, LF, and `#` comments.

    Args:
        data: Document byte buffer.
        idx: In-out scanning index.
    """
    while idx < len(data):
        var b = data[idx]
        if b == Space or b == Tab or b == NewLine or b == Enter:
            idx += 1
        elif b == Comment:
            skip_to_newline(data, idx)
        else:
            return


def classify_scalar(data: Span[Byte, _], start: Int, end: Int) -> UInt8:
    """Quickly determine the `Kind` of an unquoted scalar literal from its bytes.

    Categorizes the byte slice into `Kind.Boolean`, `Kind.NaN`, `Kind.Inf`,
    `Kind.Integer`, `Kind.Float`, `Kind.Date`, `Kind.Time`, `Kind.DateTime`, or
    `Kind.Empty` if invalid.

    Args:
        data: Document byte buffer.
        start: Start byte index of the scalar.
        end: End byte index of the scalar.

    Returns:
        The matched `Kind` constant.
    """
    var span = data[start:end]
    var n = len(span)
    if n == 0:
        return Kind.Empty

    var first = span[0]
    if first == Byte(ord("t")) and n == 4:
        if (
            span[1] == Byte(ord("r"))
            and span[2] == Byte(ord("u"))
            and span[3] == Byte(ord("e"))
        ):
            return Kind.Boolean
    elif first == Byte(ord("f")) and n == 5:
        if (
            span[1] == Byte(ord("a"))
            and span[2] == Byte(ord("l"))
            and span[3] == Byte(ord("s"))
            and span[4] == Byte(ord("e"))
        ):
            return Kind.Boolean
    elif (first == Byte(ord("n")) and n == 3) or (
        (first == Byte(ord("+")) or first == Byte(ord("-")))
        and n == 4
        and span[1] == Byte(ord("n"))
    ):
        return Kind.NaN
    elif (first == Byte(ord("i")) and n == 3) or (
        (first == Byte(ord("+")) or first == Byte(ord("-")))
        and n == 4
        and span[1] == Byte(ord("i"))
    ):
        return Kind.Inf

    if (
        first != Byte(ord("+"))
        and first != Byte(ord("-"))
        and not (first >= Byte(ord("0")) and first <= Byte(ord("9")))
    ):
        return Kind.Empty

    if (
        (first == Byte(ord("+")) or first == Byte(ord("-")))
        and n > 2
        and span[1] == Byte(ord("0"))
    ):
        var p = span[2]
        if (
            p == Byte(ord("x"))
            or p == Byte(ord("X"))
            or p == Byte(ord("b"))
            or p == Byte(ord("B"))
            or p == Byte(ord("o"))
            or p == Byte(ord("O"))
        ):
            return Kind.Empty

    if span[0] == Byte(ord("0")) and n > 1:
        var p = span[1]
        if p == Byte(ord("X")) or p == Byte(ord("B")) or p == Byte(ord("O")):
            return Kind.Empty

    var is_hex = (
        n > 2 and span[0] == Byte(ord("0")) and span[1] == Byte(ord("x"))
    )
    var is_bin = (
        n > 2 and span[0] == Byte(ord("0")) and span[1] == Byte(ord("b"))
    )
    var is_oct = (
        n > 2 and span[0] == Byte(ord("0")) and span[1] == Byte(ord("o"))
    )
    if is_hex or is_bin or is_oct:
        return Kind.Integer

    var dashes = 0
    var colons = 0
    var dots = 0
    var exponent = False

    for i in range(n):
        var b = span[i]
        if b < 0x20 or b == 0x7F:
            return Kind.Empty
        if b == Byte(ord("-")):
            if i > 0:  # don't count leading minus as date dash
                dashes += 1
        elif b == Byte(ord(":")):
            colons += 1
        elif b == Byte(ord(".")):
            dots += 1
        elif b == Byte(ord("e")) or b == Byte(ord("E")):
            exponent = True
        elif not (
            (Byte(ord("0")) <= b <= Byte(ord("9")))
            or b == Byte(ord("+"))
            or b == Byte(ord("_"))
            or b == Byte(ord("T"))
            or b == Byte(ord("t"))
            or b == Byte(ord("Z"))
            or b == Byte(ord("z"))
            or b == Byte(ord(" "))
        ):
            return Kind.Empty

    if dashes >= 2:
        if colons > 0:
            return Kind.DateTime
        if dashes == 2 and n == 10:
            return Kind.Date

    if colons > 0 and dashes == 0:
        return Kind.Time

    if dots > 0 or exponent:
        return Kind.Float

    return Kind.Integer
