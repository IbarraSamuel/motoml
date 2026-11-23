"""High-throughput compile-time reflection TOML 1.1 serializer (`to_toml`, `write_toml`)."""

from std.bit import count_trailing_zeros
from std.builtin._enum import __Union
from std.builtin.enum_like import EnumLike
from std.builtin.rebind import downcast
from std.builtin.tuple import __TupleLike
from std.builtin.variadics import TypeList
from std.collections import Array, Dict, List, Optional, Set, Span
from std.memory import Pointer, pack_bits
from std.utils import Variant
from std.utils.numerics import isinf, isnan
from ..result import Result
from ..tape.lexer import CC_BARE, _CC_TABLE
from .attr import (
    _effective_case_name,
    _effective_field_name,
    _field_is_flattened,
    _field_is_skipped,
    _field_skip_if_empty,
    _union_content,
    _union_tag,
)
from .json import _HEX_LOWER, _JsonBufWriter
from .reflection import (
    _DictKeyType,
    _DictValType,
    _IsFieldlessEnum,
    _IsValidTomlUnion,
    _VariantConstructible,
    _static_len,
)
from .tempo import (
    Date,
    DateTime,
    Time,
    _DIGIT_PAIRS,
    _format_date_buf,
    _format_datetime_buf,
    _format_time_buf,
)


# --- Low-level TOML string, key, and scalar writers ---


@always_inline
def _put_toml_special_byte[W: Writer](b: Byte, mut bw: _JsonBufWriter[W, _]):
    """Write the TOML 1.1 escape sequence for `\"`, `\\`, `< 0x20`, or `0x7F`.
    """
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
def _put_toml_quoted_bytes[
    W: Writer
](bytes: Span[Byte, _], mut bw: _JsonBufWriter[W, _]):
    """Write `"..."` with SIMD-accelerated TOML 1.1 basic string escaping."""
    bw.put_byte(Byte(ord('"')))
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var i = 0
    comptime W_SIMD = 16

    while i < n:
        var chunk_start = i
        while i + W_SIMD <= n:
            var v = ptr.unsafe_load[width=W_SIMD](i)
            var stop = (
                v.eq(Byte(ord('"')))
                | v.eq(Byte(ord("\\")))
                | v.lt(0x20)
                | v.eq(0x7F)
            )
            if not any(stop):
                i += W_SIMD
                continue
            i += Int(count_trailing_zeros(pack_bits(stop)))
            break
        while i < n:
            var b = ptr[unsafe_offset=i]
            if (
                b == Byte(ord('"'))
                or b == Byte(ord("\\"))
                or b < 0x20
                or b == 0x7F
            ):
                break
            i += 1
        if i > chunk_start:
            bw.put_bytes(ptr.unsafe_offset(chunk_start), i - chunk_start)
        if i >= n:
            break
        _put_toml_special_byte(ptr[unsafe_offset=i], bw)
        i += 1

    bw.put_byte(Byte(ord('"')))


@always_inline
def _is_bare_toml_key(bytes: Span[Byte, _]) -> Bool:
    var n = len(bytes)
    if n == 0:
        return False
    var cc_ptr = _CC_TABLE.unsafe_ptr()
    var ptr = bytes.unsafe_ptr()
    for i in range(n):
        if (cc_ptr[unsafe_offset=Int(ptr[unsafe_offset=i])] & CC_BARE) == 0:
            return False
    return True


@always_inline
def _put_toml_key[W: Writer](key: StringSpan, mut bw: _JsonBufWriter[W, _]):
    """Write `key` as a bare TOML key if `[A-Za-z0-9_-]+`, otherwise quoted."""
    var kb = key.as_bytes()
    if _is_bare_toml_key(kb):
        bw.put_bytes(kb.unsafe_ptr(), len(kb))
    else:
        _put_toml_quoted_bytes(kb, bw)


def _put_section_header[
    W: Writer
](
    path: List[String],
    leaf: StringSpan,
    is_aot: Bool,
    mut bw: _JsonBufWriter[W, _],
    mut need_blank_line: Bool,
):
    if need_blank_line:
        bw.put_byte(Byte(ord("\n")))
    need_blank_line = True
    if is_aot:
        bw.put_lit["[["]()
    else:
        bw.put_byte(Byte(ord("[")))
    for i in range(len(path)):
        if i > 0:
            bw.put_byte(Byte(ord(".")))
        _put_toml_key(StringSpan(path[i]), bw)
    if len(path) > 0:
        bw.put_byte(Byte(ord(".")))
    _put_toml_key(leaf, bw)
    if is_aot:
        bw.put_lit["]]\n"]()
    else:
        bw.put_lit["]\n"]()


@always_inline
def _put_toml_float[W: Writer](val: Float64, mut bw: _JsonBufWriter[W, _]):
    if isnan(val):
        bw.put_lit["nan"]()
        return
    if isinf(val):
        if val < 0.0:
            bw.put_lit["-inf"]()
        else:
            bw.put_lit["inf"]()
        return
    var s = String(val)
    bw.write_string(StringSpan(s))
    var sb = s.as_bytes()
    var has_dot_or_exp = False
    for i in range(len(sb)):
        var b = sb[i]
        if b == Byte(ord(".")) or b == Byte(ord("e")) or b == Byte(ord("E")):
            has_dot_or_exp = True
            break
    if not has_dot_or_exp:
        bw.put_lit[".0"]()


# --- Compile-time type classification for TOML layout ---


def _is_scalar_or_inline_type[T: AnyType]() -> Bool:
    """Return True if `T` serializes inline (`key = val`) rather than as a `[section]`.
    """
    comptime Tr = reflect[T]
    comptime if (
        T == String
        or T == StaticString
        or Tr.base_name() == "StringSpan"
        or T == Int
        or T == Int64
        or T == Int32
        or T == Int16
        or T == Int8
        or T == UInt
        or T == UInt64
        or T == UInt32
        or T == UInt16
        or T == UInt8
        or T == Float64
        or T == Float32
        or T == Bool
        or T == Date
        or T == Time
        or T == DateTime
        or _IsFieldlessEnum[T]
        or conforms_to(T, __Union)
        or conforms_to(T, _VariantConstructible)
        or conforms_to(T, __TupleLike)
        or Tr.base_name() == "Array"
        or Tr.base_name() == "Set"
    ):
        return True
    elif Tr.base_name() == "Optional":
        comptime assert conforms_to(T, Iterable)
        comptime Inner = T.IteratorType[origin_of()].Element
        return _is_scalar_or_inline_type[Inner]()
    elif Tr.base_name() == "List":
        comptime assert conforms_to(T, Iterable)
        comptime Elem = T.IteratorType[origin_of()].Element
        return not _is_table_section_type[Elem]()
    return False


def _is_table_section_type[T: AnyType]() -> Bool:
    """Return True if `T` is a struct table or `Dict` emitted as `[section]` / `[[aot]]`.
    """
    comptime Tr = reflect[T]
    comptime if Tr.base_name() == "Dict":
        return True
    comptime if _is_scalar_or_inline_type[T]():
        return False
    comptime if Tr.base_name() == "Optional" or Tr.base_name() == "List":
        return False
    return Tr.is_struct()


def _is_empty_for_skip[T: AnyType](val: T) -> Bool:
    comptime Tr = reflect[T]
    comptime if Tr.base_name() == "Optional":
        comptime assert conforms_to(T, Boolable)
        return not Bool(val)
    elif (
        T == String
        or T == StaticString
        or Tr.base_name() == "StringSpan"
        or Tr.base_name() == "List"
        or Tr.base_name() == "Dict"
        or Tr.base_name() == "Set"
    ):
        comptime if T == String:
            return rebind[String](val).byte_length() == 0
        elif T == StaticString:
            return rebind[StaticString](val).byte_length() == 0
        elif Tr.base_name() == "StringSpan":
            comptime assert conforms_to(T, Writable)
            var counter = _ByteCounter()
            val.write_to(counter)
            return counter.n == 0
        else:
            comptime assert conforms_to(T, Sized)
            return len(val) == 0
    return False


struct _ByteCounter(Writer):
    var n: Int

    def __init__(out self):
        self.n = 0

    def write_string(mut self, s: StringSpan):
        self.n += s.byte_length()


# --- Inline value writer (`val` on RHS of `=` or inside `[...]`, `{ ... }`) ---


def _write_inline_struct_fields[
    T: AnyType, W: Writer
](val: T, mut bw: _JsonBufWriter[W, _], mut first: Bool,) raises:
    comptime r = reflect[T]
    comptime types = r.field_types()
    comptime count = r.field_count()

    comptime for fi in range(count):
        comptime if not _field_is_skipped[T, fi]():
            comptime FT = types[fi]
            ref fval = r.field_ref[fi](val)
            comptime if _field_skip_if_empty[T, fi]():
                if _is_empty_for_skip(fval):
                    continue
            comptime if _field_is_flattened[T, fi]():
                comptime if reflect[FT].base_name() == "Dict":
                    _write_inline_dict_entries(fval, bw, first)
                else:
                    _write_inline_struct_fields(fval, bw, first)
            elif reflect[FT].base_name() == "Optional":
                _write_optional_inline_kv[_effective_field_name[T, fi]()](
                    fval, bw, first
                )
            else:
                if not first:
                    bw.put_lit[", "]()
                first = False
                comptime KEY = _effective_field_name[T, fi]()
                var key_s: StaticString = materialize[KEY]()
                _put_toml_key(StringSpan(key_s), bw)
                bw.put_lit[" = "]()
                _write_inline_value(fval, bw)


def _write_optional_inline_kv[
    key: StaticString, OptT: AnyType, W: Writer
](opt_val: OptT, mut bw: _JsonBufWriter[W, _], mut first: Bool,) raises:
    comptime assert conforms_to(OptT, Boolable & EnumLike)
    if not Bool(opt_val):
        return
    if not first:
        bw.put_lit[", "]()
    first = False
    var key_s: StaticString = materialize[key]()
    _put_toml_key(StringSpan(key_s), bw)
    bw.put_lit[" = "]()
    ref payload_tup = opt_val._unsafe_get_enum_payload[1]()
    comptime assert conforms_to(type_of(payload_tup), __TupleLike)
    _write_inline_value(payload_tup[0], bw)


def _format_dict_key_to_string[K: AnyType](k: K) raises -> String:
    comptime if K == String:
        return rebind[String](k).copy()
    elif K == StaticString:
        return String(rebind[StaticString](k))
    elif reflect[K].base_name() == "StringSpan":
        comptime assert conforms_to(K, Writable)
        return String(k)
    elif _IsFieldlessEnum[K]:
        comptime E = downcast[K, EnumLike]
        var disc = rebind[E](k)._get_enum_discriminant()
        comptime cases = TypeList[Trait=AnyType, E._enum_case_types]()
        comptime for ci in range(cases.length):
            if disc == ci:
                comptime CNAME = _effective_case_name[E, ci]()
                return String(materialize[CNAME]())
        raise Error("Invalid enum discriminant in Dict key.")
    else:
        raise Error(
            t"Unsupported Dict key type {reflect[K].name()} for TOML"
            t" serialization."
        )


def _write_inline_dict_entries[
    DictT: AnyType, W: Writer
](d: DictT, mut bw: _JsonBufWriter[W, _], mut first: Bool,) raises:
    comptime assert conforms_to(DictT, Iterable)
    comptime K = _DictKeyType[DictT]
    comptime VT = _DictValType[DictT]
    comptime assert conforms_to(K, KeyElement & Deinitable)
    comptime assert conforms_to(VT, Movable & Deinitable)
    ref typed_d = rebind[Dict[K, VT]](d)
    for entry in typed_d.items():
        ref k = entry.key
        ref v = entry.value
        comptime if reflect[VT].base_name() == "Optional":
            comptime assert conforms_to(VT, Boolable & EnumLike)
            if not Bool(v):
                continue
            var ks = _format_dict_key_to_string(k)
            if not first:
                bw.put_lit[", "]()
            first = False
            _put_toml_key(StringSpan(ks), bw)
            bw.put_lit[" = "]()
            ref pt = v._unsafe_get_enum_payload[1]()
            comptime assert conforms_to(type_of(pt), __TupleLike)
            _write_inline_value(pt[0], bw)
        else:
            var ks = _format_dict_key_to_string(k)
            if not first:
                bw.put_lit[", "]()
            first = False
            _put_toml_key(StringSpan(ks), bw)
            bw.put_lit[" = "]()
            _write_inline_value(v, bw)


def _write_inline_union[
    E: __Union, W: Writer
](val: E, mut bw: _JsonBufWriter[W, _]) raises:
    comptime assert _IsValidTomlUnion[E], "Invalid union type for TOML."
    comptime cases = TypeList[Trait=AnyType, E._enum_case_types]()
    comptime tag_opt = _union_tag[E]()
    comptime content_opt = _union_content[E]()
    var disc = val._get_enum_discriminant()

    comptime for i in range(cases.length):
        if disc == i:
            comptime CaseTuple = cases[i]
            comptime assert conforms_to(CaseTuple, __TupleLike)
            comptime elts = TypeList[Trait=AnyType, CaseTuple.__element_types]()
            comptime CNAME = _effective_case_name[E, i]()
            var cname_s: StaticString = materialize[CNAME]()
            ref ptup = val._unsafe_get_enum_payload[i]()

            comptime if case .Some(tag_key) = tag_opt:
                var tag_s: StaticString = materialize[tag_key]()
                comptime if case .Some(content_key) = content_opt:
                    # Adjacently tagged: `{ type = "case", value = ... }`
                    bw.put_lit["{ "]()
                    _put_toml_key(StringSpan(tag_s), bw)
                    bw.put_lit[" = "]()
                    _put_toml_quoted_bytes(cname_s.as_bytes(), bw)
                    comptime if elts.length == 1:
                        bw.put_lit[", "]()
                        var cont_s: StaticString = materialize[content_key]()
                        _put_toml_key(StringSpan(cont_s), bw)
                        bw.put_lit[" = "]()
                        _write_inline_value(ptup[0], bw)
                    elif elts.length > 1:
                        bw.put_lit[", "]()
                        var cont_s: StaticString = materialize[content_key]()
                        _put_toml_key(StringSpan(cont_s), bw)
                        bw.put_lit[" = "]()
                        _write_inline_value(ptup, bw)
                    bw.put_lit[" }"]()
                else:
                    # Internally tagged: `{ type = "case", ...fields }`
                    bw.put_lit["{ "]()
                    _put_toml_key(StringSpan(tag_s), bw)
                    bw.put_lit[" = "]()
                    _put_toml_quoted_bytes(cname_s.as_bytes(), bw)
                    var first = False
                    comptime if elts.length == 1:
                        comptime P0 = elts[0]
                        comptime assert (
                            reflect[P0].is_struct()
                            and not _is_scalar_or_inline_type[P0]()
                        ), (
                            "Internally tagged union case payload must be a"
                            " struct or empty; add toml_attr.content(...) for"
                            " scalar/tuple payloads."
                        )
                        _write_inline_struct_fields(ptup[0], bw, first)
                    elif elts.length > 1:
                        comptime assert False, (
                            "Internally tagged union cannot have multi-element"
                            " tuple payloads without toml_attr.content(...)."
                        )
                    bw.put_lit[" }"]()
            else:
                # Default union representation:
                # 0 payloads -> `"case"`
                # 1 payload  -> direct untagged value
                # >=2 payloads -> tuple array `[e0, e1, ...]`
                comptime if elts.length == 0:
                    _put_toml_quoted_bytes(cname_s.as_bytes(), bw)
                elif elts.length == 1:
                    _write_inline_value(ptup[0], bw)
                else:
                    _write_inline_value(ptup, bw)
            return

    raise Error("Invalid union discriminant during TOML serialization.")


def _write_inline_one_of[
    V: _VariantConstructible, W: Writer
](val: V, mut bw: _JsonBufWriter[W, _]) raises:
    comptime r = reflect[V]
    comptime assert r.field_count() == 1
    ref inner_var = r.field_ref[0](val)
    comptime ts = TypeList[Trait=AnyType, V._variant_types]()
    comptime VarT = Variant[*ts]
    ref v_typed = rebind[VarT](inner_var)
    comptime for i in range(ts.length):
        comptime ArmT = ts[i]
        if v_typed.isa[ArmT]():
            _write_inline_value(v_typed[ArmT], bw)
            return
    raise Error("Active OneOf variant arm not found.")


def _write_inline_value[
    T: AnyType, W: Writer
](val: T, mut bw: _JsonBufWriter[W, _]) raises:
    comptime Tr = reflect[T]

    comptime if T == String:
        _put_toml_quoted_bytes(rebind[String](val).as_bytes(), bw)
    elif T == StaticString:
        _put_toml_quoted_bytes(rebind[StaticString](val).as_bytes(), bw)
    elif Tr.base_name() == "StringSpan":
        comptime assert conforms_to(T, Writable)
        var s = String(val)
        _put_toml_quoted_bytes(s.as_bytes(), bw)
    elif T == Int:
        bw.put_int(rebind[Int](val))
    elif T == Int64:
        bw.put_int(Int(rebind[Int64](val)))
    elif T == Int32:
        bw.put_int(Int(rebind[Int32](val)))
    elif T == Int16:
        bw.put_int(Int(rebind[Int16](val)))
    elif T == Int8:
        bw.put_int(Int(rebind[Int8](val)))
    elif T == UInt:
        var u = UInt64(rebind[UInt](val))
        if u > 9223372036854775807:
            raise Error("UInt value exceeds TOML signed 64-bit integer range.")
        bw.put_int(Int(u))
    elif T == UInt64:
        var u = rebind[UInt64](val)
        if u > 9223372036854775807:
            raise Error(
                "UInt64 value exceeds TOML signed 64-bit integer range."
            )
        bw.put_int(Int(u))
    elif T == UInt32:
        bw.put_int(Int(rebind[UInt32](val)))
    elif T == UInt16:
        bw.put_int(Int(rebind[UInt16](val)))
    elif T == UInt8:
        bw.put_int(Int(rebind[UInt8](val)))
    elif T == Float64:
        _put_toml_float(rebind[Float64](val), bw)
    elif T == Float32:
        _put_toml_float(Float64(rebind[Float32](val)), bw)
    elif T == Bool:
        if rebind[Bool](val):
            bw.put_lit["true"]()
        else:
            bw.put_lit["false"]()
    elif T == Date:
        bw.ensure(10)
        bw.pos = _format_date_buf(
            rebind[Date](val), bw.buf.unsafe_ptr(), bw.pos
        )
    elif T == Time:
        bw.ensure(24)
        bw.pos = _format_time_buf(
            rebind[Time](val), bw.buf.unsafe_ptr(), bw.pos
        )
    elif T == DateTime:
        bw.ensure(40)
        bw.pos = _format_datetime_buf(
            rebind[DateTime](val), bw.buf.unsafe_ptr(), bw.pos
        )
    elif _IsFieldlessEnum[T]:
        comptime E = downcast[T, EnumLike]
        var disc = rebind[E](val)._get_enum_discriminant()
        comptime cases = TypeList[Trait=AnyType, E._enum_case_types]()
        comptime for i in range(cases.length):
            if disc == i:
                comptime CNAME = _effective_case_name[E, i]()
                var cs: StaticString = materialize[CNAME]()
                _put_toml_quoted_bytes(cs.as_bytes(), bw)
                return
        raise Error("Invalid enum discriminant during TOML serialization.")
    elif conforms_to(T, _VariantConstructible):
        _write_inline_one_of(val, bw)
    elif conforms_to(T, __Union):
        _write_inline_union(val, bw)
    elif conforms_to(T, __TupleLike):
        comptime Tup = downcast[T, __TupleLike]
        comptime elts = TypeList[Trait=AnyType, Tup.__element_types]()
        ref t_val = rebind[Tup](val)
        bw.put_byte(Byte(ord("[")))
        comptime for i in range(elts.length):
            comptime if i > 0:
                bw.put_lit[", "]()
            _write_inline_value(t_val[i], bw)
        bw.put_byte(Byte(ord("]")))
    elif Tr.base_name() == "Array":
        comptime assert conforms_to(T, Iterable & Movable & Deinitable)
        comptime Elem = T.IteratorType[origin_of()].Element
        comptime N = _static_len[T]()
        var ptr = Pointer(to=val).unsafe_bitcast[Elem]()
        bw.put_byte(Byte(ord("[")))
        for i in range(N):
            if i > 0:
                bw.put_lit[", "]()
            _write_inline_value(ptr[unsafe_offset=i], bw)
        bw.put_byte(Byte(ord("]")))
    elif Tr.base_name() == "List" or Tr.base_name() == "Set":
        comptime assert conforms_to(T, Iterable)
        bw.put_byte(Byte(ord("[")))
        var first = True
        for item in val:
            comptime assert conforms_to(type_of(item), Deinitable)
            if not first:
                bw.put_lit[", "]()
            first = False
            _write_inline_value(item, bw)
        bw.put_byte(Byte(ord("]")))
    elif Tr.base_name() == "Optional":
        comptime assert conforms_to(T, Boolable & EnumLike)
        if not Bool(val):
            raise Error(
                "Cannot serialize None Optional inside a TOML array or bare"
                " value (TOML has no null literal)."
            )
        ref pt = val._unsafe_get_enum_payload[1]()
        comptime assert conforms_to(type_of(pt), __TupleLike)
        _write_inline_value(pt[0], bw)
    elif Tr.base_name() == "Dict":
        bw.put_byte(Byte(ord("{")))
        var first = True
        _write_inline_dict_entries(val, bw, first)
        if not first:
            bw.put_byte(Byte(ord(" ")))
        bw.put_byte(Byte(ord("}")))
    elif Tr.is_struct():
        bw.put_byte(Byte(ord("{")))
        var first = True
        var start_pos = bw.pos
        _write_inline_struct_fields(val, bw, first)
        if not first:
            # Pad `{ k = v }` cleanly; insert leading space? Keep compact `{k = v}` or `{ k = v }`
            _ = start_pos
        bw.put_byte(Byte(ord("}")))
    else:
        raise Error(t"Unsupported type {Tr.name()} for TOML serialization.")


# --- Multi-line two-pass section writer (`[table]` & `[[array_of_tables]]`) ---


def _write_kv_line[
    ValT: AnyType, W: Writer
](key: StringSpan, val: ValT, mut bw: _JsonBufWriter[W, _]) raises:
    _put_toml_key(key, bw)
    bw.put_lit[" = "]()
    _write_inline_value(val, bw)
    bw.put_byte(Byte(ord("\n")))


def _emit_struct_pass1[
    T: AnyType, W: Writer
](
    val: T,
    mut bw: _JsonBufWriter[W, _],
    mut emitted_header: Bool,
    is_root: Bool,
    path: List[String],
    leaf: Optional[String],
    mut need_blank_line: Bool,
) raises:
    """Pass 1: emit inline scalar/array key-value lines before any `[subtable]` sections.
    """
    comptime r = reflect[T]
    comptime types = r.field_types()
    comptime count = r.field_count()

    comptime for fi in range(count):
        comptime if not _field_is_skipped[T, fi]():
            comptime FT = types[fi]
            ref fval = r.field_ref[fi](val)
            comptime if _field_skip_if_empty[T, fi]():
                if _is_empty_for_skip(fval):
                    continue

            comptime if _field_is_flattened[T, fi]():
                comptime if reflect[FT].base_name() == "Dict":
                    _emit_dict_pass1(
                        fval,
                        bw,
                        emitted_header,
                        is_root,
                        path,
                        leaf,
                        need_blank_line,
                    )
                else:
                    _emit_struct_pass1(
                        fval,
                        bw,
                        emitted_header,
                        is_root,
                        path,
                        leaf,
                        need_blank_line,
                    )
            else:
                comptime KEY = _effective_field_name[T, fi]()
                var key_s: StaticString = materialize[KEY]()

                comptime if reflect[FT].base_name() == "Optional":
                    comptime assert conforms_to(
                        FT, Boolable & EnumLike & Iterable
                    )
                    comptime Inner = FT.IteratorType[origin_of()].Element
                    if Bool(fval):
                        ref pt = fval._unsafe_get_enum_payload[1]()
                        comptime assert conforms_to(type_of(pt), __TupleLike)
                        comptime if _is_scalar_or_inline_type[Inner]():
                            _ensure_table_header(
                                is_root,
                                emitted_header,
                                path,
                                leaf,
                                bw,
                                need_blank_line,
                            )
                            _write_kv_line(StringSpan(key_s), pt[0], bw)
                        elif reflect[Inner].base_name() == "List":
                            comptime assert conforms_to(type_of(pt[0]), Sized)
                            if len(pt[0]) == 0:
                                _ensure_table_header(
                                    is_root,
                                    emitted_header,
                                    path,
                                    leaf,
                                    bw,
                                    need_blank_line,
                                )
                                _put_toml_key(StringSpan(key_s), bw)
                                bw.put_lit[" = []\n"]()
                elif _is_scalar_or_inline_type[FT]():
                    _ensure_table_header(
                        is_root,
                        emitted_header,
                        path,
                        leaf,
                        bw,
                        need_blank_line,
                    )
                    _write_kv_line(StringSpan(key_s), fval, bw)
                elif reflect[FT].base_name() == "List":
                    # `List[TableStruct | Dict]`: empty list must be emitted inline as `key = []`!
                    comptime assert conforms_to(FT, Sized)
                    if len(fval) == 0:
                        _ensure_table_header(
                            is_root,
                            emitted_header,
                            path,
                            leaf,
                            bw,
                            need_blank_line,
                        )
                        _put_toml_key(StringSpan(key_s), bw)
                        bw.put_lit[" = []\n"]()


@always_inline
def _ensure_table_header[
    W: Writer
](
    is_root: Bool,
    mut emitted_header: Bool,
    path: List[String],
    leaf: Optional[String],
    mut bw: _JsonBufWriter[W, _],
    mut need_blank_line: Bool,
):
    if not is_root and not emitted_header:
        emitted_header = True
        if case .Some(lf) = leaf:
            _put_section_header(
                path, StringSpan(lf), False, bw, need_blank_line
            )


def _emit_dict_pass1[
    DictT: AnyType, W: Writer
](
    d: DictT,
    mut bw: _JsonBufWriter[W, _],
    mut emitted_header: Bool,
    is_root: Bool,
    path: List[String],
    leaf: Optional[String],
    mut need_blank_line: Bool,
) raises:
    comptime assert conforms_to(DictT, Iterable)
    comptime K = _DictKeyType[DictT]
    comptime VT = _DictValType[DictT]
    comptime assert conforms_to(K, KeyElement & Deinitable)
    comptime assert conforms_to(VT, Movable & Deinitable)
    ref typed_d = rebind[Dict[K, VT]](d)
    for entry in typed_d.items():
        ref k = entry.key
        ref v = entry.value

        comptime if reflect[VT].base_name() == "Optional":
            comptime assert conforms_to(VT, Boolable & EnumLike & Iterable)
            comptime Inner = VT.IteratorType[origin_of()].Element
            if Bool(v):
                ref pt = v._unsafe_get_enum_payload[1]()
                comptime assert conforms_to(type_of(pt), __TupleLike)
                comptime if _is_scalar_or_inline_type[Inner]():
                    _ensure_table_header(
                        is_root, emitted_header, path, leaf, bw, need_blank_line
                    )
                    var ks = _format_dict_key_to_string(k)
                    _write_kv_line(StringSpan(ks), pt[0], bw)
                elif reflect[Inner].base_name() == "List":
                    comptime assert conforms_to(type_of(pt[0]), Sized)
                    if len(pt[0]) == 0:
                        _ensure_table_header(
                            is_root,
                            emitted_header,
                            path,
                            leaf,
                            bw,
                            need_blank_line,
                        )
                        var ks = _format_dict_key_to_string(k)
                        _put_toml_key(StringSpan(ks), bw)
                        bw.put_lit[" = []\n"]()
        elif _is_scalar_or_inline_type[VT]():
            _ensure_table_header(
                is_root, emitted_header, path, leaf, bw, need_blank_line
            )
            var ks = _format_dict_key_to_string(k)
            _write_kv_line(StringSpan(ks), v, bw)
        elif reflect[VT].base_name() == "List":
            comptime assert conforms_to(VT, Sized)
            if len(v) == 0:
                _ensure_table_header(
                    is_root, emitted_header, path, leaf, bw, need_blank_line
                )
                var ks = _format_dict_key_to_string(k)
                _put_toml_key(StringSpan(ks), bw)
                bw.put_lit[" = []\n"]()


def _emit_subtable_or_aot_field[
    FT: AnyType, W: Writer
](
    fval: FT,
    child_path: List[String],
    field_key: String,
    mut bw: _JsonBufWriter[W, _],
    mut emitted_any_sub: Bool,
    mut need_blank_line: Bool,
) raises:
    comptime if _is_table_section_type[FT]():
        emitted_any_sub = True
        _write_table_section(
            fval,
            False,
            child_path,
            Optional(field_key.copy()),
            bw,
            need_blank_line,
        )
    elif reflect[FT].base_name() == "List" and not _is_scalar_or_inline_type[
        FT
    ]():
        comptime assert conforms_to(FT, Iterable & Sized)
        if len(fval) > 0:
            emitted_any_sub = True
            var next_path = child_path.copy()
            next_path.append(field_key.copy())
            for elem in fval:
                comptime assert conforms_to(type_of(elem), Deinitable)
                _put_section_header(
                    child_path, StringSpan(field_key), True, bw, need_blank_line
                )
                _write_aot_element_body(elem, next_path, bw, need_blank_line)


def _emit_struct_pass2[
    T: AnyType, W: Writer
](
    val: T,
    child_path: List[String],
    mut bw: _JsonBufWriter[W, _],
    mut emitted_any_sub: Bool,
    mut need_blank_line: Bool,
) raises:
    """Pass 2: emit `[subtable]` and non-empty `[[array_of_tables]]` sections.
    """
    comptime r = reflect[T]
    comptime types = r.field_types()
    comptime count = r.field_count()

    comptime for fi in range(count):
        comptime if not _field_is_skipped[T, fi]():
            comptime FT = types[fi]
            ref fval = r.field_ref[fi](val)
            comptime if _field_skip_if_empty[T, fi]():
                if _is_empty_for_skip(fval):
                    continue

            comptime if _field_is_flattened[T, fi]():
                comptime if reflect[FT].base_name() == "Dict":
                    _emit_dict_pass2(
                        fval,
                        child_path,
                        bw,
                        emitted_any_sub,
                        need_blank_line,
                    )
                else:
                    _emit_struct_pass2(
                        fval,
                        child_path,
                        bw,
                        emitted_any_sub,
                        need_blank_line,
                    )
            else:
                comptime KEY = _effective_field_name[T, fi]()
                var key_str = String(materialize[KEY]())

                comptime if reflect[FT].base_name() == "Optional":
                    comptime assert conforms_to(
                        FT, Boolable & EnumLike & Iterable
                    )
                    comptime Inner = FT.IteratorType[origin_of()].Element
                    if Bool(fval):
                        ref pt = fval._unsafe_get_enum_payload[1]()
                        comptime assert conforms_to(type_of(pt), __TupleLike)
                        _emit_subtable_or_aot_field(
                            pt[0],
                            child_path,
                            key_str,
                            bw,
                            emitted_any_sub,
                            need_blank_line,
                        )
                else:
                    _emit_subtable_or_aot_field(
                        fval,
                        child_path,
                        key_str,
                        bw,
                        emitted_any_sub,
                        need_blank_line,
                    )


def _emit_dict_pass2[
    DictT: AnyType, W: Writer
](
    d: DictT,
    child_path: List[String],
    mut bw: _JsonBufWriter[W, _],
    mut emitted_any_sub: Bool,
    mut need_blank_line: Bool,
) raises:
    comptime assert conforms_to(DictT, Iterable)
    comptime K = _DictKeyType[DictT]
    comptime VT = _DictValType[DictT]
    comptime assert conforms_to(K, KeyElement & Deinitable)
    comptime assert conforms_to(VT, Movable & Deinitable)
    ref typed_d = rebind[Dict[K, VT]](d)
    for entry in typed_d.items():
        ref k = entry.key
        ref v = entry.value

        comptime if reflect[VT].base_name() == "Optional":
            comptime assert conforms_to(VT, Boolable & EnumLike)
            if Bool(v):
                ref pt = v._unsafe_get_enum_payload[1]()
                comptime assert conforms_to(type_of(pt), __TupleLike)
                var ks = _format_dict_key_to_string(k)
                _emit_subtable_or_aot_field(
                    pt[0],
                    child_path,
                    ks,
                    bw,
                    emitted_any_sub,
                    need_blank_line,
                )
        elif not _is_scalar_or_inline_type[VT]():
            var ks = _format_dict_key_to_string(k)
            _emit_subtable_or_aot_field(
                v,
                child_path,
                ks,
                bw,
                emitted_any_sub,
                need_blank_line,
            )


def _write_aot_element_body[
    ElemT: AnyType, W: Writer
](
    elem: ElemT,
    elem_path: List[String],
    mut bw: _JsonBufWriter[W, _],
    mut need_blank_line: Bool,
) raises:
    var emitted_header = True
    var no_leaf = Optional[String](None)
    comptime if reflect[ElemT].base_name() == "Dict":
        _emit_dict_pass1(
            elem, bw, emitted_header, True, elem_path, no_leaf, need_blank_line
        )
        if bw.pos > 0:
            need_blank_line = True
        var any_sub = False
        _emit_dict_pass2(elem, elem_path, bw, any_sub, need_blank_line)
    else:
        _emit_struct_pass1(
            elem, bw, emitted_header, True, elem_path, no_leaf, need_blank_line
        )
        if bw.pos > 0:
            need_blank_line = True
        var any_sub = False
        _emit_struct_pass2(elem, elem_path, bw, any_sub, need_blank_line)


def _write_table_section[
    T: AnyType, W: Writer
](
    val: T,
    is_root: Bool,
    parent_path: List[String],
    leaf: Optional[String],
    mut bw: _JsonBufWriter[W, _],
    mut need_blank_line: Bool,
) raises:
    var emitted_header = False
    comptime if reflect[T].base_name() == "Dict":
        _emit_dict_pass1(
            val,
            bw,
            emitted_header,
            is_root,
            parent_path,
            leaf,
            need_blank_line,
        )
    else:
        _emit_struct_pass1(
            val,
            bw,
            emitted_header,
            is_root,
            parent_path,
            leaf,
            need_blank_line,
        )

    if is_root and bw.pos > 0:
        need_blank_line = True

    var child_path = parent_path.copy()
    if case .Some(lf) = leaf:
        child_path.append(lf.copy())

    var emitted_any_sub = False
    comptime if reflect[T].base_name() == "Dict":
        _emit_dict_pass2(val, child_path, bw, emitted_any_sub, need_blank_line)
    else:
        _emit_struct_pass2(
            val, child_path, bw, emitted_any_sub, need_blank_line
        )

    # An empty nested struct or empty Dict `{}` must still emit `[section]` so it exists!
    if not is_root and not emitted_header and not emitted_any_sub:
        if case .Some(lf) = leaf:
            _put_section_header(
                parent_path, StringSpan(lf), False, bw, need_blank_line
            )


def _write_root_union[
    E: __Union, W: Writer
](val: E, mut bw: _JsonBufWriter[W, _]) raises:
    comptime assert _IsValidTomlUnion[E], "Invalid union type for TOML."
    comptime cases = TypeList[Trait=AnyType, E._enum_case_types]()
    comptime tag_opt = _union_tag[E]()
    comptime content_opt = _union_content[E]()
    var disc = val._get_enum_discriminant()
    var root_path = List[String]()
    var need_blank = False

    comptime for i in range(cases.length):
        if disc == i:
            comptime CaseTuple = cases[i]
            comptime assert conforms_to(CaseTuple, __TupleLike)
            comptime elts = TypeList[Trait=AnyType, CaseTuple.__element_types]()
            comptime CNAME = _effective_case_name[E, i]()
            var cname_s: StaticString = materialize[CNAME]()
            ref ptup = val._unsafe_get_enum_payload[i]()

            comptime if case .Some(tag_key) = tag_opt:
                var tag_s: StaticString = materialize[tag_key]()
                _put_toml_key(StringSpan(tag_s), bw)
                bw.put_lit[" = "]()
                _put_toml_quoted_bytes(cname_s.as_bytes(), bw)
                bw.put_byte(Byte(ord("\n")))
                need_blank = True
                comptime if case .Some(content_key) = content_opt:
                    var cont_str = String(materialize[content_key]())
                    comptime if elts.length == 1:
                        comptime P0 = elts[0]
                        comptime if _is_table_section_type[P0]():
                            _write_table_section(
                                ptup[0],
                                False,
                                root_path,
                                Optional(cont_str^),
                                bw,
                                need_blank,
                            )
                        else:
                            _write_kv_line(StringSpan(cont_str), ptup[0], bw)
                    elif elts.length > 1:
                        _write_kv_line(StringSpan(cont_str), ptup, bw)
                else:
                    comptime if elts.length == 1:
                        comptime P0 = elts[0]
                        comptime assert _is_table_section_type[P0](), (
                            "Internally tagged root union case payload must be"
                            " a struct or Dict."
                        )
                        _write_table_section(
                            ptup[0], True, root_path, None, bw, need_blank
                        )
                    elif elts.length > 1:
                        comptime assert False, (
                            "Internally tagged union requires"
                            " toml_attr.content(...) for tuple payloads."
                        )
            else:
                comptime if elts.length == 1 and _is_table_section_type[
                    elts[0]
                ]():
                    _write_table_section(
                        ptup[0], True, root_path, None, bw, need_blank
                    )
                else:
                    raise Error(
                        "TOML root document must serialize to a table (struct,"
                        " Dict, or table-valued union)."
                    )
            return

    raise Error("Invalid union discriminant during TOML serialization.")


# --- Public entry points ---


def write_toml[T: AnyType, W: Writer, //](value: T, mut writer: W) raises:
    """Serialize a Mojo struct, `Dict`, or tagged/table `__union` to TOML 1.1 into `writer`.
    """
    var bw = _JsonBufWriter[W, origin_of(writer)](writer)
    var root_path = List[String]()
    var need_blank = False

    comptime if conforms_to(T, __Union):
        _write_root_union(value, bw)
    elif _is_table_section_type[T]():
        _write_table_section(value, True, root_path, None, bw, need_blank)
    else:
        raise Error(
            t"TOML root value must be a struct, Dict, or table-valued __union;"
            t" got {reflect[T].name()}."
        )
    bw.flush()


def to_toml[T: AnyType, //](value: T) raises -> String:
    """Serialize a Mojo struct, `Dict`, or tagged/table `__union` to a TOML 1.1 `String`.
    """
    var out = String()
    write_toml(value, out)
    return out^


def try_to_toml[T: AnyType, //](value: T) -> Result[String]:
    """Non-raising TOML 1.1 serializer returning `Result[String]` (usable at `comptime`).
    """
    try:
        return .Ok(to_toml(value))
    except e:
        return .Err(String(e))
