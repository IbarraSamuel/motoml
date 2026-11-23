"""TOML 1.1 scalar and string validators and decoders."""

from std.bit import count_trailing_zeros
from std.collections import Array, Span
from std.memory import Pointer, bitcast, pack_bits, unsafe_memcpy
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

# 256-entry hex digit lookup table (values 0..15 for hex digits, 16 for non-hex; all < 0x80).
comptime _HEX_TABLE: StaticString = (
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x10\x10\x10\x10\x10\x10"
    "\x10\x0a\x0b\x0c\x0d\x0e\x0f\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x0a\x0b\x0c\x0d\x0e\x0f\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
    "\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10\x10"
)

# 256-entry simple 1-byte TOML 1.1 escape translation table (`\"`, `\\`, `\b`, `\e`, `\f`, `\n`, `\r`, `\t`).
# Maps valid 1-byte escapes to their non-zero ASCII byte (< 0x80), and all other bytes to 0.
comptime _ESC_SIMPLE_TABLE: StaticString = (
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x22\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x5c\x00\x00\x00"
    "\x00\x00\x08\x00\x00\x1b\x0c\x00\x00\x00\x00\x00\x00\x00\x0a\x00"
    "\x00\x00\x0d\x00\x09\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
    "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
)


@always_inline
def _pow10(e: Int) -> Float64:
    """Compute exact `10.0 ** e` in IEEE-754 `Float64` for `0 <= e <= 22`."""
    comptime LO = SIMD[DType.float64, 8](1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7)
    if e < 8:
        return LO[e]
    var hi: Float64 = 1e8 if e < 16 else 1e16
    return LO[e & 7] * hi


@always_inline
def decode_hex_n[
    validate: Bool
](ptr: Pointer[Byte, _], start: Int, count: Int) -> Int64:
    """Decode `count` (2, 4, or 8) hex digits via table lookup; returns `-1` on invalid hex when `validate=True`.
    """
    var hex_ptr = _HEX_TABLE.unsafe_ptr()
    if count == 2:
        var d0 = UInt32(hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=start])])
        var d1 = UInt32(
            hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=start + 1])]
        )
        comptime if validate:
            if (d0 | d1) >= 16:
                return -1
        return Int64((d0 << 4) | d1)
    if count == 4:
        var d0 = UInt32(hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=start])])
        var d1 = UInt32(
            hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=start + 1])]
        )
        var d2 = UInt32(
            hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=start + 2])]
        )
        var d3 = UInt32(
            hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=start + 3])]
        )
        comptime if validate:
            if (d0 | d1 | d2 | d3) >= 16:
                return -1
        return Int64((d0 << 12) | (d1 << 8) | (d2 << 4) | d3)

    var cp: UInt64 = 0
    var bad: UInt32 = 0
    for j in range(start, start + count):
        var d = UInt32(hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=j])])
        bad |= d
        cp = (cp << 4) | UInt64(d & 0x0F)
    comptime if validate:
        if bad >= 16:
            return -1
    return Int64(cp)


@always_inline
def _encode_utf8_codepoint(
    cp: UInt32, dst: MutPointer[Byte, _], pos: Int
) -> Int:
    """Encode a validated Unicode scalar value (`0..0x10FFFF`) as UTF-8 into `dst + pos`.
    """
    if cp < 0x80:
        dst[unsafe_offset=pos] = Byte(cp)
        return pos + 1
    if cp < 0x800:
        dst[unsafe_offset=pos] = Byte(0xC0 | (cp >> 6))
        dst[unsafe_offset=pos + 1] = Byte(0x80 | (cp & 0x3F))
        return pos + 2
    if cp < 0x10000:
        dst[unsafe_offset=pos] = Byte(0xE0 | (cp >> 12))
        dst[unsafe_offset=pos + 1] = Byte(0x80 | ((cp >> 6) & 0x3F))
        dst[unsafe_offset=pos + 2] = Byte(0x80 | (cp & 0x3F))
        return pos + 3
    dst[unsafe_offset=pos] = Byte(0xF0 | (cp >> 18))
    dst[unsafe_offset=pos + 1] = Byte(0x80 | ((cp >> 12) & 0x3F))
    dst[unsafe_offset=pos + 2] = Byte(0x80 | ((cp >> 6) & 0x3F))
    dst[unsafe_offset=pos + 3] = Byte(0x80 | (cp & 0x3F))
    return pos + 4


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
    if _ESC_SIMPLE_TABLE.unsafe_ptr()[unsafe_offset=Int(esc)] != 0:
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
def _parse_4d_swar(ptr: ImmPointer[Byte, _], offset: Int) -> UInt64:
    var v = (
        bitcast[DType.uint32, 1](ptr.unsafe_load[width=4](offset)) - 0x30303030
    )
    v = ((v & 0x00FF00FF) * 10) + ((v >> 8) & 0x00FF00FF)
    return UInt64(((v & 0x0000FFFF) * 100) + (v >> 16))


@always_inline
def _parse_8d_swar(ptr: ImmPointer[Byte, _], offset: Int) -> UInt64:
    var v = (
        bitcast[DType.uint64, 1](ptr.unsafe_load[width=8](offset))
        - 0x3030303030303030
    )
    v = ((v & 0x00FF00FF00FF00FF) * 10) + ((v >> 8) & 0x00FF00FF00FF00FF)
    v = ((v & 0x0000FFFF0000FFFF) * 100) + ((v >> 16) & 0x0000FFFF0000FFFF)
    return ((v & 0xFFFFFFFF) * 10000) + (v >> 32)


@always_inline
def decode_int_unchecked(bytes: Span[Byte, _], flags: UInt8 = 0) -> Int:
    """Decode a pre-validated 64-bit signed integer literal."""
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var first = ptr[unsafe_offset=0]

    if (flags & NodeFlags.CANONICAL) != 0:
        var is_neg = first == Byte(ord("-"))
        var start = Int(is_neg or first == Byte(ord("+")))
        var dlen = n - start
        var acc: UInt64
        if dlen <= 4:
            if dlen == 1:
                acc = UInt64(ptr[unsafe_offset=start] - Byte(ord("0")))
            elif dlen == 2:
                acc = UInt64(
                    ptr[unsafe_offset=start] - Byte(ord("0"))
                ) * 10 + UInt64(ptr[unsafe_offset=start + 1] - Byte(ord("0")))
            elif dlen == 3:
                acc = (
                    UInt64(ptr[unsafe_offset=start] - Byte(ord("0"))) * 100
                    + UInt64(ptr[unsafe_offset=start + 1] - Byte(ord("0"))) * 10
                    + UInt64(ptr[unsafe_offset=start + 2] - Byte(ord("0")))
                )
            else:
                acc = _parse_4d_swar(ptr, start)
        elif dlen <= 8:
            var rem = dlen - 4
            var hi: UInt64
            if rem == 1:
                hi = UInt64(ptr[unsafe_offset=start] - Byte(ord("0")))
            elif rem == 2:
                hi = UInt64(
                    ptr[unsafe_offset=start] - Byte(ord("0"))
                ) * 10 + UInt64(ptr[unsafe_offset=start + 1] - Byte(ord("0")))
            elif rem == 3:
                hi = (
                    UInt64(ptr[unsafe_offset=start] - Byte(ord("0"))) * 100
                    + UInt64(ptr[unsafe_offset=start + 1] - Byte(ord("0"))) * 10
                    + UInt64(ptr[unsafe_offset=start + 2] - Byte(ord("0")))
                )
            else:
                hi = _parse_4d_swar(ptr, start)
            acc = hi * 10000 + _parse_4d_swar(ptr, start + rem)
        else:
            acc = _parse_8d_swar(ptr, start)
            for i in range(start + 8, n):
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
        var hex_ptr = _HEX_TABLE.unsafe_ptr()
        var shift: UInt64 = UInt64(4) if prefix == Byte(ord("x")) else (
            UInt64(3) if prefix == Byte(ord("o")) else UInt64(1)
        )
        var acc: UInt64 = 0
        for i in range(start + 2, n):
            var b = ptr[unsafe_offset=i]
            if b == Byte(ord("_")):
                continue
            acc = (acc << shift) | UInt64(hex_ptr[unsafe_offset=Int(b)])
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
        var hex_ptr = _HEX_TABLE.unsafe_ptr()
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
                var prev_d = UInt64(
                    hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=i - 1])]
                )
                var next_d = UInt64(
                    hex_ptr[unsafe_offset=Int(ptr[unsafe_offset=i + 1])]
                )
                if prev_d >= base or next_d >= base:
                    return ScalarResult[Int](0, False)
                continue
            var d = UInt64(hex_ptr[unsafe_offset=Int(b)])
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
            var i = start
            while i < n:
                var b = ptr[unsafe_offset=i]
                if b == Byte(ord(".")):
                    break
                acc = acc * 10 + UInt64(b - Byte(ord("0")))
                i += 1
            var frac_start = i + 1
            var frac_len = n - frac_start
            for j in range(frac_start, n):
                acc = acc * 10 + UInt64(ptr[unsafe_offset=j] - Byte(ord("0")))
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


# --- Direct-buffer & Writer string unescaping ---


def _decode_string_to_buf_impl[
    validate: Bool
](
    bytes: Span[Byte, _],
    flags: UInt8,
    dst: MutPointer[Byte, _],
    mut err_msg: StaticString,
) -> Int:
    """Unescape a TOML 1.1 string directly into `dst` (capacity >= `len(bytes)`), returning written byte length or `-1`.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        if n > 0:
            unsafe_memcpy(dest=dst, src=ptr, count=n)
        return n

    var is_multiline = (flags & NodeFlags.MULTILINE) != 0
    var esc_tbl = _ESC_SIMPLE_TABLE.unsafe_ptr()
    var i = 0
    var out_pos = 0
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
        var copy_len = i - chunk_start
        if copy_len > 0:
            unsafe_memcpy(
                dest=dst.unsafe_offset(out_pos),
                src=ptr.unsafe_offset(chunk_start),
                count=copy_len,
            )
            out_pos += copy_len
        if i >= n:
            break

        i += 1
        comptime if validate:
            if i >= n:
                err_msg = "Incomplete escape sequence."
                return -1

        var esc = ptr[unsafe_offset=i]
        var simple = esc_tbl[unsafe_offset=Int(esc)]
        if simple != 0:
            dst[unsafe_offset=out_pos] = simple
            out_pos += 1
            i += 1
        elif esc == Byte(ord("x")):
            comptime if validate:
                if i + 2 >= n:
                    err_msg = "Hex escape has too few digits."
                    return -1
            var cp = decode_hex_n[validate](ptr, i + 1, 2)
            comptime if validate:
                if cp < 0:
                    err_msg = "Invalid hex digit in hex escape."
                    return -1
            i += 3
            out_pos = _encode_utf8_codepoint(UInt32(cp), dst, out_pos)
        elif esc == Byte(ord("u")) or esc == Byte(ord("U")):
            var hex_len = 4 if esc == Byte(ord("u")) else 8
            comptime if validate:
                if i + hex_len >= n:
                    err_msg = "Unicode escape has too few hex digits."
                    return -1
            var cp = decode_hex_n[validate](ptr, i + 1, hex_len)
            comptime if validate:
                if cp < 0:
                    err_msg = "Invalid hex digit in unicode escape."
                    return -1
                if (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
                    err_msg = (
                        "Unicode escape is not a valid Unicode scalar value."
                    )
                    return -1
            i += 1 + hex_len
            out_pos = _encode_utf8_codepoint(UInt32(cp), dst, out_pos)
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
                        return -1
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
                            return -1
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
                    return -1
        else:
            comptime if validate:
                err_msg = "Unknown escape sequence in string."
                return -1

    return out_pos


@always_inline
def decode_string_to_buf_unchecked(
    bytes: Span[Byte, _], flags: UInt8, dst: MutPointer[Byte, _]
) -> Int:
    """Unescape a pre-validated string literal directly into `dst`, returning decoded byte count.
    """
    var err_msg: StaticString = ""
    return _decode_string_to_buf_impl[False](bytes, flags, dst, err_msg)


@always_inline
def decode_string_to_writer_unchecked[
    W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut writer: W):
    """Unescape a pre-validated string literal into `writer` (stack-buffered for `<= 512` bytes).
    """
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        writer.write(StringSpan(unsafe_from_utf8=bytes))
        return
    var n = len(bytes)
    if n <= 512:
        var sbuf = Array[Byte, 512](uninitialized=True)
        var err_msg: StaticString = ""
        var written = _decode_string_to_buf_impl[False](
            bytes, flags, sbuf.unsafe_ptr(), err_msg
        )
        writer.write(
            StringSpan(
                unsafe_from_utf8=Span(
                    unsafe_ptr=sbuf.unsafe_ptr(), length=written
                )
            )
        )
        return
    var s = decode_string_unchecked(bytes, flags)
    writer.write(s)


@always_inline
def decode_string_to_writer[
    W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut writer: W) -> Result[NoneType]:
    """Validate and unescape a string literal into `writer` (stack-buffered for `<= 512` bytes).
    """
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        writer.write(StringSpan(unsafe_from_utf8=bytes))
        return .Ok(None)
    var n = len(bytes)
    if n <= 512:
        var sbuf = Array[Byte, 512](uninitialized=True)
        var err_msg: StaticString = ""
        var written = _decode_string_to_buf_impl[True](
            bytes, flags, sbuf.unsafe_ptr(), err_msg
        )
        if written < 0:
            return .Err(Error(err_msg))
        writer.write(
            StringSpan(
                unsafe_from_utf8=Span(
                    unsafe_ptr=sbuf.unsafe_ptr(), length=written
                )
            )
        )
        return .Ok(None)
    var s = String(capacity_bytes=n)
    var dst = s.unsafe_ptr_mut(n)
    var err_msg: StaticString = ""
    var written = _decode_string_to_buf_impl[True](bytes, flags, dst, err_msg)
    if written < 0:
        return .Err(Error(err_msg))
    s.resize(unsafe_uninit_length=written)
    writer.write(s)
    return .Ok(None)


@always_inline
def decode_string_unchecked(bytes: Span[Byte, _], flags: UInt8) -> String:
    """Decode and unescape a pre-validated string literal into an owned `String`.
    """
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        return String(StringSpan(unsafe_from_utf8=bytes))
    var n = len(bytes)
    var s = String(capacity_bytes=n)
    var dst = s.unsafe_ptr_mut(n)
    var err_msg: StaticString = ""
    var written = _decode_string_to_buf_impl[False](bytes, flags, dst, err_msg)
    s.resize(unsafe_uninit_length=written)
    return s^


def decode_string(bytes: Span[Byte, _], flags: UInt8) -> Result[String]:
    """Validate and decode a string literal into an owned `String`."""
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        return .Ok(String(StringSpan(unsafe_from_utf8=bytes)))
    var n = len(bytes)
    var s = String(capacity_bytes=n)
    var dst = s.unsafe_ptr_mut(n)
    var err_msg: StaticString = ""
    var written = _decode_string_to_buf_impl[True](bytes, flags, dst, err_msg)
    if written < 0:
        return .Err(Error(err_msg))
    s.resize(unsafe_uninit_length=written)
    return .Ok(s^)
