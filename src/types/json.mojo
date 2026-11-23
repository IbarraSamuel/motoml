"""Streaming `toml-test` tagged JSON serialization and SIMD JSON string escaping."""

from std.bit import count_trailing_zeros
from std.collections import Span
from std.memory import Pointer, bitcast, pack_bits
from ..mode import Mode
from ..tape.decode import (
    decode_bool,
    decode_bool_unchecked,
    decode_date,
    decode_datetime,
    decode_datetime_unchecked,
    decode_float,
    decode_float_unchecked,
    decode_hex_n,
    decode_int,
    decode_int_unchecked,
    decode_time,
    decode_time_unchecked,
)
from ..tape.node import NO_NODE, Node, NodeFlags
from .store import _Store
from .tempo import Date


@always_inline
def _write_json_special_byte[W: Writer](b: Byte, mut w: W):
    """Write the JSON escape sequence for `\"`, `\\`, or any byte `< 0x20`."""
    if b == Byte(ord('"')):
        w.write('\\"')
    elif b == Byte(ord("\\")):
        w.write("\\\\")
    elif b == Byte(ord("\n")):
        w.write("\\n")
    elif b == Byte(ord("\r")):
        w.write("\\r")
    elif b == Byte(ord("\t")):
        w.write("\\t")
    elif b == Byte(ord("\b")):
        w.write("\\b")
    elif b == Byte(ord("\x0c")):
        w.write("\\f")
    else:
        var hex = "0123456789abcdef".as_bytes()
        w.write(
            "\\u00",
            StringSpan(unsafe_from_utf8=hex[Int(b >> 4) : Int(b >> 4) + 1]),
            StringSpan(unsafe_from_utf8=hex[Int(b & 0x0F) : Int(b & 0x0F) + 1]),
        )


@always_inline
def _write_json_codepoint[W: Writer](cp: UInt32, mut w: W):
    """Write a Unicode scalar value into a JSON string with necessary escaping.
    """
    if cp == UInt32(ord('"')) or cp == UInt32(ord("\\")) or cp < 0x20:
        _write_json_special_byte(Byte(cp), w)
    else:
        w.write(Codepoint(unsafe_unchecked_codepoint=cp))


@always_inline
def _write_json_escaped_bytes[W: Writer](bytes: Span[Byte, _], mut w: W):
    """Stream UTF-8 bytes into `w` with JSON escaping using a 16-byte SIMD scan.
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
        _write_json_special_byte(ptr[unsafe_offset=i], w)
        i += 1


def _write_toml_string_as_json_impl[
    validate: Bool, W: Writer
](
    bytes: Span[Byte, _],
    flags: UInt8,
    mut w: W,
    mut err_msg: StaticString,
) -> Bool:
    """Decode an escaped TOML 1.1 string directly into a JSON string body in one pass.
    """
    var is_multiline = (flags & NodeFlags.MULTILINE) != 0
    var i = 0
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
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

        var b = ptr[unsafe_offset=i]
        if b != Byte(ord("\\")):
            _write_json_special_byte(b, w)
            i += 1
            continue

        i += 1
        comptime if validate:
            if i >= n:
                err_msg = "Incomplete escape sequence."
                return False

        var esc = ptr[unsafe_offset=i]
        if esc == Byte(ord("b")):
            w.write("\\b")
            i += 1
        elif esc == Byte(ord("t")):
            w.write("\\t")
            i += 1
        elif esc == Byte(ord("n")):
            w.write("\\n")
            i += 1
        elif esc == Byte(ord("f")):
            w.write("\\f")
            i += 1
        elif esc == Byte(ord("r")):
            w.write("\\r")
            i += 1
        elif esc == Byte(ord("e")):
            w.write("\\u001b")
            i += 1
        elif esc == Byte(ord('"')):
            w.write('\\"')
            i += 1
        elif esc == Byte(ord("\\")):
            w.write("\\\\")
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
            _write_json_codepoint(UInt32(cp), w)
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
            _write_json_codepoint(UInt32(cp), w)
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
def _write_toml_string_bytes[
    mode: Mode, W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut w: W) raises:
    comptime if case .Eager = mode:
        _write_json_escaped_bytes(bytes, w)
    else:
        if (flags & NodeFlags.LITERAL) != 0 or (
            flags & NodeFlags.HAS_ESCAPE
        ) == 0:
            _write_json_escaped_bytes(bytes, w)
        else:
            var err_msg: StaticString = ""
            comptime if case .Strict = mode:
                _ = _write_toml_string_as_json_impl[False](
                    bytes, flags, w, err_msg
                )
            else:
                if not _write_toml_string_as_json_impl[True](
                    bytes, flags, w, err_msg
                ):
                    raise Error(err_msg)


@always_inline
def _eager_int(ref node: Node) -> Int:
    var u = (UInt64(node.len) << 32) | UInt64(node.start)
    return Int(bitcast[DType.int64, 1](u))


@always_inline
def _eager_float(ref node: Node) -> Float64:
    var u = (UInt64(node.len) << 32) | UInt64(node.start)
    return bitcast[DType.float64, 1](u)


@always_inline
def _eager_date(ref node: Node) -> Date:
    return Date(
        year=Int(node.start >> 16),
        month=Int((node.start >> 8) & 0xFF),
        day=Int(node.start & 0xFF),
    )


def _write_node_as_json[
    mode: Mode, origin: ImmOrigin, W: Writer
](
    doc_ptr: Pointer[Byte, origin],
    nodes_ptr: Pointer[Node, origin],
    store_ptr: Pointer[_Store, origin],
    node_idx: UInt32,
    mut w: W,
) raises:
    """Stream a tape node and its subtree as `toml-test` tagged JSON."""
    if node_idx == NO_NODE:
        raise Error("Cannot serialize Missing TOML value to JSON.")
    ref node = nodes_ptr[unsafe_offset=Int(node_idx)]

    match node.kind:
        case .String:
            var raw = Span[Byte, origin](
                unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            w.write('{"type": "string", "value": "')
            _write_toml_string_bytes[mode](raw, node.flags, w)
            w.write('"}')
        case .Integer:
            comptime if case .Eager = mode:
                w.write(
                    '{"type": "integer", "value": "', _eager_int(node), '"}'
                )
            else:
                var raw = Span[Byte, origin](
                    unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                comptime if case .Strict = mode:
                    if (node.flags & NodeFlags.CANONICAL) != 0:
                        var first = raw.unsafe_ptr()[unsafe_offset=0]
                        if first != Byte(ord("+")) and not (
                            len(raw) == 2
                            and first == Byte(ord("-"))
                            and raw.unsafe_ptr()[unsafe_offset=1]
                            == Byte(ord("0"))
                        ):
                            w.write(
                                '{"type": "integer", "value": "',
                                StringSpan(unsafe_from_utf8=raw),
                                '"}',
                            )
                            return
                    w.write(
                        '{"type": "integer", "value": "',
                        decode_int_unchecked(raw, node.flags),
                        '"}',
                    )
                else:
                    w.write(
                        '{"type": "integer", "value": "',
                        decode_int(raw).take(),
                        '"}',
                    )
        case .Float:
            comptime if case .Eager = mode:
                w.write(
                    '{"type": "float", "value": "', _eager_float(node), '"}'
                )
            else:
                var raw = Span[Byte, origin](
                    unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                comptime if case .Strict = mode:
                    w.write(
                        '{"type": "float", "value": "',
                        decode_float_unchecked(raw, node.flags),
                        '"}',
                    )
                else:
                    w.write(
                        '{"type": "float", "value": "',
                        decode_float(raw).take(),
                        '"}',
                    )
        case .NaN:
            w.write('{"type": "float", "value": "nan"}')
        case .Inf:
            comptime if case .Eager = mode:
                if _eager_float(node) < 0.0:
                    w.write('{"type": "float", "value": "-inf"}')
                else:
                    w.write('{"type": "float", "value": "inf"}')
            else:
                if node.len > 0 and doc_ptr[
                    unsafe_offset=Int(node.start)
                ] == Byte(ord("-")):
                    w.write('{"type": "float", "value": "-inf"}')
                else:
                    w.write('{"type": "float", "value": "inf"}')
        case .Boolean:
            var bval: Bool
            comptime match mode:
                case .Eager:
                    bval = node.start != 0
                case .Strict:
                    bval = decode_bool_unchecked(
                        Span[Byte, origin](
                            unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                            length=Int(node.len),
                        )
                    )
                case .Trusted:
                    bval = decode_bool(
                        Span[Byte, origin](
                            unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                            length=Int(node.len),
                        )
                    ).take()
            w.write(
                '{"type": "bool", "value": "true"}' if bval else '{"type": "bool", "value": "false"}'
            )
        case .Date:
            comptime if case .Eager = mode:
                w.write(
                    '{"type": "date-local", "value": "', _eager_date(node), '"}'
                )
            else:
                var raw = Span[Byte, origin](
                    unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                comptime if case .Strict = mode:
                    pass
                else:
                    _ = decode_date(raw).take()
                w.write(
                    '{"type": "date-local", "value": "',
                    StringSpan(unsafe_from_utf8=raw),
                    '"}',
                )
        case .Time:
            comptime if case .Eager = mode:
                w.write(
                    '{"type": "time-local", "value": "',
                    store_ptr[].temporals[Int(node.start)].time,
                    '"}',
                )
            else:
                var raw = Span[Byte, origin](
                    unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                comptime if case .Strict = mode:
                    w.write(
                        '{"type": "time-local", "value": "',
                        decode_time_unchecked(raw),
                        '"}',
                    )
                else:
                    w.write(
                        '{"type": "time-local", "value": "',
                        decode_time(raw).take(),
                        '"}',
                    )
        case .DateTime:
            var dt: DateTime
            match mode:
                case .Eager:
                    dt = store_ptr[].temporals[Int(node.start)]
                case .Strict:
                    dt = decode_datetime_unchecked(
                        Span[Byte, origin](
                            unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                            length=Int(node.len),
                        )
                    )
                case .Trusted:
                    dt = decode_datetime(
                        Span[Byte, origin](
                            unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                            length=Int(node.len),
                        )
                    ).take()
            var nm = "datetime-local" if dt.is_local else "datetime"
            w.write('{"type": "', nm, '", "value": "', dt, '"}')
        case .Array:
            w.write("[")
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    w.write(", ")
                first = False
                _write_node_as_json[mode_id](
                    doc_ptr, nodes_ptr, store_ptr, curr, w
                )
                curr = nodes_ptr[unsafe_offset=Int(curr)].next_sibling
            w.write("]")
        case .Table:
            w.write("{")
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    w.write(", ")
                first = False
                ref child_node = nodes_ptr[unsafe_offset=Int(curr)]
                w.write('"')
                var k_span = Span[Byte, origin](
                    unsafe_ptr=doc_ptr.unsafe_offset(Int(child_node.key_start)),
                    length=Int(child_node.key_len),
                )
                _write_toml_string_bytes[mode_id](
                    k_span, child_node.key_flags, w
                )
                w.write('": ')
                _write_node_as_json[mode_id](
                    doc_ptr, nodes_ptr, store_ptr, curr, w
                )
                curr = child_node.next_sibling
            w.write("}")
        case .Empty:
            pass
