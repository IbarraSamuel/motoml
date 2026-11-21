"""TOML 1.1 scalar and string validators and decoders."""

from std.bit import count_trailing_zeros
from std.collections import Span
from std.memory import pack_bits
from std.utils.numerics import inf, nan
from ..result import Result, ScalarResult
from ..types.tempo import (
    Date,
    DateTime,
    Time,
    decode_date,
    decode_date_unchecked,
    decode_datetime,
    decode_datetime_unchecked,
    decode_time,
    decode_time_unchecked,
    validate_date,
    validate_datetime,
    validate_time,
)
from .node import NodeFlags, NodeKind


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
def decode_hex_n[
    validate: Bool
](ptr: Pointer[Byte, _], start: Int, count: Int) -> Int64:
    """Decode `count` hex digits; returns `-1` on invalid hex when `validate=True`.
    """
    var cp: Int64 = 0
    for j in range(start, start + count):
        var hb = ptr[unsafe_offset=j]
        var d: Int64
        if Byte(ord("0")) <= hb <= Byte(ord("9")):
            d = Int64(hb - Byte(ord("0")))
        elif Byte(ord("a")) <= hb <= Byte(ord("f")):
            d = 10 + Int64(hb - Byte(ord("a")))
        elif Byte(ord("A")) <= hb <= Byte(ord("F")):
            d = 10 + Int64(hb - Byte(ord("A")))
        else:
            comptime if validate:
                return -1
            else:
                d = 0
        cp = (cp << 4) | d
    return cp


@always_inline
def check_escape_at[
    is_multiline: Bool
](ptr: Pointer[Byte, _], end: Int, mut idx: Int) -> Bool:
    """Validate a TOML 1.1 escape sequence starting at `ptr[idx]` (byte after `\\`).

    Advances `idx` to the last byte of the escape sequence so the caller's
    `idx += 1` lands on the first byte after the escape.
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
        if decode_hex_n[True](ptr, idx + 1, 2) < 0:
            return False
        idx += 2
        return True
    if esc == Byte(ord("u")) or esc == Byte(ord("U")):
        var hex_len = 4 if esc == Byte(ord("u")) else 8
        if idx + hex_len >= end:
            return False
        var cp = decode_hex_n[True](ptr, idx + 1, hex_len)
        if cp < 0 or (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
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


# --- Scalar validation ---


@always_inline
def validate_float(bytes: Span[Byte, _]) -> Bool:
    """Validate TOML 1.1 float literal syntax without calling `atof`."""
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
def validate_bool(bytes: Span[Byte, _]) -> Bool:
    """Validate a TOML boolean literal."""
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
    """Validate a 64-bit signed TOML integer literal."""
    return decode_int(bytes)._ok


@always_inline
def validate_scalar(kind: NodeKind, bytes: Span[Byte, _]) -> Bool:
    """Validate an unquoted scalar according to its classified `NodeKind`."""
    match kind:
        case .Integer:
            return validate_int(bytes)
        case .Float | .NaN | .Inf:
            return validate_float(bytes)
        case .Boolean:
            return validate_bool(bytes)
        case .Date:
            return validate_date(bytes)
        case .Time:
            return validate_time(bytes)
        case .DateTime:
            return validate_datetime(bytes)
        case _:
            return False


# --- Boolean & Integer decoding ---


@always_inline
def decode_bool_unchecked(bytes: Span[Byte, _]) -> Bool:
    """Decode a pre-validated boolean literal."""
    return bytes.unsafe_ptr()[unsafe_offset=0] == Byte(ord("t"))


@always_inline
def decode_bool(bytes: Span[Byte, _]) -> ScalarResult[Bool]:
    """Validate and decode a boolean literal."""
    if not validate_bool(bytes):
        return ScalarResult[Bool](False, False)
    return ScalarResult[Bool](decode_bool_unchecked(bytes), True)


@always_inline
def decode_int_unchecked(bytes: Span[Byte, _], flags: UInt8 = 0) -> Int:
    """Decode a pre-validated 64-bit signed integer literal."""
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


def decode_int(bytes: Span[Byte, _]) -> ScalarResult[Int]:
    """Validate and decode a 64-bit signed TOML integer literal."""
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

    var acc: UInt64 = 0
    if base == 10:
        comptime CUTOFF_10: UInt64 = 922337203685477580
        var cutlim: UInt64 = UInt64(8) if is_neg else UInt64(7)
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
            if acc > CUTOFF_10 or (acc == CUTOFF_10 and d > cutlim):
                return ScalarResult[Int](0, False)
            acc = acc * 10 + d
    else:
        # Signed non-decimal integers are rejected above (`has_sign`), so limit is I64_MAX.
        var cutoff: UInt64 = UInt64(0x07FFFFFFFFFFFFFF) if base == 16 else (
            UInt64(0x0FFFFFFFFFFFFFFF) if base
            == 8 else UInt64(0x3FFFFFFFFFFFFFFF)
        )
        var cutlim: UInt64 = UInt64(15) if base == 16 else (
            UInt64(7) if base == 8 else UInt64(1)
        )
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


# --- Float decoding ---


def _atof_fallback(bytes: Span[Byte, _], has_underscore: Bool) -> Float64:
    """Cold fallback to `atof` for >15-digit, extreme-exponent, or special floats.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var s = StringSpan(unsafe_from_utf8=bytes)
    if s == "nan" or s == "+nan" or s == "-nan":
        return nan[DType.float64]()
    if s == "inf" or s == "+inf":
        return inf[DType.float64]()
    if s == "-inf":
        return -inf[DType.float64]()
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
        return nan[DType.float64]()


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

    # General Clinger fast path for scientific / underscored floats (<= 15 digits & |exp| <= 22)
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


def decode_float(bytes: Span[Byte, _]) -> ScalarResult[Float64]:
    """Validate and decode a 64-bit IEEE-754 floating-point literal."""
    if not validate_float(bytes):
        return ScalarResult[Float64](0.0, False)
    return ScalarResult[Float64](decode_float_unchecked(bytes, 0), True)


# --- String unescaping (single unified implementation for checked & unchecked) ---


def _decode_string_to_writer_impl[
    validate: Bool, W: Writer
](
    bytes: Span[Byte, _],
    flags: UInt8,
    mut writer: W,
    mut err_msg: StaticString,
) -> Bool:
    """Unescape a TOML 1.1 string literal directly into `writer` using 16-byte SIMD scan.
    """
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        writer.write(StringSpan(unsafe_from_utf8=bytes))
        return True

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
        comptime if validate:
            if i >= n:
                err_msg = "Incomplete escape sequence."
                return False

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
        elif esc == Byte(ord('"')):
            writer.write('"')
            i += 1
        elif esc == Byte(ord("\\")):
            writer.write("\\")
            i += 1
        elif esc == Byte(ord("x")):
            comptime if validate:
                if i + 2 >= n:
                    err_msg = "Hex escape has too few digits."
                    return False
            var cp = decode_hex_n[validate](ptr, i + 1, 2)
            comptime if validate:
                if cp < 0:
                    err_msg = "Invalid hex digit in hex escape."
                    return False
            i += 3
            writer.write(Codepoint(unsafe_unchecked_codepoint=UInt32(cp)))
        elif esc == Byte(ord("u")) or esc == Byte(ord("U")):
            var hex_len = 4 if esc == Byte(ord("u")) else 8
            comptime if validate:
                if i + hex_len >= n:
                    err_msg = "Unicode escape has too few hex digits."
                    return False
            var cp = decode_hex_n[validate](ptr, i + 1, hex_len)
            comptime if validate:
                if cp < 0:
                    err_msg = "Invalid hex digit in unicode escape."
                    return False
                if (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
                    err_msg = (
                        "Unicode escape is not a valid Unicode scalar value."
                    )
                    return False
            i += 1 + hex_len
            writer.write(Codepoint(unsafe_unchecked_codepoint=UInt32(cp)))
        elif is_multiline and (
            esc == Byte(ord("\n"))
            or esc == Byte(ord("\r"))
            or esc == Byte(ord(" "))
            or esc == Byte(ord("\t"))
        ):
            var has_nl = esc == Byte(ord("\n")) or esc == Byte(ord("\r"))
            comptime if validate:
                if esc == Byte(ord("\r")):
                    if i + 1 >= n or ptr[unsafe_offset=i + 1] != Byte(
                        ord("\n")
                    ):
                        err_msg = "Bare CR in line-trimming backslash."
                        return False
            while i < n:
                var wb = ptr[unsafe_offset=i]
                if wb == Byte(ord(" ")) or wb == Byte(ord("\t")):
                    i += 1
                elif wb == Byte(ord("\r")):
                    comptime if validate:
                        if i + 1 >= n or ptr[unsafe_offset=i + 1] != Byte(
                            ord("\n")
                        ):
                            err_msg = "Bare CR in line-trimming backslash."
                            return False
                    has_nl = True
                    i += 2
                elif wb == Byte(ord("\n")):
                    has_nl = True
                    i += 1
                else:
                    break
            comptime if validate:
                if not has_nl:
                    err_msg = (
                        "Line-trimming backslash must be followed by a newline."
                    )
                    return False
        else:
            comptime if validate:
                err_msg = "Unknown escape sequence in string."
                return False

    return True


@always_inline
def decode_string_to_writer_unchecked[
    W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut writer: W):
    """Unescape a pre-validated string literal directly into `writer`."""
    var err_msg: StaticString = ""
    _ = _decode_string_to_writer_impl[False](bytes, flags, writer, err_msg)


@always_inline
def decode_string_to_writer[
    W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut writer: W) -> Result[NoneType]:
    """Validate and unescape a string literal directly into `writer`."""
    var err_msg: StaticString = ""
    if not _decode_string_to_writer_impl[True](bytes, flags, writer, err_msg):
        return .Err(Error(err_msg))
    return .Ok(None)


@always_inline
def decode_string_unchecked(bytes: Span[Byte, _], flags: UInt8) -> String:
    """Decode and unescape a pre-validated string literal into an owned `String`.
    """
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        return String(StringSpan(unsafe_from_utf8=bytes))
    var s = String(capacity_bytes=len(bytes))
    decode_string_to_writer_unchecked(bytes, flags, s)
    return s^


def decode_string(bytes: Span[Byte, _], flags: UInt8) -> Result[String]:
    """Validate and decode a string literal into an owned `String`."""
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        return .Ok(String(StringSpan(unsafe_from_utf8=bytes)))
    var s = String(capacity_bytes=len(bytes))
    var err_msg: StaticString = ""
    if not _decode_string_to_writer_impl[True](bytes, flags, s, err_msg):
        return .Err(Error(err_msg))
    return .Ok(s^)
