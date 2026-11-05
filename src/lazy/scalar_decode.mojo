"""Non-allocating and lazy decoders for scalar TOML values.
"""

from ..result import Result
from .node import NodeFlags
from ..types.tempo import Date, Time, DateTime
from std.collections import Span
from std.math import nan


@always_inline
def decode_bool(bytes: Span[Byte, _]) -> Result[Bool]:
    if len(bytes) == 4 and bytes[0] == Byte(ord("t")):
        return .Ok(True)
    elif len(bytes) == 5 and bytes[0] == Byte(ord("f")):
        return .Ok(False)
    return .Err("Invalid boolean value.")


def decode_int(bytes: Span[Byte, _]) -> Result[Int]:
    if len(bytes) == 0:
        return .Err("Empty integer value.")

    var start = 0
    var is_neg = False
    if bytes[0] == Byte(ord("-")):
        is_neg = True
        start = 1
    elif bytes[0] == Byte(ord("+")):
        start = 1

    if start >= len(bytes):
        return .Err("Malformed integer.")

    var has_sign = start > 0
    var base: Int = 10
    if len(bytes) - start > 1 and bytes[start] == Byte(ord("0")):
        var prefix = bytes[start + 1]
        if (
            prefix == Byte(ord("x"))
            or prefix == Byte(ord("o"))
            or prefix == Byte(ord("b"))
        ):
            if has_sign:
                return .Err("Sign not allowed on non-decimal integer.")
            if prefix == Byte(ord("x")):
                base = 16
            elif prefix == Byte(ord("o")):
                base = 8
            else:
                base = 2
            start += 2
            if start >= len(bytes):
                return .Err("Incomplete non-decimal integer.")
        elif (
            prefix == Byte(ord("X"))
            or prefix == Byte(ord("O"))
            or prefix == Byte(ord("B"))
        ):
            return .Err("Non-decimal integer prefixes must be lowercase.")
        else:
            return .Err("Leading zeros are not allowed in decimal integers.")

    var val: Int = 0
    for i in range(start, len(bytes)):
        var b = bytes[i]
        if b == Byte(ord("_")):
            if i == start or i + 1 >= len(bytes):
                return .Err("Invalid underscore in integer.")
            var prev_b = bytes[i - 1]
            var next_b = bytes[i + 1]
            var prev_valid = (Byte(ord("0")) <= prev_b <= Byte(ord("9"))) or (
                base == 16
                and (
                    (Byte(ord("a")) <= prev_b <= Byte(ord("f")))
                    or (Byte(ord("A")) <= prev_b <= Byte(ord("F")))
                )
            )
            var next_valid = (Byte(ord("0")) <= next_b <= Byte(ord("9"))) or (
                base == 16
                and (
                    (Byte(ord("a")) <= next_b <= Byte(ord("f")))
                    or (Byte(ord("A")) <= next_b <= Byte(ord("F")))
                )
            )
            if not prev_valid or not next_valid:
                return .Err("Invalid underscore in integer.")
            continue
        var digit: Int = -1
        if Byte(ord("0")) <= b <= Byte(ord("9")):
            digit = Int(b - Byte(ord("0")))
        elif Byte(ord("a")) <= b <= Byte(ord("f")):
            digit = 10 + Int(b - Byte(ord("a")))
        elif Byte(ord("A")) <= b <= Byte(ord("F")):
            digit = 10 + Int(b - Byte(ord("A")))

        if digit < 0 or digit >= base:
            return .Err("Invalid digit in integer.")
        val = val * base + digit

    if is_neg:
        val = -val
    return .Ok(val)


def decode_float(bytes: Span[Byte, _]) -> Result[Float64]:
    if len(bytes) == 0:
        return .Err("Empty float value.")

    var s = StringSlice(unsafe_from_utf8=bytes)
    if s == "nan" or s == "+nan" or s == "-nan":
        return .Ok(nan[DType.float64]())
    if s == "inf" or s == "+inf":
        return .Ok(Float64.MAX)
    if s == "-inf":
        return .Ok(Float64.MIN)

    for i in range(len(bytes)):
        var b = bytes[i]
        if not (
            (Byte(ord("0")) <= b <= Byte(ord("9")))
            or b == Byte(ord("."))
            or b == Byte(ord("_"))
            or b == Byte(ord("+"))
            or b == Byte(ord("-"))
            or b == Byte(ord("e"))
            or b == Byte(ord("E"))
        ):
            return .Err("Invalid character in float.")

    var dot_pos = s.find(".")
    if dot_pos >= 0:
        if dot_pos == 0 or dot_pos == len(bytes) - 1:
            return .Err(
                "Float must have digits before and after decimal point."
            )
        var prev_b = bytes[dot_pos - 1]
        var next_b = bytes[dot_pos + 1]
        if not (Byte(ord("0")) <= prev_b <= Byte(ord("9"))) or not (
            Byte(ord("0")) <= next_b <= Byte(ord("9"))
        ):
            return .Err("Decimal point must be surrounded by digits.")
        var int_start = 0
        if len(bytes) > 0 and (
            bytes[0] == Byte(ord("-")) or bytes[0] == Byte(ord("+"))
        ):
            int_start = 1
        if dot_pos > int_start + 1 and bytes[int_start] == Byte(ord("0")):
            return .Err("Leading zeros not allowed in float integer part.")

    var has_underscore = False
    for i in range(len(bytes)):
        if bytes[i] == Byte(ord("_")):
            if (
                i == 0
                or i + 1 >= len(bytes)
                or not (Byte(ord("0")) <= bytes[i - 1] <= Byte(ord("9")))
                or not (Byte(ord("0")) <= bytes[i + 1] <= Byte(ord("9")))
            ):
                return .Err("Invalid underscore in float.")
            has_underscore = True

    try:
        if has_underscore:
            return .Ok(atof(s.replace("_", "")))
        return .Ok(atof(s))
    except e:
        return .Err(e^)


def decode_date(bytes: Span[Byte, _]) -> Result[Date]:
    return Date.from_string(StringSlice(unsafe_from_utf8=bytes))


def decode_time(bytes: Span[Byte, _]) -> Result[Time]:
    return Time.from_string(StringSlice(unsafe_from_utf8=bytes))


def decode_datetime(bytes: Span[Byte, _]) -> Result[DateTime]:
    return DateTime.from_string(StringSlice(unsafe_from_utf8=bytes))


def decode_string_to_writer[
    W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut writer: W) -> Result[NoneType]:
    # Literal strings have zero unescaping
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        writer.write(StringSlice(unsafe_from_utf8=bytes))
        return .Ok(None)

    var is_multiline = (flags & NodeFlags.MULTILINE) != 0
    var i = 0
    var n = len(bytes)

    while i < n:
        var chunk_start = i
        while i < n and bytes[i] != Byte(ord("\\")):
            i += 1
        if i > chunk_start:
            writer.write(StringSlice(unsafe_from_utf8=bytes[chunk_start:i]))
        if i >= n:
            break

        i += 1
        if i >= n:
            return .Err("Incomplete escape sequence.")

        var esc = bytes[i]
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
                var hb = bytes[j]
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
                var hb = bytes[j]
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
            # Line-ending backslash: optional spaces/tabs, MUST have at least one newline
            var has_nl = esc == Byte(ord("\n")) or esc == Byte(ord("\r"))
            while i < n:
                var wb = bytes[i]
                if wb == Byte(ord(" ")) or wb == Byte(ord("\t")):
                    i += 1
                elif wb == Byte(ord("\r")) or wb == Byte(ord("\n")):
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
    if (flags & NodeFlags.LITERAL) != 0 or (flags & NodeFlags.HAS_ESCAPE) == 0:
        return .Ok(String(StringSlice(unsafe_from_utf8=bytes)))

    var s = String()
    var res = decode_string_to_writer(bytes, flags, s)
    if case .Err = res:
        return .Err(res^.unsafe_take_error())
    _ = res^.unsafe_take_value()
    return .Ok(s^)
