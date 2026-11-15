"""Shared JSON escaping helpers for streaming TOML values to a `Writer`."""

from std.collections import Span
from std.memory import pack_bits
from std.bit import count_trailing_zeros


@always_inline
def _write_json_escaped_bytes[W: Writer](bytes: Span[Byte, _], mut w: W):
    """Stream UTF-8 bytes into `w` with JSON string escaping, using 16-byte SIMD scan.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var i = 0
    comptime W_SIMD = 16

    while i < n:
        var chunk_start = i
        while i + W_SIMD <= n:
            var v = ptr.unsafe_load[width=W_SIMD](i)
            var stop = v.eq(Byte(ord('"'))) | v.eq(Byte(ord("\\"))) | v.lt(0x20)
            var mask = pack_bits(stop)
            if not mask:
                i += W_SIMD
                continue
            i += Int(count_trailing_zeros(mask))
            break
        while i < n:
            var b = ptr[unsafe_offset=i]
            if b == Byte(ord('"')) or b == Byte(ord("\\")) or b < 0x20:
                break
            i += 1
        if i > chunk_start:
            w.write(StringSpan(unsafe_from_utf8=bytes[chunk_start:i]))
        if i >= n:
            break
        var esc_b = ptr[unsafe_offset=i]
        if esc_b == Byte(ord('"')):
            w.write('\\"')
        elif esc_b == Byte(ord("\\")):
            w.write("\\\\")
        elif esc_b == Byte(ord("\n")):
            w.write("\\n")
        elif esc_b == Byte(ord("\r")):
            w.write("\\r")
        elif esc_b == Byte(ord("\t")):
            w.write("\\t")
        elif esc_b == Byte(ord("\b")):
            w.write("\\b")
        elif esc_b == Byte(ord("\x0c")):
            w.write("\\f")
        else:
            var hex = "0123456789abcdef".as_bytes()
            w.write(
                "\\u00",
                StringSpan(
                    unsafe_from_utf8=hex[Int(esc_b >> 4) : Int(esc_b >> 4) + 1]
                ),
                StringSpan(
                    unsafe_from_utf8=hex[
                        Int(esc_b & 0x0F) : Int(esc_b & 0x0F) + 1
                    ]
                ),
            )
        i += 1
