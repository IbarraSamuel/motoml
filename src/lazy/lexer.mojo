"""Low-level scanner and lexing helpers for lazy TOML parsing.
"""

from .node import Kind
from std.memory import pack_bits
from std.bit import count_trailing_zeros
from std.collections.string._utf8 import _is_valid_utf8

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

comptime CC_BARE: UInt8 = 1
comptime CC_HWS: UInt8 = 2
comptime CC_CTRL_NO_TAB: UInt8 = 4

# 256-entry byte classification table in .rodata (values < 0x80 so 1 UTF-8 byte per entry).
comptime _CC_TABLE: StaticString = (
    "\x04\x04\x04\x04\x04\x04\x04\x04\x04\x02\x04\x04\x04\x04\x04\x04"
    "\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04\x04"
    "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00"
    "\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00"
    "\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01"
    "\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x01"
    "\x00\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01"
    "\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x04"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
)

# 256-entry scalar action table:
#   0 = fast scalar body ('0'..'9', '+', '_', 'T', 't', 'Z', 'z')
#   1 = stop byte ('\t', '\n', '\r', ',', ']', '}', '#')
#   2 = '.'
#   3 = '-'
#   4 = ':'
#   5 = 'e' or 'E'
#   6 = ' ' (space: stops scalar unless at date-time offset 10 followed by digit)
#   7 = other byte (triggers fallback for true/false/inf/nan/hex/bin/oct or invalid)
comptime _SCALAR_TABLE: StaticString = (
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x01\x01\x07\x07\x01\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x06\x07\x07\x01\x07\x07\x07\x07\x07\x07\x07\x00\x01\x03\x02\x07"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x04\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x05\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x00\x07\x07\x07\x07\x07\x00\x07\x07\x01\x07\x00"
    "\x07\x07\x07\x07\x07\x05\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x00\x07\x07\x07\x07\x07\x00\x07\x07\x01\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
    "\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
)


@always_inline
def is_valid_utf8_fast(data: Span[Byte, _]) -> Bool:
    """Fast SIMD ASCII-first UTF-8 validation.

    Scans 64-byte blocks for the high bit (`0x80`). Pure-ASCII blocks are guaranteed
    valid UTF-8 and end on a codepoint boundary; if any non-ASCII byte is encountered,
    delegates the remaining slice `data[i:]` to the stdlib SIMD UTF-8 validator.
    """
    var ptr = data.unsafe_ptr()
    var n = len(data)
    var i = 0
    comptime W = 16
    while i + 64 <= n:
        var v0 = ptr.unsafe_load[width=W](i)
        var v1 = ptr.unsafe_load[width=W](i + 16)
        var v2 = ptr.unsafe_load[width=W](i + 32)
        var v3 = ptr.unsafe_load[width=W](i + 48)
        var hi = ((v0 | v1) | (v2 | v3)) & 0x80
        if any(hi.ne(0)):
            return _is_valid_utf8(data[i:])
        i += 64
    while i + W <= n:
        var v = ptr.unsafe_load[width=W](i)
        if any((v & 0x80).ne(0)):
            return _is_valid_utf8(data[i:])
        i += W
    while i < n:
        if ptr[unsafe_offset=i] >= 0x80:
            return _is_valid_utf8(data[i:])
        i += 1
    return True


@always_inline
def is_bare_key_byte(b: Byte) -> Bool:
    """Determine whether a byte is allowed in an unquoted TOML bare key."""
    return (_CC_TABLE.unsafe_ptr()[unsafe_offset=Int(b)] & CC_BARE) != 0


@always_inline
def skip_spaces_and_tabs(data: Span[Byte, _], mut idx: Int):
    """Advance index past horizontal whitespace (ASCII spaces and tabs)."""
    var ptr = data.unsafe_ptr()
    var n = len(data)
    while idx < n:
        var b = ptr[unsafe_offset=idx]
        if b == Space or b == Tab:
            idx += 1
        else:
            return


@always_inline
def skip_to_newline(data: Span[Byte, _], mut idx: Int):
    """Advance index until reaching a newline byte (`\\n`) or EOF."""
    var ptr = data.unsafe_ptr()
    var n = len(data)
    comptime W = 16
    while idx + W <= n:
        var v = ptr.unsafe_load[width=W](idx)
        var mask = pack_bits(v.eq(NewLine))
        if not mask:
            idx += W
            continue
        idx += Int(count_trailing_zeros(mask))
        return
    while idx < n and ptr[unsafe_offset=idx] != NewLine:
        idx += 1


@always_inline
def skip_comment(data: Span[Byte, _], mut idx: Int) -> Bool:
    """Advance index to the end of a comment line, checking for illegal characters.
    """
    var ptr = data.unsafe_ptr()
    var n = len(data)
    comptime W = 16
    while idx + W <= n:
        var v = ptr.unsafe_load[width=W](idx)
        var stop = v.lt(0x20) | v.eq(0x7F)
        var mask = pack_bits(stop)
        if not mask:
            idx += W
            continue
        idx += Int(count_trailing_zeros(mask))
        var b = ptr[unsafe_offset=idx]
        if b == NewLine:
            return True
        if b == Enter:
            if idx + 1 < n and ptr[unsafe_offset=idx + 1] == NewLine:
                idx += 1
                return True
            return False
        if b == Tab:
            idx += 1
            continue
        return False

    var cc_ptr = _CC_TABLE.unsafe_ptr()
    while idx < n:
        var b = ptr[unsafe_offset=idx]
        if (cc_ptr[unsafe_offset=Int(b)] & CC_CTRL_NO_TAB) == 0:
            idx += 1
            continue
        if b == NewLine:
            return True
        elif b == Enter:
            if idx + 1 < n and ptr[unsafe_offset=idx + 1] == NewLine:
                idx += 1
                return True
            return False
        return False
    return True


@always_inline
def skip_whitespace_and_comments(data: Span[Byte, _], mut idx: Int):
    """Advance index through arbitrary sequences of whitespace and comments."""
    var ptr = data.unsafe_ptr()
    var n = len(data)
    while idx < n:
        var b = ptr[unsafe_offset=idx]
        if b == Space or b == Tab or b == NewLine or b == Enter:
            idx += 1
        elif b == Comment:
            skip_to_newline(data, idx)
        else:
            return


@always_inline
def scan_and_classify_scalar(
    data: Span[Byte, _], mut idx: Int
) -> Tuple[Int, Kind, UInt8]:
    """Scan an unquoted scalar, classify its `Kind`, and fast-validate common numbers in one pass.

    Returns:
        `(scalar_len, kind, prevalidated_level)` where `prevalidated_level` is:
        - `0`: requires `validate_scalar` in `Strict`/`Lexical` mode
        - `1`: lexically pre-validated (`flags = 0`)
        - `2`: lexically pre-validated and canonical plain decimal (`flags = NodeFlags.CANONICAL`).
    """
    var start = idx
    var n = len(data)
    var ptr = data.unsafe_ptr()
    var sp_ptr = _SCALAR_TABLE.unsafe_ptr()

    # Fast path for signed/unsigned decimal integers and decimal/scientific floats:
    if idx < n:
        var b0 = ptr[unsafe_offset=idx]
        var dig_start = idx
        if b0 == Byte(ord("-")) or b0 == Byte(ord("+")):
            dig_start += 1
        if dig_start < n:
            var d0 = ptr[unsafe_offset=dig_start]
            if Byte(ord("0")) <= d0 <= Byte(ord("9")):
                var p = dig_start + 1
                while p < n:
                    var c = ptr[unsafe_offset=p]
                    if Byte(ord("0")) <= c <= Byte(ord("9")):
                        p += 1
                    else:
                        break
                var int_digits = p - dig_start
                var no_leading_zero = (int_digits == 1) or (
                    d0 != Byte(ord("0"))
                )
                if p == n:
                    idx = p
                    var pv: UInt8 = 2 if (
                        no_leading_zero and int_digits <= 18
                    ) else 0
                    return (p - start, Kind.Integer, pv)
                var next_b = ptr[unsafe_offset=p]
                var next_sp = sp_ptr[unsafe_offset=Int(next_b)]
                if next_sp == 1 or (next_sp == 6 and (p - start != 10)):
                    idx = p
                    var pv: UInt8 = 2 if (
                        no_leading_zero and int_digits <= 18
                    ) else 0
                    return (p - start, Kind.Integer, pv)
                if next_b == Byte(ord("_")) and d0 != Byte(ord("0")):
                    var up = p
                    var total_digits = int_digits
                    while (
                        up + 1 < n
                        and ptr[unsafe_offset=up] == Byte(ord("_"))
                        and (
                            Byte(ord("0"))
                            <= ptr[unsafe_offset=up + 1]
                            <= Byte(ord("9"))
                        )
                    ):
                        up += 1
                        var seg_s = up
                        while up < n:
                            var uc = ptr[unsafe_offset=up]
                            if Byte(ord("0")) <= uc <= Byte(ord("9")):
                                up += 1
                            else:
                                break
                        total_digits += up - seg_s
                    if up > p:
                        if up == n:
                            idx = up
                            var pv: UInt8 = 1 if total_digits <= 18 else 0
                            return (up - start, Kind.Integer, pv)
                        var usp = sp_ptr[
                            unsafe_offset=Int(ptr[unsafe_offset=up])
                        ]
                        if usp == 1 or usp == 6:
                            idx = up
                            var pv: UInt8 = 1 if total_digits <= 18 else 0
                            return (up - start, Kind.Integer, pv)
                if next_b == Byte(ord(".")) and no_leading_zero:
                    var fp = p + 1
                    while fp < n:
                        var fc = ptr[unsafe_offset=fp]
                        if Byte(ord("0")) <= fc <= Byte(ord("9")):
                            fp += 1
                        else:
                            break
                    if fp > p + 1:
                        if fp == n:
                            idx = fp
                            return (fp - start, Kind.Float, 2)
                        var fnext = ptr[unsafe_offset=fp]
                        var end_sp = sp_ptr[unsafe_offset=Int(fnext)]
                        if end_sp == 1 or end_sp == 6:
                            idx = fp
                            return (fp - start, Kind.Float, 2)
                        if fnext == Byte(ord("e")) or fnext == Byte(ord("E")):
                            var ep = fp + 1
                            if ep < n and (
                                ptr[unsafe_offset=ep] == Byte(ord("+"))
                                or ptr[unsafe_offset=ep] == Byte(ord("-"))
                            ):
                                ep += 1
                            var exp_start = ep
                            while ep < n:
                                var ec = ptr[unsafe_offset=ep]
                                if Byte(ord("0")) <= ec <= Byte(ord("9")):
                                    ep += 1
                                else:
                                    break
                            if ep > exp_start:
                                if ep == n:
                                    idx = ep
                                    return (ep - start, Kind.Float, 1)
                                var esp = sp_ptr[
                                    unsafe_offset=Int(ptr[unsafe_offset=ep])
                                ]
                                if esp == 1 or esp == 6:
                                    idx = ep
                                    return (ep - start, Kind.Float, 1)
                elif (
                    next_b == Byte(ord("e")) or next_b == Byte(ord("E"))
                ) and no_leading_zero:
                    var ep = p + 1
                    if ep < n and (
                        ptr[unsafe_offset=ep] == Byte(ord("+"))
                        or ptr[unsafe_offset=ep] == Byte(ord("-"))
                    ):
                        ep += 1
                    var exp_start = ep
                    while ep < n:
                        var ec = ptr[unsafe_offset=ep]
                        if Byte(ord("0")) <= ec <= Byte(ord("9")):
                            ep += 1
                        else:
                            break
                    if ep > exp_start:
                        if ep == n:
                            idx = ep
                            return (ep - start, Kind.Float, 1)
                        var esp = sp_ptr[
                            unsafe_offset=Int(ptr[unsafe_offset=ep])
                        ]
                        if esp == 1 or esp == 6:
                            idx = ep
                            return (ep - start, Kind.Float, 1)
                idx = p

    var dashes = 0
    var colons = 0
    var dots = 0
    var exponent = False
    var has_other = False

    while idx < n:
        var sb = ptr[unsafe_offset=idx]
        var sp = sp_ptr[unsafe_offset=Int(sb)]
        if sp == 0:
            idx += 1
            continue
        if sp == 1:
            break
        if sp == 2:
            dots += 1
            idx += 1
            continue
        if sp == 3:
            if idx > start:
                dashes += 1
            idx += 1
            continue
        if sp == 4:
            colons += 1
            idx += 1
            continue
        if sp == 5:
            exponent = True
            idx += 1
            continue
        if sp == 6:
            if (
                (idx - start == 10)
                and idx + 1 < n
                and (
                    Byte(ord("0"))
                    <= ptr[unsafe_offset=idx + 1]
                    <= Byte(ord("9"))
                )
            ):
                idx += 1
                continue
            break
        has_other = True
        idx += 1

    var s_len = idx - start
    if s_len <= 0:
        return (0, Kind.Empty, 0)

    if not has_other:
        var first = ptr[unsafe_offset=start]
        if not (
            (Byte(ord("0")) <= first <= Byte(ord("9")))
            or first == Byte(ord("+"))
            or first == Byte(ord("-"))
        ):
            return (s_len, Kind.Empty, 0)
        if dashes >= 2:
            if colons > 0:
                return (s_len, Kind.DateTime, 0)
            if dashes == 2 and s_len == 10:
                return (s_len, Kind.Date, 0)
        if colons > 0 and dashes == 0:
            return (s_len, Kind.Time, 0)
        if dots > 0 or exponent:
            return (s_len, Kind.Float, 0)
        return (s_len, Kind.Integer, 0)

    var k = classify_scalar(data, start, idx)
    return (s_len, k, 1 if k == Kind.Boolean else 0)


def classify_scalar(data: Span[Byte, _], start: Int, end: Int) -> Kind:
    """Determine the `Kind` of an unquoted scalar literal from its bytes."""
    var n = end - start
    if n <= 0:
        return Kind.Empty
    var ptr = data.unsafe_ptr().unsafe_offset(start)

    var first = ptr[unsafe_offset=0]
    if first == Byte(ord("t")) and n == 4:
        if (
            ptr[unsafe_offset=1] == Byte(ord("r"))
            and ptr[unsafe_offset=2] == Byte(ord("u"))
            and ptr[unsafe_offset=3] == Byte(ord("e"))
        ):
            return Kind.Boolean
    elif first == Byte(ord("f")) and n == 5:
        if (
            ptr[unsafe_offset=1] == Byte(ord("a"))
            and ptr[unsafe_offset=2] == Byte(ord("l"))
            and ptr[unsafe_offset=3] == Byte(ord("s"))
            and ptr[unsafe_offset=4] == Byte(ord("e"))
        ):
            return Kind.Boolean
    elif (first == Byte(ord("n")) and n == 3) or (
        (first == Byte(ord("+")) or first == Byte(ord("-")))
        and n == 4
        and ptr[unsafe_offset=1] == Byte(ord("n"))
    ):
        return Kind.NaN
    elif (first == Byte(ord("i")) and n == 3) or (
        (first == Byte(ord("+")) or first == Byte(ord("-")))
        and n == 4
        and ptr[unsafe_offset=1] == Byte(ord("i"))
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
        and ptr[unsafe_offset=1] == Byte(ord("0"))
    ):
        var p = ptr[unsafe_offset=2]
        if (
            p == Byte(ord("x"))
            or p == Byte(ord("X"))
            or p == Byte(ord("b"))
            or p == Byte(ord("B"))
            or p == Byte(ord("o"))
            or p == Byte(ord("O"))
        ):
            return Kind.Empty

    if first == Byte(ord("0")) and n > 1:
        var p = ptr[unsafe_offset=1]
        if p == Byte(ord("X")) or p == Byte(ord("B")) or p == Byte(ord("O")):
            return Kind.Empty

    var is_hex = (
        n > 2
        and first == Byte(ord("0"))
        and ptr[unsafe_offset=1] == Byte(ord("x"))
    )
    var is_bin = (
        n > 2
        and first == Byte(ord("0"))
        and ptr[unsafe_offset=1] == Byte(ord("b"))
    )
    var is_oct = (
        n > 2
        and first == Byte(ord("0"))
        and ptr[unsafe_offset=1] == Byte(ord("o"))
    )
    if is_hex or is_bin or is_oct:
        return Kind.Integer

    var dashes = 0
    var colons = 0
    var dots = 0
    var exponent = False

    for i in range(n):
        var b = ptr[unsafe_offset=i]
        if b < 0x20 or b == 0x7F:
            return Kind.Empty
        if b == Byte(ord("-")):
            if i > 0:
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
