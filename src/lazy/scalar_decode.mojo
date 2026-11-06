"""Non-allocating and lazy decoders for scalar TOML values.
"""

from ..result import Result, ScalarResult
from .node import Kind, NodeFlags
from ..types.tempo import Date, Time, DateTime, Offset
from std.collections import Span
from std.math import nan
from std.memory import pack_bits
from std.bit import count_trailing_zeros


@always_inline
def _pow10(e: Int) -> Float64:
    """Compute exact `10.0 ** e` in IEEE-754 `Float64` for `0 <= e <= 22`."""
    var r: Float64 = 1.0
    if (e & 1) != 0:
        r *= 1e1
    if (e & 2) != 0:
        r *= 1e2
    if (e & 4) != 0:
        r *= 1e4
    if (e & 8) != 0:
        r *= 1e8
    if (e & 16) != 0:
        r *= 1e16
    return r


@always_inline
def check_escape_at[
    is_multiline: Bool
](ptr: Pointer[Byte, _], end: Int, mut idx: Int) -> Bool:
    """Validate an escape sequence starting at `ptr[idx]` (the byte after `\\`).

    Advances `idx` to the last byte of the escape sequence so the caller's
    `idx += 1` lands on the first byte following the escape.
    """
    if idx >= end:
        return False
    var esc = ptr[unsafe_offset=idx]
    if (
        esc == Byte(ord("b"))
        or esc == Byte(ord("t"))
        or esc == Byte(ord("n"))
        or esc == Byte(ord("f"))
        or esc == Byte(ord("r"))
        or esc == Byte(ord("e"))
        or esc == Byte(ord('"'))
        or esc == Byte(ord("\\"))
    ):
        return True
    if esc == Byte(ord("x")):
        if idx + 2 >= end:
            return False
        for j in range(idx + 1, idx + 3):
            var hb = ptr[unsafe_offset=j]
            if not (
                (Byte(ord("0")) <= hb <= Byte(ord("9")))
                or (Byte(ord("a")) <= hb <= Byte(ord("f")))
                or (Byte(ord("A")) <= hb <= Byte(ord("F")))
            ):
                return False
        idx += 2
        return True
    if esc == Byte(ord("u")) or esc == Byte(ord("U")):
        var hex_len = 4 if esc == Byte(ord("u")) else 8
        if idx + hex_len >= end:
            return False
        var cp: UInt32 = 0
        for j in range(idx + 1, idx + 1 + hex_len):
            var hb = ptr[unsafe_offset=j]
            var d: UInt32
            if Byte(ord("0")) <= hb <= Byte(ord("9")):
                d = UInt32(hb - Byte(ord("0")))
            elif Byte(ord("a")) <= hb <= Byte(ord("f")):
                d = 10 + UInt32(hb - Byte(ord("a")))
            elif Byte(ord("A")) <= hb <= Byte(ord("F")):
                d = 10 + UInt32(hb - Byte(ord("A")))
            else:
                return False
            cp = (cp << 4) | d
        if (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
            return False
        idx += hex_len
        return True
    comptime if is_multiline:
        if (
            esc == Byte(ord(" "))
            or esc == Byte(ord("\t"))
            or esc == Byte(ord("\n"))
            or esc == Byte(ord("\r"))
        ):
            var p = idx
            while p < end and (
                ptr[unsafe_offset=p] == Byte(ord(" "))
                or ptr[unsafe_offset=p] == Byte(ord("\t"))
            ):
                p += 1
            if p >= end:
                return False
            var nb = ptr[unsafe_offset=p]
            if nb == Byte(ord("\n")):
                idx = p
                return True
            if nb == Byte(ord("\r")):
                if p + 1 < end and ptr[unsafe_offset=p + 1] == Byte(ord("\n")):
                    idx = p + 1
                    return True
            return False
    return False


@always_inline
def validate_float(bytes: Span[Byte, _]) -> Bool:
    """Validate float literal syntax and lexical rules without calling `atof`.
    """
    var n = len(bytes)
    if n == 0:
        return False

    var ptr = bytes.unsafe_ptr()
    var s = StringSpan(unsafe_from_utf8=bytes)
    if (
        s == "nan"
        or s == "+nan"
        or s == "-nan"
        or s == "inf"
        or s == "+inf"
        or s == "-inf"
    ):
        return True

    var int_start = 0
    if ptr[unsafe_offset=0] == Byte(ord("-")) or ptr[unsafe_offset=0] == Byte(
        ord("+")
    ):
        int_start = 1
    if int_start >= n:
        return False

    var dot_pos = -1
    var exp_pos = -1

    for i in range(int_start, n):
        var b = ptr[unsafe_offset=i]
        if Byte(ord("0")) <= b <= Byte(ord("9")):
            continue
        elif b == Byte(ord(".")):
            if dot_pos >= 0 or exp_pos >= 0:
                return False
            dot_pos = i
        elif b == Byte(ord("e")) or b == Byte(ord("E")):
            if exp_pos >= 0:
                return False
            exp_pos = i
        elif b == Byte(ord("+")) or b == Byte(ord("-")):
            if i != exp_pos + 1:
                return False
        elif b == Byte(ord("_")):
            if i == int_start or i + 1 >= n:
                return False
            var prev_b = ptr[unsafe_offset=i - 1]
            var next_b = ptr[unsafe_offset=i + 1]
            if not (Byte(ord("0")) <= prev_b <= Byte(ord("9"))) or not (
                Byte(ord("0")) <= next_b <= Byte(ord("9"))
            ):
                return False
        else:
            return False

    var int_end = dot_pos if dot_pos >= 0 else (exp_pos if exp_pos >= 0 else n)
    if int_end <= int_start:
        return False
    if int_end > int_start + 1 and ptr[unsafe_offset=int_start] == Byte(
        ord("0")
    ):
        return False

    if dot_pos >= 0:
        if dot_pos == 0 or dot_pos == n - 1:
            return False
        var prev_b = ptr[unsafe_offset=dot_pos - 1]
        var next_b = ptr[unsafe_offset=dot_pos + 1]
        if not (Byte(ord("0")) <= prev_b <= Byte(ord("9"))) or not (
            Byte(ord("0")) <= next_b <= Byte(ord("9"))
        ):
            return False

    if exp_pos >= 0:
        var exp_digits_start = exp_pos + 1
        if exp_digits_start < n and (
            ptr[unsafe_offset=exp_digits_start] == Byte(ord("+"))
            or ptr[unsafe_offset=exp_digits_start] == Byte(ord("-"))
        ):
            exp_digits_start += 1
        if exp_digits_start >= n or not (
            Byte(ord("0"))
            <= ptr[unsafe_offset=exp_digits_start]
            <= Byte(ord("9"))
        ):
            return False
        if exp_pos == int_start:
            return False

    return True


@always_inline
def validate_date(bytes: Span[Byte, _]) -> Bool:
    """Validate an RFC 3339 local date (`YYYY-MM-DD`) without constructing `Result`.
    """
    if len(bytes) != 10:
        return False
    var ptr = bytes.unsafe_ptr()
    if ptr[unsafe_offset=4] != Byte(ord("-")) or ptr[unsafe_offset=7] != Byte(
        ord("-")
    ):
        return False
    var year = _parse_4digits(ptr, 0)
    var month = _parse_2digits(ptr, 5)
    var day = _parse_2digits(ptr, 8)
    if year < 0 or month < 1 or month > 12 or day < 1:
        return False

    var days_in_month = 31
    if month == 4 or month == 6 or month == 9 or month == 11:
        days_in_month = 30
    elif month == 2:
        var leap = (year % 4 == 0) and (year % 100 != 0 or year % 400 == 0)
        days_in_month = 29 if leap else 28
    return day <= days_in_month


@always_inline
def validate_time(bytes: Span[Byte, _]) -> Bool:
    """Validate an RFC 3339 local time (`HH:MM[:SS[.fraction]]`) without constructing `Result`.
    """
    var n = len(bytes)
    if n != 5 and n < 8:
        return False
    var ptr = bytes.unsafe_ptr()
    if ptr[unsafe_offset=2] != Byte(ord(":")):
        return False
    var hour = _parse_2digits(ptr, 0)
    var minute = _parse_2digits(ptr, 3)
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        return False
    if n == 5:
        return True
    if ptr[unsafe_offset=5] != Byte(ord(":")):
        return False
    var sec_int = _parse_2digits(ptr, 6)
    if sec_int < 0 or sec_int > 60:
        return False
    if n == 8:
        return True
    if ptr[unsafe_offset=8] != Byte(ord(".")) or n == 9:
        return False
    for i in range(9, n):
        var b = ptr[unsafe_offset=i]
        if not (Byte(ord("0")) <= b <= Byte(ord("9"))):
            return False
        if sec_int == 60 and b > Byte(ord("0")):
            return False
    return True


@always_inline
def validate_datetime(bytes: Span[Byte, _]) -> Bool:
    """Validate an RFC 3339 date-time without constructing `Result`."""
    var n = len(bytes)
    if n < 16:
        return False
    var ptr = bytes.unsafe_ptr()
    var sep = ptr[unsafe_offset=10]
    if (
        sep != Byte(ord("T"))
        and sep != Byte(ord("t"))
        and sep != Byte(ord(" "))
    ):
        return False
    if not validate_date(bytes[:10]):
        return False

    var last = ptr[unsafe_offset=n - 1]
    if last == Byte(ord("Z")) or last == Byte(ord("z")):
        return validate_time(bytes[11 : n - 1])

    var t_split = n
    for i in range(16, n):
        var b = ptr[unsafe_offset=i]
        if b == Byte(ord("+")) or b == Byte(ord("-")):
            t_split = i
            break
        elif b == Byte(ord("Z")) or b == Byte(ord("z")):
            return False

    if t_split == n:
        return validate_time(bytes[11:n])

    if n - t_split != 6 or ptr[unsafe_offset=t_split + 3] != Byte(ord(":")):
        return False
    var off_h = _parse_2digits(ptr, t_split + 1)
    var off_m = _parse_2digits(ptr, t_split + 4)
    if off_h < 0 or off_h > 23 or off_m < 0 or off_m > 59:
        return False
    return validate_time(bytes[11:t_split])


@always_inline
def validate_bool(bytes: Span[Byte, _]) -> Bool:
    """Validate a boolean scalar without constructing `Result`."""
    var n = len(bytes)
    if n == 4:
        var ptr = bytes.unsafe_ptr()
        return (
            ptr[unsafe_offset=0] == Byte(ord("t"))
            and ptr[unsafe_offset=1] == Byte(ord("r"))
            and ptr[unsafe_offset=2] == Byte(ord("u"))
            and ptr[unsafe_offset=3] == Byte(ord("e"))
        )
    elif n == 5:
        var ptr = bytes.unsafe_ptr()
        return (
            ptr[unsafe_offset=0] == Byte(ord("f"))
            and ptr[unsafe_offset=1] == Byte(ord("a"))
            and ptr[unsafe_offset=2] == Byte(ord("l"))
            and ptr[unsafe_offset=3] == Byte(ord("s"))
            and ptr[unsafe_offset=4] == Byte(ord("e"))
        )
    return False


@always_inline
def validate_int(bytes: Span[Byte, _]) -> Bool:
    """Validate a 64-bit signed integer literal without constructing `Result`.
    """
    return decode_int(bytes)._ok


@always_inline
def validate_scalar(kind: Kind, bytes: Span[Byte, _]) -> Bool:
    """Validate an unquoted scalar according to its classified `Kind` without heap allocations.
    """
    if kind == Kind.Integer:
        return validate_int(bytes)
    if kind == Kind.Float:
        return validate_float(bytes)
    if kind == Kind.Boolean:
        return validate_bool(bytes)
    if kind == Kind.Date:
        return validate_date(bytes)
    if kind == Kind.Time:
        return validate_time(bytes)
    if kind == Kind.DateTime:
        return validate_datetime(bytes)
    if kind == Kind.NaN or kind == Kind.Inf:
        return validate_float(bytes)
    return False


@always_inline
def decode_bool_unchecked(bytes: Span[Byte, _]) -> Bool:
    """Fast unchecked boolean decode for scalars already validated at parse time.
    """
    return bytes.unsafe_ptr()[unsafe_offset=0] == Byte(ord("t"))


@always_inline
def decode_bool(bytes: Span[Byte, _]) -> ScalarResult[Bool]:
    """Decode a boolean scalar from its raw byte representation."""
    var n = len(bytes)
    if n == 4:
        var ptr = bytes.unsafe_ptr()
        if (
            ptr[unsafe_offset=0] == Byte(ord("t"))
            and ptr[unsafe_offset=1] == Byte(ord("r"))
            and ptr[unsafe_offset=2] == Byte(ord("u"))
            and ptr[unsafe_offset=3] == Byte(ord("e"))
        ):
            return ScalarResult[Bool](True, True)
    elif n == 5:
        var ptr = bytes.unsafe_ptr()
        if (
            ptr[unsafe_offset=0] == Byte(ord("f"))
            and ptr[unsafe_offset=1] == Byte(ord("a"))
            and ptr[unsafe_offset=2] == Byte(ord("l"))
            and ptr[unsafe_offset=3] == Byte(ord("s"))
            and ptr[unsafe_offset=4] == Byte(ord("e"))
        ):
            return ScalarResult[Bool](False, True)
    return ScalarResult[Bool](False, False)


@always_inline
def decode_int_unchecked(bytes: Span[Byte, _], flags: UInt8 = 0) -> Int:
    """Fast unchecked integer decode for scalars already validated at parse time.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var first = ptr[unsafe_offset=0]

    if (flags & NodeFlags.CANONICAL) != 0:
        var is_neg = first == Byte(ord("-"))
        var start = Int(is_neg or first == Byte(ord("+")))
        var acc: UInt64 = 0
        for i in range(start, n):
            acc = acc * 10 + UInt64(ptr[unsafe_offset=i] - Byte(ord("0")))
        return -Int(acc) if is_neg else Int(acc)

    var start = 0
    var is_neg = False
    if first == Byte(ord("-")):
        is_neg = True
        start = 1
    elif first == Byte(ord("+")):
        start = 1

    if n - start > 2 and ptr[unsafe_offset=start] == Byte(ord("0")):
        var prefix = ptr[unsafe_offset=start + 1]
        var base: UInt64 = UInt64(16) if prefix == Byte(ord("x")) else (
            UInt64(8) if prefix == Byte(ord("o")) else UInt64(2)
        )
        var acc: UInt64 = 0
        for i in range(start + 2, n):
            var b = ptr[unsafe_offset=i]
            if b == Byte(ord("_")):
                continue
            var d: UInt64
            if Byte(ord("0")) <= b <= Byte(ord("9")):
                d = UInt64(b - Byte(ord("0")))
            elif Byte(ord("a")) <= b <= Byte(ord("f")):
                d = 10 + UInt64(b - Byte(ord("a")))
            else:
                d = 10 + UInt64(b - Byte(ord("A")))
            acc = acc * base + d
        return Int(acc)

    var acc: UInt64 = 0
    for i in range(start, n):
        var b = ptr[unsafe_offset=i]
        if b != Byte(ord("_")):
            acc = acc * 10 + UInt64(b - Byte(ord("0")))
    if is_neg:
        if acc == UInt64(0x8000000000000000):
            return Int(-9223372036854775807 - 1)
        return -Int(acc)
    return Int(acc)


def _atof_fallback(bytes: Span[Byte, _], has_underscore: Bool) -> Float64:
    """Cold fallback to `atof` for >15-digit or extreme-exponent floats."""
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var s = StringSpan(unsafe_from_utf8=bytes)
    if s == "nan" or s == "+nan" or s == "-nan":
        return nan[DType.float64]()
    if s == "inf" or s == "+inf":
        return Float64.MAX
    if s == "-inf":
        return Float64.MIN
    try:
        if not has_underscore:
            return atof(s)
        var clean = String(capacity_bytes=n)
        var seg_start = 0
        for i in range(n):
            if ptr[unsafe_offset=i] == Byte(ord("_")):
                if i > seg_start:
                    clean.write(StringSpan(unsafe_from_utf8=bytes[seg_start:i]))
                seg_start = i + 1
        if seg_start < n:
            clean.write(StringSpan(unsafe_from_utf8=bytes[seg_start:n]))
        return atof(clean)
    except:
        return 0.0


@always_inline
def decode_float_unchecked(bytes: Span[Byte, _], flags: UInt8 = 0) -> Float64:
    """Fast IEEE-754 exact float decode for scalars already validated at parse time.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var first = ptr[unsafe_offset=0]

    # Clinger's fast path for canonical [+-]?[0-9]+\.[0-9]+ up to 15 significant digits
    if (flags & NodeFlags.CANONICAL) != 0:
        var is_neg = first == Byte(ord("-"))
        var start = Int(is_neg or first == Byte(ord("+")))
        if n - start <= 16:
            var acc: UInt64 = 0
            var frac_len = 0
            var seen_dot = False
            for i in range(start, n):
                var b = ptr[unsafe_offset=i]
                if b == Byte(ord(".")):
                    seen_dot = True
                else:
                    acc = acc * 10 + UInt64(b - Byte(ord("0")))
                    if seen_dot:
                        frac_len += 1
            var val = Float64(acc) / _pow10(frac_len)
            return -val if is_neg else val

    if (
        first == Byte(ord("n"))
        or first == Byte(ord("i"))
        or (
            n >= 3
            and (first == Byte(ord("+")) or first == Byte(ord("-")))
            and (
                ptr[unsafe_offset=1] == Byte(ord("n"))
                or ptr[unsafe_offset=1] == Byte(ord("i"))
            )
        )
    ):
        return _atof_fallback(bytes, False)

    # General Clinger fast path for scientific / underscored floats with <= 15 digits & |exp| <= 22
    var is_neg = first == Byte(ord("-"))
    var start = Int(is_neg or first == Byte(ord("+")))
    var acc: UInt64 = 0
    var sig_digits = 0
    var frac_digits = 0
    var seen_dot = False
    var exp_pos = -1
    var has_underscore = False

    for i in range(start, n):
        var b = ptr[unsafe_offset=i]
        if Byte(ord("0")) <= b <= Byte(ord("9")):
            var d = UInt64(b - Byte(ord("0")))
            if acc != 0 or d != 0:
                sig_digits += 1
                if sig_digits <= 15:
                    acc = acc * 10 + d
            if seen_dot:
                frac_digits += 1
        elif b == Byte(ord(".")):
            seen_dot = True
        elif b == Byte(ord("e")) or b == Byte(ord("E")):
            exp_pos = i
            break
        elif b == Byte(ord("_")):
            has_underscore = True

    if sig_digits <= 15:
        var exp_val = 0
        var exp_ok = True
        if exp_pos >= 0:
            var ep = exp_pos + 1
            var exp_neg = False
            if ep < n:
                if ptr[unsafe_offset=ep] == Byte(ord("-")):
                    exp_neg = True
                    ep += 1
                elif ptr[unsafe_offset=ep] == Byte(ord("+")):
                    ep += 1
            for i in range(ep, n):
                var eb = ptr[unsafe_offset=i]
                if eb == Byte(ord("_")):
                    has_underscore = True
                    continue
                exp_val = exp_val * 10 + Int(eb - Byte(ord("0")))
                if exp_val > 100:
                    exp_ok = False
                    break
            if exp_neg:
                exp_val = -exp_val
        if exp_ok:
            var eff_exp = exp_val - frac_digits
            if acc == 0:
                return -0.0 if is_neg else 0.0
            if 0 <= eff_exp <= 22:
                var val = Float64(acc) * _pow10(eff_exp)
                return -val if is_neg else val
            elif -22 <= eff_exp < 0:
                var val = Float64(acc) / _pow10(-eff_exp)
                return -val if is_neg else val

    return _atof_fallback(bytes, has_underscore)


def decode_int(bytes: Span[Byte, _]) -> ScalarResult[Int]:
    """Decode a 64-bit signed integer from its raw byte representation."""
    var n = len(bytes)
    if n == 0:
        return ScalarResult[Int](0, False)

    var ptr = bytes.unsafe_ptr()
    var start = 0
    var is_neg = False
    var first = ptr[unsafe_offset=0]
    if first == Byte(ord("-")):
        is_neg = True
        start = 1
    elif first == Byte(ord("+")):
        start = 1

    if start >= n:
        return ScalarResult[Int](0, False)

    var has_sign = start > 0
    var base: UInt64 = 10
    if n - start > 1 and ptr[unsafe_offset=start] == Byte(ord("0")):
        var prefix = ptr[unsafe_offset=start + 1]
        if (
            prefix == Byte(ord("x"))
            or prefix == Byte(ord("o"))
            or prefix == Byte(ord("b"))
        ):
            if has_sign:
                return ScalarResult[Int](0, False)
            if prefix == Byte(ord("x")):
                base = 16
            elif prefix == Byte(ord("o")):
                base = 8
            else:
                base = 2
            start += 2
            if start >= n:
                return ScalarResult[Int](0, False)
        else:
            return ScalarResult[Int](0, False)

    var limit: UInt64 = UInt64(0x8000000000000000) if is_neg else UInt64(
        0x7FFFFFFFFFFFFFFF
    )
    var cutoff: UInt64 = limit // base
    var cutlim: UInt64 = limit % base

    var acc: UInt64 = 0
    if base == 10:
        for i in range(start, n):
            var b = ptr[unsafe_offset=i]
            if b == Byte(ord("_")):
                if i == start or i + 1 >= n:
                    return ScalarResult[Int](0, False)
                var prev_b = ptr[unsafe_offset=i - 1]
                var next_b = ptr[unsafe_offset=i + 1]
                if not (Byte(ord("0")) <= prev_b <= Byte(ord("9"))) or not (
                    Byte(ord("0")) <= next_b <= Byte(ord("9"))
                ):
                    return ScalarResult[Int](0, False)
                continue
            if not (Byte(ord("0")) <= b <= Byte(ord("9"))):
                return ScalarResult[Int](0, False)
            var d = UInt64(b - Byte(ord("0")))
            if acc > cutoff or (acc == cutoff and d > cutlim):
                return ScalarResult[Int](0, False)
            acc = acc * 10 + d
    else:
        for i in range(start, n):
            var b = ptr[unsafe_offset=i]
            if b == Byte(ord("_")):
                if i == start or i + 1 >= n:
                    return ScalarResult[Int](0, False)
                var prev_b = ptr[unsafe_offset=i - 1]
                var next_b = ptr[unsafe_offset=i + 1]
                var prev_valid = (
                    Byte(ord("0")) <= prev_b <= Byte(ord("9"))
                ) or (
                    base == 16
                    and (
                        (Byte(ord("a")) <= prev_b <= Byte(ord("f")))
                        or (Byte(ord("A")) <= prev_b <= Byte(ord("F")))
                    )
                )
                var next_valid = (
                    Byte(ord("0")) <= next_b <= Byte(ord("9"))
                ) or (
                    base == 16
                    and (
                        (Byte(ord("a")) <= next_b <= Byte(ord("f")))
                        or (Byte(ord("A")) <= next_b <= Byte(ord("F")))
                    )
                )
                if not prev_valid or not next_valid:
                    return ScalarResult[Int](0, False)
                continue
            var d: UInt64
            if Byte(ord("0")) <= b <= Byte(ord("9")):
                d = UInt64(b - Byte(ord("0")))
            elif Byte(ord("a")) <= b <= Byte(ord("f")):
                d = 10 + UInt64(b - Byte(ord("a")))
            elif Byte(ord("A")) <= b <= Byte(ord("F")):
                d = 10 + UInt64(b - Byte(ord("A")))
            else:
                return ScalarResult[Int](0, False)
            if d >= base:
                return ScalarResult[Int](0, False)
            if acc > cutoff or (acc == cutoff and d > cutlim):
                return ScalarResult[Int](0, False)
            acc = acc * base + d

    if is_neg:
        if acc == UInt64(0x8000000000000000):
            return ScalarResult[Int](Int(-9223372036854775807 - 1), True)
        return ScalarResult[Int](-Int(acc), True)
    return ScalarResult[Int](Int(acc), True)


def decode_float(bytes: Span[Byte, _]) -> ScalarResult[Float64]:
    """Decode a 64-bit floating point number from its raw byte representation.
    """
    if not validate_float(bytes):
        return ScalarResult[Float64](0.0, False)
    return ScalarResult[Float64](decode_float_unchecked(bytes, 0), True)


@always_inline
def _u2digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    return Int(ptr[unsafe_offset=offset] - Byte(ord("0"))) * 10 + Int(
        ptr[unsafe_offset=offset + 1] - Byte(ord("0"))
    )


@always_inline
def _u4digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    return (
        Int(ptr[unsafe_offset=offset] - Byte(ord("0"))) * 1000
        + Int(ptr[unsafe_offset=offset + 1] - Byte(ord("0"))) * 100
        + Int(ptr[unsafe_offset=offset + 2] - Byte(ord("0"))) * 10
        + Int(ptr[unsafe_offset=offset + 3] - Byte(ord("0")))
    )


@always_inline
def _parse_2digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    var b0 = ptr[unsafe_offset=offset]
    var b1 = ptr[unsafe_offset=offset + 1]
    if not (Byte(ord("0")) <= b0 <= Byte(ord("9"))) or not (
        Byte(ord("0")) <= b1 <= Byte(ord("9"))
    ):
        return -1
    return Int(b0 - Byte(ord("0"))) * 10 + Int(b1 - Byte(ord("0")))


@always_inline
def _parse_4digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    var b0 = ptr[unsafe_offset=offset]
    var b1 = ptr[unsafe_offset=offset + 1]
    var b2 = ptr[unsafe_offset=offset + 2]
    var b3 = ptr[unsafe_offset=offset + 3]
    if (
        not (Byte(ord("0")) <= b0 <= Byte(ord("9")))
        or not (Byte(ord("0")) <= b1 <= Byte(ord("9")))
        or not (Byte(ord("0")) <= b2 <= Byte(ord("9")))
        or not (Byte(ord("0")) <= b3 <= Byte(ord("9")))
    ):
        return -1
    return (
        Int(b0 - Byte(ord("0"))) * 1000
        + Int(b1 - Byte(ord("0"))) * 100
        + Int(b2 - Byte(ord("0"))) * 10
        + Int(b3 - Byte(ord("0")))
    )


@always_inline
def decode_date_unchecked(bytes: Span[Byte, _]) -> Date:
    """Fast unchecked local date decode for scalars already validated at parse time.
    """
    var ptr = bytes.unsafe_ptr()
    return Date(
        year=_u4digits(ptr, 0),
        month=_u2digits(ptr, 5),
        day=_u2digits(ptr, 8),
    )


@always_inline
def decode_date(bytes: Span[Byte, _]) -> ScalarResult[Date]:
    """Decode an RFC 3339 local date (`YYYY-MM-DD`) using direct digit arithmetic.
    """
    if not validate_date(bytes):
        return ScalarResult[Date](Date(year=0, month=0, day=0), False)
    return ScalarResult[Date](decode_date_unchecked(bytes), True)


@always_inline
def decode_time_unchecked(bytes: Span[Byte, _]) -> Time:
    """Fast unchecked local time decode for scalars already validated at parse time.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var hour = _u2digits(ptr, 0)
    var minute = _u2digits(ptr, 3)
    if n == 5:
        return Time(hour=hour, minute=minute, second=0.0)
    var sec_int = _u2digits(ptr, 6)
    if n == 8:
        return Time(hour=hour, minute=minute, second=Float64(sec_int))
    var frac: Float64 = 0.0
    var scale: Float64 = 0.1
    for i in range(9, n):
        frac += Float64(Int(ptr[unsafe_offset=i] - Byte(ord("0")))) * scale
        scale *= 0.1
    return Time(hour=hour, minute=minute, second=Float64(sec_int) + frac)


@always_inline
def decode_time(bytes: Span[Byte, _]) -> ScalarResult[Time]:
    """Decode an RFC 3339 local time (`HH:MM[:SS[.fraction]]`) using direct arithmetic.
    """
    if not validate_time(bytes):
        return ScalarResult[Time](Time(hour=0, minute=0, second=0.0), False)
    return ScalarResult[Time](decode_time_unchecked(bytes), True)


@always_inline
def decode_datetime_unchecked(bytes: Span[Byte, _]) -> DateTime:
    """Fast unchecked datetime decode for scalars already validated at parse time.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var date = decode_date_unchecked(bytes[:10])
    var last = ptr[unsafe_offset=n - 1]
    if last == Byte(ord("Z")) or last == Byte(ord("z")):
        return DateTime(
            date, decode_time_unchecked(bytes[11 : n - 1]), Offset.utc, False
        )
    var t_split = n
    for i in range(16, n):
        var b = ptr[unsafe_offset=i]
        if b == Byte(ord("+")) or b == Byte(ord("-")):
            t_split = i
            break
    if t_split == n:
        return DateTime(
            date, decode_time_unchecked(bytes[11:n]), Offset.utc, True
        )
    var off_pos = ptr[unsafe_offset=t_split] == Byte(ord("+"))
    var off_h = _u2digits(ptr, t_split + 1)
    var off_m = _u2digits(ptr, t_split + 4)
    return DateTime(
        date,
        decode_time_unchecked(bytes[11:t_split]),
        Offset(hour=off_h, minute=off_m, positive=off_pos),
        False,
    )


def decode_datetime(bytes: Span[Byte, _]) -> ScalarResult[DateTime]:
    """Decode an RFC 3339 date-time with optional offset or local time."""
    if not validate_datetime(bytes):
        return ScalarResult[DateTime](
            DateTime(
                Date(year=0, month=0, day=0),
                Time(hour=0, minute=0, second=0.0),
                Offset.utc,
                True,
            ),
            False,
        )
    return ScalarResult[DateTime](decode_datetime_unchecked(bytes), True)


def decode_string_to_writer_unchecked[
    W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut writer: W):
    """Unescape a pre-validated string literal directly into `writer` without `Result`.
    """
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        writer.write(StringSpan(unsafe_from_utf8=bytes))
        return

    var is_multiline = (flags & NodeFlags.MULTILINE) != 0
    var i = 0
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    comptime W_SIMD = 16

    while i < n:
        var chunk_start = i
        while i + W_SIMD <= n:
            var v = ptr.unsafe_load[width=W_SIMD](i)
            var mask = pack_bits(v.eq(Byte(ord("\\"))))
            if not mask:
                i += W_SIMD
                continue
            i += Int(count_trailing_zeros(mask))
            break
        while i < n and ptr[unsafe_offset=i] != Byte(ord("\\")):
            i += 1
        if i > chunk_start:
            writer.write(StringSpan(unsafe_from_utf8=bytes[chunk_start:i]))
        if i >= n:
            break

        i += 1
        var esc = ptr[unsafe_offset=i]
        if esc == Byte(ord("b")):
            writer.write("\b")
            i += 1
        elif esc == Byte(ord("t")):
            writer.write("\t")
            i += 1
        elif esc == Byte(ord("n")):
            writer.write("\n")
            i += 1
        elif esc == Byte(ord("f")):
            writer.write("\x0c")
            i += 1
        elif esc == Byte(ord("r")):
            writer.write("\r")
            i += 1
        elif esc == Byte(ord("e")):
            writer.write("\x1b")
            i += 1
        elif esc == Byte(ord("0")):
            writer.write("\0")
            i += 1
        elif esc == Byte(ord('"')):
            writer.write('"')
            i += 1
        elif esc == Byte(ord("\\")):
            writer.write("\\")
            i += 1
        elif esc == Byte(ord("x")):
            var cp: UInt32 = 0
            for j in range(i + 1, i + 3):
                var hb = ptr[unsafe_offset=j]
                var d: UInt32
                if Byte(ord("0")) <= hb <= Byte(ord("9")):
                    d = UInt32(hb - Byte(ord("0")))
                elif Byte(ord("a")) <= hb <= Byte(ord("f")):
                    d = 10 + UInt32(hb - Byte(ord("a")))
                else:
                    d = 10 + UInt32(hb - Byte(ord("A")))
                cp = (cp << 4) | d
            i += 3
            writer.write(Codepoint(unsafe_unchecked_codepoint=cp))
        elif esc == Byte(ord("u")) or esc == Byte(ord("U")):
            var hex_len = 4 if esc == Byte(ord("u")) else 8
            var cp: UInt32 = 0
            for j in range(i + 1, i + 1 + hex_len):
                var hb = ptr[unsafe_offset=j]
                var d: UInt32
                if Byte(ord("0")) <= hb <= Byte(ord("9")):
                    d = UInt32(hb - Byte(ord("0")))
                elif Byte(ord("a")) <= hb <= Byte(ord("f")):
                    d = 10 + UInt32(hb - Byte(ord("a")))
                else:
                    d = 10 + UInt32(hb - Byte(ord("A")))
                cp = (cp << 4) | d
            i += 1 + hex_len
            writer.write(Codepoint(unsafe_unchecked_codepoint=cp))
        elif is_multiline:
            while i < n:
                var wb = ptr[unsafe_offset=i]
                if (
                    wb == Byte(ord(" "))
                    or wb == Byte(ord("\t"))
                    or wb == Byte(ord("\r"))
                    or wb == Byte(ord("\n"))
                ):
                    i += 1
                else:
                    break


@always_inline
def decode_string_unchecked(bytes: Span[Byte, _], flags: UInt8) -> String:
    """Decode and unescape a pre-validated string literal into an owned `String`.
    """
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        return String(StringSpan(unsafe_from_utf8=bytes))
    var s = String(capacity_bytes=len(bytes))
    decode_string_to_writer_unchecked(bytes, flags, s)
    return s^


def decode_string_to_writer[
    W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut writer: W) -> Result[NoneType]:
    """Decode and unescape a string literal directly into any `Writer`."""
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        writer.write(StringSpan(unsafe_from_utf8=bytes))
        return .Ok(None)

    var is_multiline = (flags & NodeFlags.MULTILINE) != 0
    var i = 0
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    comptime W_SIMD = 16

    while i < n:
        var chunk_start = i
        while i + W_SIMD <= n:
            var v = ptr.unsafe_load[width=W_SIMD](i)
            var mask = pack_bits(v.eq(Byte(ord("\\"))))
            if not mask:
                i += W_SIMD
                continue
            i += Int(count_trailing_zeros(mask))
            break
        while i < n and ptr[unsafe_offset=i] != Byte(ord("\\")):
            i += 1
        if i > chunk_start:
            writer.write(StringSpan(unsafe_from_utf8=bytes[chunk_start:i]))
        if i >= n:
            break

        i += 1
        if i >= n:
            return .Err("Incomplete escape sequence.")

        var esc = ptr[unsafe_offset=i]
        if esc == Byte(ord("b")):
            writer.write("\b")
            i += 1
        elif esc == Byte(ord("t")):
            writer.write("\t")
            i += 1
        elif esc == Byte(ord("n")):
            writer.write("\n")
            i += 1
        elif esc == Byte(ord("f")):
            writer.write("\x0c")
            i += 1
        elif esc == Byte(ord("r")):
            writer.write("\r")
            i += 1
        elif esc == Byte(ord("e")):
            writer.write("\x1b")
            i += 1
        elif esc == Byte(ord("0")):
            writer.write("\0")
            i += 1
        elif esc == Byte(ord('"')):
            writer.write('"')
            i += 1
        elif esc == Byte(ord("\\")):
            writer.write("\\")
            i += 1
        elif esc == Byte(ord("x")):
            if i + 2 >= n:
                return .Err("Hex escape has too few digits.")
            var cp: UInt32 = 0
            for j in range(i + 1, i + 3):
                var hb = ptr[unsafe_offset=j]
                var d: UInt32
                if Byte(ord("0")) <= hb <= Byte(ord("9")):
                    d = UInt32(hb - Byte(ord("0")))
                elif Byte(ord("a")) <= hb <= Byte(ord("f")):
                    d = 10 + UInt32(hb - Byte(ord("a")))
                elif Byte(ord("A")) <= hb <= Byte(ord("F")):
                    d = 10 + UInt32(hb - Byte(ord("A")))
                else:
                    return .Err("Invalid hex digit in hex escape.")
                cp = (cp << 4) | d
            i += 3
            writer.write(Codepoint(unsafe_unchecked_codepoint=cp))
        elif esc == Byte(ord("u")) or esc == Byte(ord("U")):
            var hex_len = 4 if esc == Byte(ord("u")) else 8
            if i + hex_len >= n:
                return .Err("Unicode escape has too few hex digits.")
            var cp: UInt32 = 0
            for j in range(i + 1, i + 1 + hex_len):
                var hb = ptr[unsafe_offset=j]
                var d: UInt32
                if Byte(ord("0")) <= hb <= Byte(ord("9")):
                    d = UInt32(hb - Byte(ord("0")))
                elif Byte(ord("a")) <= hb <= Byte(ord("f")):
                    d = 10 + UInt32(hb - Byte(ord("a")))
                elif Byte(ord("A")) <= hb <= Byte(ord("F")):
                    d = 10 + UInt32(hb - Byte(ord("A")))
                else:
                    return .Err("Invalid hex digit in unicode escape.")
                cp = (cp << 4) | d
            i += 1 + hex_len
            if (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
                return .Err(
                    "Unicode escape is not a valid Unicode scalar value."
                )
            writer.write(Codepoint(unsafe_unchecked_codepoint=cp))
        elif is_multiline and (
            esc == Byte(ord("\n"))
            or esc == Byte(ord("\r"))
            or esc == Byte(ord(" "))
            or esc == Byte(ord("\t"))
        ):
            var has_nl = esc == Byte(ord("\n")) or esc == Byte(ord("\r"))
            if esc == Byte(ord("\r")):
                if i + 1 >= n or ptr[unsafe_offset=i + 1] != Byte(ord("\n")):
                    return .Err("Bare CR in line-trimming backslash.")
            while i < n:
                var wb = ptr[unsafe_offset=i]
                if wb == Byte(ord(" ")) or wb == Byte(ord("\t")):
                    if has_nl:
                        i += 1
                    else:
                        i += 1
                elif wb == Byte(ord("\r")):
                    if i + 1 >= n or ptr[unsafe_offset=i + 1] != Byte(
                        ord("\n")
                    ):
                        return .Err("Bare CR in line-trimming backslash.")
                    has_nl = True
                    i += 2
                elif wb == Byte(ord("\n")):
                    has_nl = True
                    i += 1
                else:
                    break
            if not has_nl:
                return .Err(
                    "Line-trimming backslash must be followed by a newline."
                )
        else:
            return .Err("Unknown escape sequence in string.")

    return .Ok(None)


def decode_string(bytes: Span[Byte, _], flags: UInt8) -> Result[String]:
    """Decode and unescape a string literal into an owned `String`."""
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        return .Ok(String(StringSpan(unsafe_from_utf8=bytes)))

    var s = String(capacity_bytes=len(bytes))
    var res = decode_string_to_writer(bytes, flags, s)
    if case .Err = res:
        return .Err(res^.unsafe_take_error())
    _ = res^.unsafe_take_value()
    return .Ok(s^)
