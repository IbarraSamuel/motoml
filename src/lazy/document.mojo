"""Lazy Document and Value views over the node tape.
"""

from .node import Node, Kind, NodeFlags, NO_NODE
from .key_index import KeyIndex
from .validation import Validation, validation_level
from .scalar_decode import (
    decode_int,
    decode_int_unchecked,
    decode_float,
    decode_float_unchecked,
    decode_bool,
    decode_bool_unchecked,
    decode_date,
    decode_date_unchecked,
    decode_time,
    decode_time_unchecked,
    decode_datetime,
    decode_datetime_unchecked,
    decode_string,
    decode_string_unchecked,
    decode_string_to_writer,
    decode_string_to_writer_unchecked,
)
from ..types.tempo import Date, Time, DateTime
from ..types.toml import Toml
from ..result import Result, ScalarResult
from std.collections import Span, Dict, List
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
            w.write(StringSlice(unsafe_from_utf8=bytes[chunk_start:i]))
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
                StringSlice(
                    unsafe_from_utf8=hex[Int(esc_b >> 4) : Int(esc_b >> 4) + 1]
                ),
                StringSlice(
                    unsafe_from_utf8=hex[
                        Int(esc_b & 0x0F) : Int(esc_b & 0x0F) + 1
                    ]
                ),
            )
        i += 1


struct _JsonEscapeWriter[w_origin: MutOrigin, W: Writer](Writer):
    """Streaming Writer adapter that JSON-escapes chunks on the fly without allocating.
    """

    var w: Pointer[Self.W, Self.w_origin]

    @always_inline
    def __init__(out self, w: Pointer[Self.W, Self.w_origin]):
        self.w = w

    @always_inline
    def write_string(mut self, string: StringSlice):
        _write_json_escaped_bytes(string.as_bytes(), self.w[])


struct ValueIter[origin: ImmOrigin, validation: Validation = Validation.Strict](
    Copyable, ImplicitlyCopyable, Movable, Sized, TrivialRegisterPassable
):
    """O(1)-step iterator over the children of a Table or Array `Value`."""

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var key_index_ptr: Pointer[KeyIndex, Self.origin]
    var curr_idx: UInt32
    var remaining: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        key_index_ptr: Pointer[KeyIndex, Self.origin],
        curr_idx: UInt32,
        remaining: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.key_index_ptr = key_index_ptr
        self.curr_idx = curr_idx
        self.remaining = remaining

    @always_inline
    def __iter__(self) -> Self:
        return self

    @always_inline
    def __len__(self) -> Int:
        return Int(self.remaining)

    @always_inline
    def __has_next__(self) -> Bool:
        return self.curr_idx != NO_NODE

    @always_inline
    def __next__(
        mut self,
    ) raises StopIteration -> Value[Self.origin, Self.validation]:
        if self.curr_idx == NO_NODE:
            raise StopIteration()
        var idx = self.curr_idx
        self.curr_idx = self.nodes_ptr[unsafe_offset=Int(idx)].next_sibling
        self.remaining -= 1
        return Value[Self.origin, Self.validation](
            self.doc_ptr,
            self.nodes_ptr,
            self.key_index_ptr,
            idx,
        )


struct Value[origin: ImmOrigin, validation: Validation = Validation.Strict](
    Boolable,
    Copyable,
    ImplicitlyCopyable,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """A borrowed, 32-byte register-passable view of a parsed TOML node on the tape.

    Provides lazy evaluation for scalars (decoded on demand) and structural
    access (indexing tables by key and arrays by index) directly against
    the document buffer without `Optional` or `Result` heap/stack overhead.
    """

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var key_index_ptr: Pointer[KeyIndex, Self.origin]
    var node_idx: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        key_index_ptr: Pointer[KeyIndex, Self.origin],
        node_idx: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.key_index_ptr = key_index_ptr
        self.node_idx = node_idx

    @always_inline
    def __bool__(self) -> Bool:
        """Return `True` if this `Value` points to a valid node (`node_idx != NO_NODE`).
        """
        return self.node_idx != NO_NODE

    @always_inline
    def value(self) -> Self:
        """Return `self` (zero-cost compatibility helper for `Optional`-style `.value()`).
        """
        return self

    @always_inline
    def _node(self) -> ref[self.origin] Node:
        """Borrow the underlying tape `Node` for this value."""
        return self.nodes_ptr[unsafe_offset=Int(self.node_idx)]

    @always_inline
    def kind(self) -> Kind:
        """Return the `Kind` constant of this value (`Kind.Empty` if not found).
        """
        if self.node_idx == NO_NODE:
            return Kind.Empty
        return self._node().kind

    @always_inline
    def is_table(self) -> Bool:
        """Return `True` if this value represents a table."""
        return self.kind() == Kind.Table

    @always_inline
    def is_array(self) -> Bool:
        """Return `True` if this value represents an array."""
        return self.kind() == Kind.Array

    @always_inline
    def is_string(self) -> Bool:
        """Return `True` if this value represents a string."""
        return self.kind() == Kind.String

    @always_inline
    def is_int(self) -> Bool:
        """Return `True` if this value represents an integer."""
        return self.kind() == Kind.Integer

    @always_inline
    def is_float(self) -> Bool:
        """Return `True` if this value represents a float."""
        return self.kind() == Kind.Float

    @always_inline
    def is_bool(self) -> Bool:
        """Return `True` if this value represents a boolean."""
        return self.kind() == Kind.Boolean

    @always_inline
    def key_bytes(self) -> Span[Byte, self.origin]:
        """Return the raw borrowed byte span of this value's key within the document.
        """
        ref node = self._node()
        return Span[Byte, self.origin](
            unsafe_ptr=self.doc_ptr.unsafe_offset(Int(node.key_start)),
            length=Int(node.key_len),
        )

    @always_inline
    def key_slice(self) -> StringSlice[self.origin]:
        """Return a string slice view of this value's key."""
        return StringSlice(unsafe_from_utf8=self.key_bytes())

    @always_inline
    def raw_bytes(self) -> Span[Byte, self.origin]:
        """Return the raw borrowed byte span of this value within the document.
        """
        ref node = self._node()
        return Span[Byte, self.origin](
            unsafe_ptr=self.doc_ptr.unsafe_offset(Int(node.start)),
            length=Int(node.len),
        )

    @always_inline
    def as_slice(self) -> Optional[StringSlice[self.origin]]:
        """Return a zero-copy string slice if this value is an unescaped string.
        """
        if self.node_idx == NO_NODE:
            return None
        ref node = self._node()
        if (node.flags & NodeFlags.HAS_ESCAPE) == 0:
            return StringSlice(unsafe_from_utf8=self.raw_bytes())
        return None

    @always_inline
    def as_string(self) -> Result[String]:
        """Decode and return this value as an owned `String`, resolving escapes.
        """
        if self.node_idx == NO_NODE:
            return .Err("Missing value.")
        ref node = self._node()
        comptime if validation_level(Self.validation) >= 2:
            if node.kind == Kind.String:
                return .Ok(
                    decode_string_unchecked(self.raw_bytes(), node.flags)
                )
        return decode_string(self.raw_bytes(), node.flags)

    @always_inline
    def as_int(self) -> ScalarResult[Int]:
        """Decode and return this value as an integer (`Int`) in registers."""
        if self.node_idx == NO_NODE:
            return ScalarResult[Int](0, False)
        comptime if validation_level(Self.validation) >= 2:
            ref node = self._node()
            if node.kind == Kind.Integer:
                return ScalarResult[Int](
                    decode_int_unchecked(self.raw_bytes(), node.flags), True
                )
        return decode_int(self.raw_bytes())

    @always_inline
    def as_float(self) -> ScalarResult[Float64]:
        """Decode and return this value as a 64-bit float (`Float64`) in registers.
        """
        if self.node_idx == NO_NODE:
            return ScalarResult[Float64](0.0, False)
        comptime if validation_level(Self.validation) >= 2:
            ref node = self._node()
            if (
                node.kind == Kind.Float
                or node.kind == Kind.NaN
                or node.kind == Kind.Inf
            ):
                return ScalarResult[Float64](
                    decode_float_unchecked(self.raw_bytes(), node.flags), True
                )
        return decode_float(self.raw_bytes())

    @always_inline
    def as_bool(self) -> ScalarResult[Bool]:
        """Decode and return this value as a boolean (`Bool`) in registers."""
        if self.node_idx == NO_NODE:
            return ScalarResult[Bool](False, False)
        comptime if validation_level(Self.validation) >= 2:
            ref node = self._node()
            if node.kind == Kind.Boolean:
                return ScalarResult[Bool](
                    decode_bool_unchecked(self.raw_bytes()), True
                )
        return decode_bool(self.raw_bytes())

    @always_inline
    def as_date(self) -> ScalarResult[Date]:
        """Decode and return this value as a local date (`Date`) in registers.
        """
        if self.node_idx == NO_NODE:
            return ScalarResult[Date](Date(year=0, month=0, day=0), False)
        comptime if validation_level(Self.validation) >= 2:
            ref node = self._node()
            if node.kind == Kind.Date:
                return ScalarResult[Date](
                    decode_date_unchecked(self.raw_bytes()), True
                )
        return decode_date(self.raw_bytes())

    @always_inline
    def as_time(self) -> ScalarResult[Time]:
        """Decode and return this value as a local time (`Time`) in registers.
        """
        if self.node_idx == NO_NODE:
            return ScalarResult[Time](Time(hour=0, minute=0, second=0.0), False)
        comptime if validation_level(Self.validation) >= 2:
            ref node = self._node()
            if node.kind == Kind.Time:
                return ScalarResult[Time](
                    decode_time_unchecked(self.raw_bytes()), True
                )
        return decode_time(self.raw_bytes())

    @always_inline
    def as_datetime(self) -> ScalarResult[DateTime]:
        """Decode and return this value as a date-time (`DateTime`) in registers.
        """
        if self.node_idx == NO_NODE:
            return ScalarResult[DateTime](
                DateTime(
                    Date(year=0, month=0, day=0),
                    Time(hour=0, minute=0, second=0.0),
                    {},
                    True,
                ),
                False,
            )
        comptime if validation_level(Self.validation) >= 2:
            ref node = self._node()
            if node.kind == Kind.DateTime:
                return ScalarResult[DateTime](
                    decode_datetime_unchecked(self.raw_bytes()), True
                )
        return decode_datetime(self.raw_bytes())

    @always_inline
    def int(self) -> Int:
        """Direct unchecked integer decode for validated documents."""
        return decode_int_unchecked(self.raw_bytes(), self._node().flags)

    @always_inline
    def float(self) -> Float64:
        """Direct unchecked float decode for validated documents."""
        return decode_float_unchecked(self.raw_bytes(), self._node().flags)

    @always_inline
    def bool(self) -> Bool:
        """Direct unchecked boolean decode for validated documents."""
        return decode_bool_unchecked(self.raw_bytes())

    @always_inline
    def date(self) -> Date:
        """Direct unchecked date decode for validated documents."""
        return decode_date_unchecked(self.raw_bytes())

    @always_inline
    def time(self) -> Time:
        """Direct unchecked time decode for validated documents."""
        return decode_time_unchecked(self.raw_bytes())

    @always_inline
    def datetime(self) -> DateTime:
        """Direct unchecked datetime decode for validated documents."""
        return decode_datetime_unchecked(self.raw_bytes())

    @always_inline
    def string(self) -> String:
        """Direct unchecked string decode for validated documents."""
        return decode_string_unchecked(self.raw_bytes(), self._node().flags)

    @always_inline
    def children(self) -> ValueIter[Self.origin, Self.validation]:
        """Return an O(1)-step iterator over the children of this table or array.
        """
        if self.node_idx == NO_NODE:
            return ValueIter[Self.origin, Self.validation](
                self.doc_ptr,
                self.nodes_ptr,
                self.key_index_ptr,
                NO_NODE,
                0,
            )
        ref node = self._node()
        if node.kind != Kind.Table and node.kind != Kind.Array:
            return ValueIter[Self.origin, Self.validation](
                self.doc_ptr,
                self.nodes_ptr,
                self.key_index_ptr,
                NO_NODE,
                0,
            )
        return ValueIter[Self.origin, Self.validation](
            self.doc_ptr,
            self.nodes_ptr,
            self.key_index_ptr,
            node.first_child,
            node.len,
        )

    @always_inline
    def __getitem__(self, key: StringSlice) -> Self:
        """Look up a child value by key in O(1) time if this value is a table.
        """
        if self.node_idx == NO_NODE:
            return self
        ref node = self._node()
        if node.kind != Kind.Table:
            return Self(
                self.doc_ptr, self.nodes_ptr, self.key_index_ptr, NO_NODE
            )

        var key_b = key.as_bytes()
        var child_idx = self.key_index_ptr[].find_by_bytes(
            self.node_idx, key_b, self.nodes_ptr, self.doc_ptr
        )
        return Self(
            self.doc_ptr,
            self.nodes_ptr,
            self.key_index_ptr,
            child_idx,
        )

    @always_inline
    def __getitem__(self, index: Int) -> Self:
        """Look up an element by zero-based index if this value is an array."""
        if self.node_idx == NO_NODE:
            return self
        ref node = self._node()
        if node.kind != Kind.Array or index < 0 or index >= Int(node.len):
            return Self(
                self.doc_ptr, self.nodes_ptr, self.key_index_ptr, NO_NODE
            )

        var curr = node.first_child
        var i = 0
        while curr != NO_NODE:
            if i == index:
                return Self(
                    self.doc_ptr,
                    self.nodes_ptr,
                    self.key_index_ptr,
                    curr,
                )
            curr = self.nodes_ptr[unsafe_offset=Int(curr)].next_sibling
            i += 1
        return Self(self.doc_ptr, self.nodes_ptr, self.key_index_ptr, NO_NODE)

    @always_inline
    def __len__(self) -> Int:
        """Return the number of children in O(1) time."""
        if self.node_idx == NO_NODE:
            return 0
        ref node = self._node()
        if node.kind == Kind.Table or node.kind == Kind.Array:
            return Int(node.len)
        return 0

    def to_json[W: Writer](self, mut w: W) raises:
        """Stream this value and all its children as JSON to a writer with zero string allocations.
        """
        ref node = self._node()
        var k = node.kind
        if k == Kind.String:
            w.write('{"type": "string", "value": "')
            if (node.flags & NodeFlags.LITERAL) != 0 or (
                node.flags & NodeFlags.HAS_ESCAPE
            ) == 0:
                _write_json_escaped_bytes(self.raw_bytes(), w)
            else:
                var adapter = _JsonEscapeWriter(Pointer(to=w))
                comptime if validation_level(Self.validation) >= 2:
                    decode_string_to_writer_unchecked(
                        self.raw_bytes(), node.flags, adapter
                    )
                else:
                    var res = decode_string_to_writer(
                        self.raw_bytes(), node.flags, adapter
                    )
                    if case .Err = res:
                        raise Error(res^.unsafe_take_error())
                    _ = res^.unsafe_take_value()
            w.write('"}')
        elif k == Kind.Integer:
            comptime if validation_level(Self.validation) >= 2:
                var raw_b = self.raw_bytes()
                if (node.flags & NodeFlags.CANONICAL) != 0:
                    var first = raw_b.unsafe_ptr()[unsafe_offset=0]
                    if first != Byte(ord("+")) and not (
                        len(raw_b) == 2
                        and first == Byte(ord("-"))
                        and raw_b.unsafe_ptr()[unsafe_offset=1]
                        == Byte(ord("0"))
                    ):
                        w.write(
                            '{"type": "integer", "value": "',
                            StringSlice(unsafe_from_utf8=raw_b),
                            '"}',
                        )
                        return
                w.write(
                    '{"type": "integer", "value": "',
                    decode_int_unchecked(raw_b, node.flags),
                    '"}',
                )
            else:
                w.write(
                    '{"type": "integer", "value": "',
                    self.as_int().take(),
                    '"}',
                )
        elif k == Kind.Float:
            comptime if validation_level(Self.validation) >= 2:
                w.write(
                    '{"type": "float", "value": "',
                    decode_float_unchecked(self.raw_bytes(), node.flags),
                    '"}',
                )
            else:
                w.write(
                    '{"type": "float", "value": "',
                    self.as_float().take(),
                    '"}',
                )
        elif k == Kind.NaN:
            w.write('{"type": "float", "value": "nan"}')
        elif k == Kind.Inf:
            var b = self.raw_bytes()
            if len(b) > 0 and b.unsafe_ptr()[unsafe_offset=0] == Byte(ord("-")):
                w.write('{"type": "float", "value": "-inf"}')
            else:
                w.write('{"type": "float", "value": "inf"}')
        elif k == Kind.Boolean:
            comptime if validation_level(Self.validation) >= 2:
                w.write(
                    '{"type": "bool", "value": "',
                    "true" if decode_bool_unchecked(
                        self.raw_bytes()
                    ) else "false",
                    '"}',
                )
            else:
                w.write(
                    '{"type": "bool", "value": "',
                    "true" if self.as_bool().take() else "false",
                    '"}',
                )
        elif k == Kind.Date:
            comptime if validation_level(Self.validation) < 2:
                _ = self.as_date().take()
            w.write(
                '{"type": "date-local", "value": "',
                StringSlice(unsafe_from_utf8=self.raw_bytes()),
                '"}',
            )
        elif k == Kind.Time:
            comptime if validation_level(Self.validation) >= 2:
                w.write(
                    '{"type": "time-local", "value": "',
                    decode_time_unchecked(self.raw_bytes()),
                    '"}',
                )
            else:
                w.write(
                    '{"type": "time-local", "value": "',
                    self.as_time().take(),
                    '"}',
                )
        elif k == Kind.DateTime:
            comptime if validation_level(Self.validation) >= 2:
                var dt = decode_datetime_unchecked(self.raw_bytes())
                var nm = "datetime-local" if dt.is_local else "datetime"
                w.write('{"type": "', nm, '", "value": "', dt, '"}')
            else:
                var dt = self.as_datetime().take()
                var nm = "datetime-local" if dt.is_local else "datetime"
                w.write('{"type": "', nm, '", "value": "', dt, '"}')
        elif k == Kind.Array:
            w.write("[")
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    w.write(", ")
                first = False
                var child_val = Self(
                    self.doc_ptr,
                    self.nodes_ptr,
                    self.key_index_ptr,
                    curr,
                )
                child_val.to_json(w)
                curr = self.nodes_ptr[unsafe_offset=Int(curr)].next_sibling
            w.write("]")
        elif k == Kind.Table:
            w.write("{")
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    w.write(", ")
                first = False
                ref child_node = self.nodes_ptr[unsafe_offset=Int(curr)]
                w.write('"')
                var k_span = Span[Byte, self.origin](
                    unsafe_ptr=self.doc_ptr.unsafe_offset(
                        Int(child_node.key_start)
                    ),
                    length=Int(child_node.key_len),
                )
                if (child_node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
                    var adapter = _JsonEscapeWriter(Pointer(to=w))
                    comptime if validation_level(Self.validation) >= 2:
                        decode_string_to_writer_unchecked(
                            k_span, child_node.key_flags, adapter
                        )
                    else:
                        var dec_res = decode_string_to_writer(
                            k_span, child_node.key_flags, adapter
                        )
                        if case .Err = dec_res:
                            raise Error(dec_res^.unsafe_take_error())
                        _ = dec_res^.unsafe_take_value()
                else:
                    _write_json_escaped_bytes(k_span, w)
                w.write('": ')
                var child_val = Self(
                    self.doc_ptr,
                    self.nodes_ptr,
                    self.key_index_ptr,
                    curr,
                )
                child_val.to_json(w)
                curr = child_node.next_sibling
            w.write("}")

    def to_toml(self) raises -> Toml:
        """Convert this value and its subtree into an eager `Toml` AST object.
        """
        ref node = self._node()
        var k = node.kind
        if k == Kind.String:
            comptime if validation_level(Self.validation) >= 2:
                return Toml.String(
                    decode_string_unchecked(self.raw_bytes(), node.flags)
                )
            else:
                return Toml.String(self.as_string().take())
        elif k == Kind.Integer:
            comptime if validation_level(Self.validation) >= 2:
                return Toml.Integer(
                    decode_int_unchecked(self.raw_bytes(), node.flags)
                )
            else:
                return Toml.Integer(self.as_int().take())
        elif k == Kind.Float or k == Kind.Inf:
            comptime if validation_level(Self.validation) >= 2:
                return Toml.Float(
                    decode_float_unchecked(self.raw_bytes(), node.flags)
                )
            else:
                return Toml.Float(self.as_float().take())
        elif k == Kind.NaN:
            return materialize[Toml.NaN]()
        elif k == Kind.Boolean:
            comptime if validation_level(Self.validation) >= 2:
                return Toml.Boolean(decode_bool_unchecked(self.raw_bytes()))
            else:
                return Toml.Boolean(self.as_bool().take())
        elif k == Kind.Date:
            comptime if validation_level(Self.validation) >= 2:
                return Toml.Date(decode_date_unchecked(self.raw_bytes()))
            else:
                return Toml.Date(self.as_date().take())
        elif k == Kind.Time:
            comptime if validation_level(Self.validation) >= 2:
                return Toml.Time(decode_time_unchecked(self.raw_bytes()))
            else:
                return Toml.Time(self.as_time().take())
        elif k == Kind.DateTime:
            comptime if validation_level(Self.validation) >= 2:
                return Toml.DateTime(
                    decode_datetime_unchecked(self.raw_bytes())
                )
            else:
                return Toml.DateTime(self.as_datetime().take())
        elif k == Kind.Array:
            var list = List[Toml](capacity=Int(node.len))
            var curr = node.first_child
            while curr != NO_NODE:
                var child_val = Self(
                    self.doc_ptr,
                    self.nodes_ptr,
                    self.key_index_ptr,
                    curr,
                )
                list.append(child_val.to_toml())
                curr = self.nodes_ptr[unsafe_offset=Int(curr)].next_sibling
            return Toml.Array(list^)
        elif k == Kind.Table:
            var dict = Dict[String, Toml]()
            var curr = node.first_child
            while curr != NO_NODE:
                ref child_node = self.nodes_ptr[unsafe_offset=Int(curr)]
                var k_span = Span[Byte, self.origin](
                    unsafe_ptr=self.doc_ptr.unsafe_offset(
                        Int(child_node.key_start)
                    ),
                    length=Int(child_node.key_len),
                )
                var key_str: String
                if (child_node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
                    comptime if validation_level(Self.validation) >= 2:
                        key_str = decode_string_unchecked(
                            k_span, child_node.key_flags
                        )
                    else:
                        key_str = decode_string(
                            k_span, child_node.key_flags
                        ).take()
                else:
                    key_str = String(StringSlice(unsafe_from_utf8=k_span))
                var child_val = Self(
                    self.doc_ptr,
                    self.nodes_ptr,
                    self.key_index_ptr,
                    curr,
                )
                dict[key_str] = child_val.to_toml()
                curr = child_node.next_sibling
            return Toml.Table(dict^)
        return Toml.Table(Dict[String, Toml]())


struct Document[origin: ImmOrigin, validation: Validation = Validation.Strict](
    Movable, Sized
):
    """An immutable, zero-allocation parsed TOML document.

    Holds the borrowed source byte span, the flat tape of AST `Node`s, and the
    open-addressing `KeyIndex`.
    """

    var data: Span[Byte, Self.origin]
    var nodes: List[Node]
    var key_index: KeyIndex
    var root_idx: UInt32

    def __init__(
        out self,
        data: Span[Byte, Self.origin],
        var nodes: List[Node],
        var key_index: KeyIndex,
        root_idx: UInt32 = 0,
    ):
        self.data = data
        self.nodes = nodes^
        self.key_index = key_index^
        self.root_idx = root_idx

    @always_inline
    def root(
        ref self,
    ) -> Value[ImmOrigin(origin_of(self)), Self.validation]:
        """Return a `Value` handle representing the root table of the document.
        """
        return Value[ImmOrigin(origin_of(self)), Self.validation](
            self.data.unsafe_ptr().unsafe_origin_cast[
                ImmOrigin(origin_of(self))
            ](),
            Pointer(to=self.nodes[0])
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            Pointer(to=self.key_index)
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            self.root_idx,
        )

    @always_inline
    def __getitem__(
        ref self, key: StringSlice
    ) -> Value[ImmOrigin(origin_of(self)), Self.validation]:
        """Look up a top-level key in the root table."""
        return self.root()[key]

    @always_inline
    def __len__(self) -> Int:
        """Return the number of entries in the root table."""
        return len(self.root())

    def to_json[W: Writer](ref self, mut w: W) raises:
        """Stream the full document formatted as JSON to a writer."""
        self.root().to_json(w)

    def to_toml(ref self) raises -> Toml:
        """Convert the full document into an eager `Toml` AST object."""
        return self.root().to_toml()
