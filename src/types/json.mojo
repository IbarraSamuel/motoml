"""High-throughput buffered `toml-test` tagged JSON serialization and SIMD JSON escaping."""

from std.bit import count_trailing_zeros
from std.collections import Array, Span
from std.memory import Pointer, bitcast, pack_bits, unsafe_memcpy
from ..mode import Mode
from ..tape.decode import (
    _ESC_SIMPLE_TABLE,
    _encode_utf8_codepoint,
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
from .tempo import (
    Date,
    DateTime,
    _DIGIT_PAIRS,
    _format_date_buf,
    _format_datetime_buf,
    _format_time_buf,
)

comptime _HEX_LOWER: StaticString = "0123456789abcdef"


struct _JsonBufWriter[W: Writer, w_origin: MutOrigin](
    Movable, not RegisterPassable, Writer
):
    """4 KB stack-buffered JSON writer minimizing calls into generic `Writer`.
    """

    comptime CAP = 4096

    var w: Pointer[Self.W, Self.w_origin]
    var buf: Array[Byte, 4096]
    var pos: Int

    @always_inline
    def __init__(out self, ref[Self.w_origin] w: Self.W):
        self.w = Pointer(to=w)
        self.buf = Array[Byte, 4096](uninitialized=True)
        self.pos = 0

    @inline(.never)
    def flush(mut self):
        if self.pos > 0:
            self.w[].write_string(
                StringSpan(
                    unsafe_from_utf8=Span(
                        unsafe_ptr=self.buf.unsafe_ptr(), length=self.pos
                    )
                )
            )
            self.pos = 0

    @always_inline
    def ensure(mut self, extra: Int):
        if self.pos + extra > Self.CAP:
            self.flush()

    @always_inline
    def put_byte(mut self, b: Byte):
        if self.pos == Self.CAP:
            self.flush()
        self.buf.unsafe_ptr()[unsafe_offset=self.pos] = b
        self.pos += 1

    @always_inline
    def put_2bytes(mut self, b0: Byte, b1: Byte):
        if self.pos + 2 > Self.CAP:
            self.flush()
        var p = self.buf.unsafe_ptr().unsafe_offset(self.pos)
        p[unsafe_offset=0] = b0
        p[unsafe_offset=1] = b1
        self.pos += 2

    @always_inline
    def put_bytes(mut self, src: ImmPointer[Byte, _], n: Int):
        if n <= 0:
            return
        if self.pos + n <= Self.CAP:
            unsafe_memcpy(
                dest=self.buf.unsafe_ptr().unsafe_offset(self.pos),
                src=src,
                count=n,
            )
            self.pos += n
            return
        self.flush()
        if n >= 512:
            self.w[].write_string(
                StringSpan(unsafe_from_utf8=Span(unsafe_ptr=src, length=n))
            )
        else:
            unsafe_memcpy(dest=self.buf.unsafe_ptr(), src=src, count=n)
            self.pos = n

    @always_inline
    def put_lit[s: StaticString](mut self):
        comptime N = s.byte_length()
        if self.pos + N > Self.CAP:
            self.flush()
        var lit_s: StaticString = materialize[s]()
        unsafe_memcpy(
            dest=self.buf.unsafe_ptr().unsafe_offset(self.pos),
            src=lit_s.unsafe_ptr(),
            count=N,
        )
        self.pos += N

    @always_inline
    def write_string(mut self, string: StringSpan):
        var sb = string.as_bytes()
        self.put_bytes(sb.unsafe_ptr(), len(sb))

    @always_inline
    def put_int(mut self, val: Int):
        """Format a 64-bit signed integer directly into the buffer using 2-digit pair lookups.
        """
        self.ensure(24)
        var p = self.buf.unsafe_ptr()
        if val == 0:
            p[unsafe_offset=self.pos] = Byte(ord("0"))
            self.pos += 1
            return

        var u: UInt64
        if val < 0:
            p[unsafe_offset=self.pos] = Byte(ord("-"))
            self.pos += 1
            if val == Int(-9223372036854775807 - 1):
                u = UInt64(0x8000000000000000)
            else:
                u = UInt64(-val)
        else:
            u = UInt64(val)

        var tmp = Array[Byte, 20](uninitialized=True)
        var tp = tmp.unsafe_ptr()
        var ti = 20
        var dp = _DIGIT_PAIRS.unsafe_ptr()
        while u >= 100:
            var q = u // 100
            var r = Int(u - q * 100) * 2
            u = q
            ti -= 2
            tp[unsafe_offset=ti] = dp[unsafe_offset=r]
            tp[unsafe_offset=ti + 1] = dp[unsafe_offset=r + 1]
        if u < 10:
            ti -= 1
            tp[unsafe_offset=ti] = Byte(ord("0")) + Byte(u)
        else:
            var r = Int(u) * 2
            ti -= 2
            tp[unsafe_offset=ti] = dp[unsafe_offset=r]
            tp[unsafe_offset=ti + 1] = dp[unsafe_offset=r + 1]

        var digits_n = 20 - ti
        unsafe_memcpy(
            dest=p.unsafe_offset(self.pos),
            src=tp.unsafe_offset(ti),
            count=digits_n,
        )
        self.pos += digits_n


@always_inline
def _put_json_special_byte[W: Writer](b: Byte, mut bw: _JsonBufWriter[W, _]):
    """Write the JSON escape sequence for `\"`, `\\`, or any byte `< 0x20`."""
    if b == Byte(ord('"')):
        bw.put_2bytes(Byte(ord("\\")), Byte(ord('"')))
    elif b == Byte(ord("\\")):
        bw.put_2bytes(Byte(ord("\\")), Byte(ord("\\")))
    elif b == Byte(ord("\n")):
        bw.put_2bytes(Byte(ord("\\")), Byte(ord("n")))
    elif b == Byte(ord("\r")):
        bw.put_2bytes(Byte(ord("\\")), Byte(ord("r")))
    elif b == Byte(ord("\t")):
        bw.put_2bytes(Byte(ord("\\")), Byte(ord("t")))
    elif b == Byte(ord("\b")):
        bw.put_2bytes(Byte(ord("\\")), Byte(ord("b")))
    elif b == Byte(ord("\x0c")):
        bw.put_2bytes(Byte(ord("\\")), Byte(ord("f")))
    else:
        bw.ensure(6)
        var hex = _HEX_LOWER.unsafe_ptr()
        var p = bw.buf.unsafe_ptr().unsafe_offset(bw.pos)
        p[unsafe_offset=0] = Byte(ord("\\"))
        p[unsafe_offset=1] = Byte(ord("u"))
        p[unsafe_offset=2] = Byte(ord("0"))
        p[unsafe_offset=3] = Byte(ord("0"))
        p[unsafe_offset=4] = hex[unsafe_offset=Int(b >> 4)]
        p[unsafe_offset=5] = hex[unsafe_offset=Int(b & 0x0F)]
        bw.pos += 6


@always_inline
def _put_json_codepoint[W: Writer](cp: UInt32, mut bw: _JsonBufWriter[W, _]):
    """Write a Unicode scalar value into a JSON string with necessary escaping.
    """
    if cp == UInt32(ord('"')) or cp == UInt32(ord("\\")) or cp < 0x20:
        _put_json_special_byte(Byte(cp), bw)
    else:
        bw.ensure(4)
        bw.pos = _encode_utf8_codepoint(cp, bw.buf.unsafe_ptr(), bw.pos)


@always_inline
def _put_json_escaped_bytes[
    W: Writer
](bytes: Span[Byte, _], mut bw: _JsonBufWriter[W, _]):
    """Stream UTF-8 bytes into `bw` with JSON escaping using a 16-byte SIMD scan.
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
            if not any(stop):
                i += W_SIMD
                continue
            i += Int(count_trailing_zeros(pack_bits(stop)))
            break
        while i < n:
            var b = ptr[unsafe_offset=i]
            if b == Byte(ord('"')) or b == Byte(ord("\\")) or b < 0x20:
                break
            i += 1
        if i > chunk_start:
            bw.put_bytes(ptr.unsafe_offset(chunk_start), i - chunk_start)
        if i >= n:
            break
        _put_json_special_byte(ptr[unsafe_offset=i], bw)
        i += 1


def _put_toml_string_as_json_impl[
    validate: Bool, W: Writer
](
    bytes: Span[Byte, _],
    flags: UInt8,
    mut bw: _JsonBufWriter[W, _],
    mut err_msg: StaticString,
) -> Bool:
    """Decode an escaped TOML 1.1 string directly into `bw` as JSON in one pass.
    """
    var is_multiline = (flags & NodeFlags.MULTILINE) != 0
    var esc_tbl = _ESC_SIMPLE_TABLE.unsafe_ptr()
    var i = 0
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    comptime W_SIMD = 16

    while i < n:
        var chunk_start = i
        while i + W_SIMD <= n:
            var v = ptr.unsafe_load[width=W_SIMD](i)
            var stop = v.eq(Byte(ord('"'))) | v.eq(Byte(ord("\\"))) | v.lt(0x20)
            if not any(stop):
                i += W_SIMD
                continue
            i += Int(count_trailing_zeros(pack_bits(stop)))
            break
        while i < n:
            var b = ptr[unsafe_offset=i]
            if b == Byte(ord('"')) or b == Byte(ord("\\")) or b < 0x20:
                break
            i += 1
        if i > chunk_start:
            bw.put_bytes(ptr.unsafe_offset(chunk_start), i - chunk_start)
        if i >= n:
            break

        var b = ptr[unsafe_offset=i]
        if b != Byte(ord("\\")):
            _put_json_special_byte(b, bw)
            i += 1
            continue

        i += 1
        comptime if validate:
            if i >= n:
                err_msg = "Incomplete escape sequence."
                return False

        var esc = ptr[unsafe_offset=i]
        var simple = esc_tbl[unsafe_offset=Int(esc)]
        if simple != 0:
            _put_json_special_byte(simple, bw)
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
            _put_json_codepoint(UInt32(cp), bw)
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
            _put_json_codepoint(UInt32(cp), bw)
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
def _put_toml_string_bytes[
    mode: Mode, W: Writer
](bytes: Span[Byte, _], flags: UInt8, mut bw: _JsonBufWriter[W, _]) raises:
    comptime if case .Eager = mode:
        _put_json_escaped_bytes(bytes, bw)
    else:
        if (flags & NodeFlags.LITERAL) != 0 or (
            flags & NodeFlags.HAS_ESCAPE
        ) == 0:
            _put_json_escaped_bytes(bytes, bw)
        else:
            var err_msg: StaticString = ""
            comptime if case .Strict = mode:
                _ = _put_toml_string_as_json_impl[False](
                    bytes, flags, bw, err_msg
                )
            else:
                if not _put_toml_string_as_json_impl[True](
                    bytes, flags, bw, err_msg
                ):
                    raise Error(err_msg)


@always_inline
def _is_exact_canonical_float_repr(
    ptr: ImmPointer[Byte, _], n: Int, flags: UInt8, mut trim_plus: Int
) -> Bool:
    """Return True iff `ptr[trim_plus..n]` is guaranteed byte-for-byte identical to `Float64.write_to`.
    """
    if (flags & NodeFlags.CANONICAL) == 0:
        return False
    var first = ptr[unsafe_offset=0]
    trim_plus = 1 if first == Byte(ord("+")) else 0
    var lead_idx = 1 if (
        first == Byte(ord("+")) or first == Byte(ord("-"))
    ) else 0
    var mag_len = n - lead_idx
    if mag_len > 16:
        return False
    var last = ptr[unsafe_offset=n - 1]
    if last == Byte(ord("0")) and ptr[unsafe_offset=n - 2] != Byte(ord(".")):
        return False
    var d0 = ptr[unsafe_offset=lead_idx]
    if Byte(ord("1")) <= d0 <= Byte(ord("9")):
        return True
    # d0 == '0' (so ptr[lead_idx + 1] == '.'): exact fixed-point iff `0.0` or first frac digit != '0'
    var f0 = ptr[unsafe_offset=lead_idx + 2]
    return (mag_len == 3 and f0 == Byte(ord("0"))) or (
        Byte(ord("1")) <= f0 <= Byte(ord("9"))
    )


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


def _write_node_as_json_buf[
    mode: Mode, origin: ImmOrigin, W: Writer, w_origin: MutOrigin
](
    doc_ptr: Pointer[Byte, origin],
    nodes_ptr: Pointer[Node, origin],
    store_ptr: Pointer[_Store, origin],
    node_idx: UInt32,
    mut bw: _JsonBufWriter[W, w_origin],
) raises:
    """Stream a tape node and its subtree into `bw` as `toml-test` tagged JSON.
    """
    if node_idx == NO_NODE:
        raise Error("Cannot serialize Missing TOML value to JSON.")
    ref node = nodes_ptr[unsafe_offset=Int(node_idx)]

    match node.kind:
        case .String:
            var raw = Span[Byte, origin](
                unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            bw.put_lit['{"type": "string", "value": "']()
            _put_toml_string_bytes[mode](raw, node.flags, bw)
            bw.put_lit['"}']()
        case .Integer:
            bw.put_lit['{"type": "integer", "value": "']()
            comptime if case .Eager = mode:
                bw.put_int(_eager_int(node))
            else:
                var r_ptr = doc_ptr.unsafe_offset(Int(node.start))
                var r_len = Int(node.len)
                comptime if case .Strict = mode:
                    if (node.flags & NodeFlags.CANONICAL) != 0:
                        var first = r_ptr[unsafe_offset=0]
                        if first == Byte(ord("+")):
                            bw.put_bytes(r_ptr.unsafe_offset(1), r_len - 1)
                            bw.put_lit['"}']()
                            return
                        if not (
                            r_len == 2
                            and first == Byte(ord("-"))
                            and r_ptr[unsafe_offset=1] == Byte(ord("0"))
                        ):
                            bw.put_bytes(r_ptr, r_len)
                            bw.put_lit['"}']()
                            return
                    bw.put_int(
                        decode_int_unchecked(
                            Span[Byte, origin](unsafe_ptr=r_ptr, length=r_len),
                            node.flags,
                        )
                    )
                else:
                    bw.put_int(
                        decode_int(
                            Span[Byte, origin](unsafe_ptr=r_ptr, length=r_len)
                        ).take()
                    )
            bw.put_lit['"}']()
        case .Float:
            bw.put_lit['{"type": "float", "value": "']()
            comptime if case .Eager = mode:
                bw.write(_eager_float(node))
            else:
                var r_ptr = doc_ptr.unsafe_offset(Int(node.start))
                var r_len = Int(node.len)
                var raw = Span[Byte, origin](unsafe_ptr=r_ptr, length=r_len)
                comptime if case .Strict = mode:
                    var trim_plus = 0
                    if _is_exact_canonical_float_repr(
                        r_ptr, r_len, node.flags, trim_plus
                    ):
                        bw.put_bytes(
                            r_ptr.unsafe_offset(trim_plus), r_len - trim_plus
                        )
                    else:
                        bw.write(decode_float_unchecked(raw, node.flags))
                else:
                    bw.write(decode_float(raw).take())
            bw.put_lit['"}']()
        case .NaN:
            bw.put_lit['{"type": "float", "value": "nan"}']()
        case .Inf:
            comptime if case .Eager = mode:
                if _eager_float(node) < 0.0:
                    bw.put_lit['{"type": "float", "value": "-inf"}']()
                else:
                    bw.put_lit['{"type": "float", "value": "inf"}']()
            else:
                if node.len > 0 and doc_ptr[
                    unsafe_offset=Int(node.start)
                ] == Byte(ord("-")):
                    bw.put_lit['{"type": "float", "value": "-inf"}']()
                else:
                    bw.put_lit['{"type": "float", "value": "inf"}']()
        case .Boolean:
            var bval: Bool
            comptime match mode:
                case .Eager:
                    bval = node.start != 0
                case .Strict:
                    bval = doc_ptr[unsafe_offset=Int(node.start)] == Byte(
                        ord("t")
                    )
                case .Trusted:
                    bval = decode_bool(
                        Span[Byte, origin](
                            unsafe_ptr=doc_ptr.unsafe_offset(Int(node.start)),
                            length=Int(node.len),
                        )
                    ).take()
            if bval:
                bw.put_lit['{"type": "bool", "value": "true"}']()
            else:
                bw.put_lit['{"type": "bool", "value": "false"}']()
        case .Date:
            bw.put_lit['{"type": "date-local", "value": "']()
            comptime if case .Eager = mode:
                bw.ensure(10)
                bw.pos = _format_date_buf(
                    _eager_date(node), bw.buf.unsafe_ptr(), bw.pos
                )
            else:
                var r_ptr = doc_ptr.unsafe_offset(Int(node.start))
                var r_len = Int(node.len)
                comptime if case .Trusted = mode:
                    _ = decode_date(
                        Span[Byte, origin](unsafe_ptr=r_ptr, length=r_len)
                    ).take()
                bw.put_bytes(r_ptr, r_len)
            bw.put_lit['"}']()
        case .Time:
            bw.put_lit['{"type": "time-local", "value": "']()
            comptime if case .Eager = mode:
                bw.ensure(24)
                bw.pos = _format_time_buf(
                    store_ptr[].temporals[Int(node.start)].time,
                    bw.buf.unsafe_ptr(),
                    bw.pos,
                )
            else:
                var r_ptr = doc_ptr.unsafe_offset(Int(node.start))
                var r_len = Int(node.len)
                var raw = Span[Byte, origin](unsafe_ptr=r_ptr, length=r_len)
                comptime if case .Strict = mode:
                    if r_len == 8 and r_ptr[unsafe_offset=5] == Byte(ord(":")):
                        bw.put_bytes(r_ptr, 8)
                    else:
                        bw.ensure(24)
                        bw.pos = _format_time_buf(
                            decode_time_unchecked(raw),
                            bw.buf.unsafe_ptr(),
                            bw.pos,
                        )
                else:
                    bw.ensure(24)
                    bw.pos = _format_time_buf(
                        decode_time(raw).take(), bw.buf.unsafe_ptr(), bw.pos
                    )
            bw.put_lit['"}']()
        case .DateTime:
            comptime if case .Strict = mode:
                var r_ptr = doc_ptr.unsafe_offset(Int(node.start))
                var r_len = Int(node.len)
                if (
                    r_len == 20
                    and r_ptr[unsafe_offset=10] == Byte(ord("T"))
                    and r_ptr[unsafe_offset=16] == Byte(ord(":"))
                    and r_ptr[unsafe_offset=19] == Byte(ord("Z"))
                ):
                    bw.put_lit['{"type": "datetime", "value": "']()
                    bw.put_bytes(r_ptr, 20)
                    bw.put_lit['"}']()
                    return

            var dt: DateTime
            comptime match mode:
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
            if dt.is_local:
                bw.put_lit['{"type": "datetime-local", "value": "']()
            else:
                bw.put_lit['{"type": "datetime", "value": "']()
            bw.ensure(40)
            bw.pos = _format_datetime_buf(dt, bw.buf.unsafe_ptr(), bw.pos)
            bw.put_lit['"}']()
        case .Array:
            bw.put_byte(Byte(ord("[")))
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    bw.put_2bytes(Byte(ord(",")), Byte(ord(" ")))
                first = False
                _write_node_as_json_buf[mode](
                    doc_ptr, nodes_ptr, store_ptr, curr, bw
                )
                curr = nodes_ptr[unsafe_offset=Int(curr)].next_sibling
            bw.put_byte(Byte(ord("]")))
        case .Table:
            bw.put_byte(Byte(ord("{")))
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    bw.put_2bytes(Byte(ord(",")), Byte(ord(" ")))
                first = False
                ref child_node = nodes_ptr[unsafe_offset=Int(curr)]
                bw.put_byte(Byte(ord('"')))
                var k_span = Span[Byte, origin](
                    unsafe_ptr=doc_ptr.unsafe_offset(Int(child_node.key_start)),
                    length=Int(child_node.key_len),
                )
                _put_toml_string_bytes[mode](k_span, child_node.key_flags, bw)
                bw.put_lit['": ']()
                _write_node_as_json_buf[mode](
                    doc_ptr, nodes_ptr, store_ptr, curr, bw
                )
                curr = child_node.next_sibling
            bw.put_byte(Byte(ord("}")))
        case .Empty:
            pass


def _write_node_as_json[
    mode: Mode, origin: ImmOrigin, W: Writer
](
    doc_ptr: Pointer[Byte, origin],
    nodes_ptr: Pointer[Node, origin],
    store_ptr: Pointer[_Store, origin],
    node_idx: UInt32,
    mut w: W,
) raises:
    """Stream a tape node and its subtree as `toml-test` tagged JSON via a 4 KB stack buffer.
    """
    var bw = _JsonBufWriter[W, origin_of(w)](w)
    _write_node_as_json_buf[mode](doc_ptr, nodes_ptr, store_ptr, node_idx, bw)
    bw.flush()
