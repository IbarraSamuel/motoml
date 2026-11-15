"""Unified `Toml` view, typed container views, and `TomlDocument` owner."""

from ..lazy.node import Node, NodeKind, NodeFlags, NO_NODE
from ..lazy.key_index import KeyIndex, KEY_ESCAPE_BIT
from ..lazy.validation import Validation, validation_level
from ..lazy.reader import _ParsedTape
from ..lazy.scalar_decode import (
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
    decode_string_to_writer_unchecked,
    write_toml_string_as_json,
    write_toml_string_as_json_unchecked,
)
from ..mode import _Mode, Mode, _validation_of
from .kind import KindTag, _Kind, Kind
from .tempo import Date, Time, DateTime, Offset
from ..result import Result, ScalarResult
from ..reflection import _destroy_partial_struct
from ..json_write import _write_json_escaped_bytes
from std.collections import Span, List
from std.math import nan
from std.memory import Layout, Pointer, alloc, bitcast, unsafe_memcpy
from std.os import abort


comptime KindPayload[id: Int, o: ImmOrigin, m_id: Int] = TypeList.of[
    String,
    Int,
    Float64,
    Bool,
    Date,
    Time,
    DateTime,
    TomlArray[o, _Mode[m_id]()],
    TomlTable[o, _Mode[m_id]()],
]()[id]


struct _Store(Movable):
    """Shared backing store for `TomlDocument` (lazy uses `key_index` only)."""

    var key_index: KeyIndex
    var arena: List[Byte]
    var array_slots: List[UInt32]
    var temporals: List[DateTime]

    @always_inline
    def __init__(out self, var key_index: KeyIndex):
        self.key_index = key_index^
        self.arena = List[Byte]()
        self.array_slots = List[UInt32]()
        self.temporals = List[DateTime]()

    @always_inline
    def __init__(
        out self,
        var key_index: KeyIndex,
        var arena: List[Byte],
        var array_slots: List[UInt32],
        var temporals: List[DateTime],
    ):
        self.key_index = key_index^
        self.arena = arena^
        self.array_slots = array_slots^
        self.temporals = temporals^


struct _ArenaWriter[origin: MutOrigin](Writer):
    """Non-allocating writer that appends decoded UTF-8 bytes into `arena`."""

    var ptr: Pointer[Byte, Self.origin]
    var pos: Int

    @always_inline
    def __init__(out self, ptr: Pointer[Byte, Self.origin]):
        self.ptr = ptr
        self.pos = 0

    @always_inline
    def write_string(mut self, string: StringSpan):
        var sb = string.as_bytes()
        var n = len(sb)
        if n > 0:
            unsafe_memcpy(
                dest=self.ptr.unsafe_offset(self.pos),
                src=sb.unsafe_ptr(),
                count=n,
            )
            self.pos += n


struct TomlIter[
    mode_id: Int,
    //,
    origin: ImmOrigin,
    mode: _Mode[mode_id] = Mode.Strict,
](
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Iterator,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """O(1)-step iterator over the children of a `Toml`, `TomlTable`, or `TomlArray`.
    """

    comptime Element = Toml[Self.origin, Self.mode]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var store_ptr: Pointer[_Store, Self.origin]
    var curr_idx: UInt32
    var remaining: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        store_ptr: Pointer[_Store, Self.origin],
        curr_idx: UInt32,
        remaining: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.store_ptr = store_ptr
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
    def __next__(mut self) raises StopIteration -> Self.Element:
        if self.curr_idx == NO_NODE:
            raise StopIteration()
        var idx = self.curr_idx
        self.curr_idx = self.nodes_ptr[unsafe_offset=Int(idx)].next_sibling
        self.remaining -= 1
        return Toml[Self.origin, Self.mode](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, idx
        )


struct TomlItemIter[
    mode_id: Int,
    //,
    origin: ImmOrigin,
    mode: _Mode[mode_id] = Mode.Strict,
](
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Iterator,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """Iterator yielding `(key, value)` pairs of a TOML table."""

    comptime Element = Tuple[String, Toml[Self.origin, Self.mode]]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var store_ptr: Pointer[_Store, Self.origin]
    var curr_idx: UInt32
    var remaining: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        store_ptr: Pointer[_Store, Self.origin],
        curr_idx: UInt32,
        remaining: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.store_ptr = store_ptr
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
    def __next__(mut self) raises StopIteration -> Self.Element:
        if self.curr_idx == NO_NODE:
            raise StopIteration()
        var idx = self.curr_idx
        self.curr_idx = self.nodes_ptr[unsafe_offset=Int(idx)].next_sibling
        self.remaining -= 1
        var v = Toml[Self.origin, Self.mode](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, idx
        )
        return (v._decode_key(), v)


struct TomlKeyIter[
    mode_id: Int,
    //,
    origin: ImmOrigin,
    mode: _Mode[mode_id] = Mode.Strict,
](
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Iterator,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """Iterator yielding decoded key strings of a TOML table."""

    comptime Element = String
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var store_ptr: Pointer[_Store, Self.origin]
    var curr_idx: UInt32
    var remaining: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        store_ptr: Pointer[_Store, Self.origin],
        curr_idx: UInt32,
        remaining: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.store_ptr = store_ptr
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
    def __next__(mut self) raises StopIteration -> String:
        if self.curr_idx == NO_NODE:
            raise StopIteration()
        var idx = self.curr_idx
        self.curr_idx = self.nodes_ptr[unsafe_offset=Int(idx)].next_sibling
        self.remaining -= 1
        var v = Toml[Self.origin, Self.mode](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, idx
        )
        return v._decode_key()


struct TomlTable[
    mode_id: Int,
    //,
    origin: ImmOrigin,
    mode: _Mode[mode_id] = Mode.Strict,
](
    Boolable,
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Movable,
    Sized,
    TrivialRegisterPassable,
    Writable,
):
    """Typed 32-byte view over a TOML table node."""

    comptime Element = Toml[Self.origin, Self.mode]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = TomlIter[Self.origin, Self.mode]

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var store_ptr: Pointer[_Store, Self.origin]
    var node_idx: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        store_ptr: Pointer[_Store, Self.origin],
        node_idx: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.store_ptr = store_ptr
        self.node_idx = node_idx

    @always_inline
    def as_toml(self) -> Toml[Self.origin, Self.mode]:
        return Toml[Self.origin, Self.mode](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, self.node_idx
        )

    @always_inline
    def __bool__(self) -> Bool:
        return self.node_idx != NO_NODE

    @always_inline
    def __len__(self) -> Int:
        if self.node_idx == NO_NODE:
            return 0
        return Int(self.nodes_ptr[unsafe_offset=Int(self.node_idx)].len)

    @always_inline
    def __getitem__(self, key: StringSpan) -> Toml[Self.origin, Self.mode]:
        if self.node_idx == NO_NODE:
            return self.as_toml()
        var key_b = key.as_bytes()
        var child_idx = self.store_ptr[].key_index.find_by_bytes(
            self.node_idx, key_b, self.nodes_ptr, self.doc_ptr
        )
        return Toml[Self.origin, Self.mode](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, child_idx
        )

    @always_inline
    def get(self, key: StringSpan) -> Optional[Toml[Self.origin, Self.mode]]:
        var v = self[key]
        if v:
            return v
        return None

    @always_inline
    def __contains__(self, key: StringSpan) -> Bool:
        return Bool(self[key])

    @always_inline
    def __iter__(self) -> TomlIter[Self.origin, Self.mode]:
        return self.as_toml().__iter__()

    @always_inline
    def items(self) -> TomlItemIter[Self.origin, Self.mode]:
        return self.as_toml().items()

    @always_inline
    def keys(self) -> TomlKeyIter[Self.origin, Self.mode]:
        return self.as_toml().keys()

    def to_json[W: Writer](self, mut w: W) raises:
        self.as_toml().to_json(w)

    def write_to(self, mut w: Some[Writer]):
        self.as_toml().write_to(w)


struct TomlArray[
    mode_id: Int,
    //,
    origin: ImmOrigin,
    mode: _Mode[mode_id] = Mode.Strict,
](
    Boolable,
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Movable,
    Sized,
    TrivialRegisterPassable,
    Writable,
):
    """Typed 32-byte view over a TOML array node."""

    comptime Element = Toml[Self.origin, Self.mode]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = TomlIter[Self.origin, Self.mode]

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var store_ptr: Pointer[_Store, Self.origin]
    var node_idx: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        store_ptr: Pointer[_Store, Self.origin],
        node_idx: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.store_ptr = store_ptr
        self.node_idx = node_idx

    @always_inline
    def as_toml(self) -> Toml[Self.origin, Self.mode]:
        return Toml[Self.origin, Self.mode](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, self.node_idx
        )

    @always_inline
    def __bool__(self) -> Bool:
        return self.node_idx != NO_NODE

    @always_inline
    def __len__(self) -> Int:
        if self.node_idx == NO_NODE:
            return 0
        return Int(self.nodes_ptr[unsafe_offset=Int(self.node_idx)].len)

    @always_inline
    def __getitem__(self, index: Int) -> Toml[Self.origin, Self.mode]:
        if self.node_idx == NO_NODE:
            return self.as_toml()
        ref node = self.nodes_ptr[unsafe_offset=Int(self.node_idx)]
        if index < 0 or index >= Int(node.len):
            return Toml[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE
            )
        comptime if Self.mode_id == 0:
            var child_idx = self.store_ptr[].array_slots.unsafe_ptr()[
                unsafe_offset=Int(node.start) + index
            ]
            return Toml[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, child_idx
            )
        else:
            var curr = node.first_child
            var i = 0
            while curr != NO_NODE:
                if i == index:
                    return Toml[Self.origin, Self.mode](
                        self.doc_ptr, self.nodes_ptr, self.store_ptr, curr
                    )
                curr = self.nodes_ptr[unsafe_offset=Int(curr)].next_sibling
                i += 1
            return Toml[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE
            )

    @always_inline
    def __iter__(self) -> TomlIter[Self.origin, Self.mode]:
        return self.as_toml().__iter__()

    def to_json[W: Writer](self, mut w: W) raises:
        self.as_toml().to_json(w)

    def write_to(self, mut w: Some[Writer]):
        self.as_toml().write_to(w)


struct Toml[
    mode_id: Int,
    //,
    origin: ImmOrigin,
    mode: _Mode[mode_id] = Mode.Strict,
](
    Boolable,
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Movable,
    Sized,
    TrivialRegisterPassable,
    Writable,
):
    """Unified 32-byte register-passable view over a parsed TOML node.

    In `Mode.Eager`, values are pre-decoded and stored in the owning
    `TomlDocument` for cheap O(1) loads. In lazy modes (`Strict`, `Lexical`,
    `Structure`, `Trusted`), scalars are decoded on demand from the borrowed
    source bytes.
    """

    comptime Element = Self
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = TomlIter[Self.origin, Self.mode]

    var doc_ptr: Pointer[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var store_ptr: Pointer[_Store, Self.origin]
    var node_idx: UInt32

    @always_inline
    def __init__(
        out self,
        doc_ptr: Pointer[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        store_ptr: Pointer[_Store, Self.origin],
        node_idx: UInt32,
    ):
        self.doc_ptr = doc_ptr
        self.nodes_ptr = nodes_ptr
        self.store_ptr = store_ptr
        self.node_idx = node_idx

    @always_inline
    def _node(self) -> ref[self.origin] Node:
        return self.nodes_ptr[unsafe_offset=Int(self.node_idx)]

    @always_inline
    def _missing(self) -> Self:
        return Self(self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE)

    @always_inline
    def __bool__(self) -> Bool:
        """Return `True` if this `Toml` view refers to a present node."""
        return self.node_idx != NO_NODE

    @always_inline
    def is_missing(self) -> Bool:
        """Return `True` if this view represents a missing key or index."""
        return self.node_idx == NO_NODE or self._node().kind == NodeKind.Empty

    @always_inline
    def kind(self) -> KindTag:
        """Return the public `KindTag` of this value (`KindTag.Missing` if absent).
        """
        if self.node_idx == NO_NODE:
            return KindTag.Missing
        var nk = self._node().kind
        if nk == NodeKind.String:
            return KindTag.String
        elif nk == NodeKind.Integer:
            return KindTag.Integer
        elif nk == NodeKind.Float or nk == NodeKind.NaN or nk == NodeKind.Inf:
            return KindTag.Float
        elif nk == NodeKind.Boolean:
            return KindTag.Boolean
        elif nk == NodeKind.Date:
            return KindTag.Date
        elif nk == NodeKind.Time:
            return KindTag.Time
        elif nk == NodeKind.DateTime:
            return KindTag.DateTime
        elif nk == NodeKind.Array:
            return KindTag.Array
        elif nk == NodeKind.Table:
            return KindTag.Table
        return KindTag.Missing

    @always_inline
    def is_kind[id: Int, //, k: _Kind[id]](self) -> Bool:
        """Return `True` if this value matches `k`."""
        comptime if id == 9:
            return (
                self.node_idx == NO_NODE or self._node().kind == NodeKind.Empty
            )
        if self.node_idx == NO_NODE:
            return False
        var nk = self._node().kind
        comptime if id == 2:
            return (
                nk == NodeKind.Float or nk == NodeKind.NaN or nk == NodeKind.Inf
            )
        else:
            return nk._value == UInt8(id + 1)

    @always_inline
    def _matches_node_kind[id: Int](self, nk: NodeKind) -> Bool:
        comptime if id == 2:
            return (
                nk == NodeKind.Float or nk == NodeKind.NaN or nk == NodeKind.Inf
            )
        else:
            return nk._value == UInt8(id + 1)

    @always_inline
    def raw_bytes(self) -> Span[Byte, self.origin]:
        """Return the underlying raw byte span of this value."""
        ref node = self._node()
        return Span[Byte, self.origin](
            unsafe_ptr=self.doc_ptr.unsafe_offset(Int(node.start)),
            length=Int(node.len),
        )

    @always_inline
    def key_bytes(self) -> Span[Byte, self.origin]:
        """Return the underlying raw byte span of this node's key."""
        ref node = self._node()
        return Span[Byte, self.origin](
            unsafe_ptr=self.doc_ptr.unsafe_offset(Int(node.key_start)),
            length=Int(node.key_len),
        )

    @always_inline
    def key_span(self) -> Optional[StringSpan[self.origin]]:
        """Return a zero-copy key slice, or `None` if lazy and key has escapes.
        """
        if self.node_idx == NO_NODE:
            return None
        comptime if Self.mode_id == 0:
            return StringSpan(unsafe_from_utf8=self.key_bytes())
        else:
            if (self._node().key_flags & NodeFlags.HAS_ESCAPE) == 0:
                return StringSpan(unsafe_from_utf8=self.key_bytes())
            return None

    def _decode_key(self) -> String:
        if self.node_idx == NO_NODE:
            return String()
        ref node = self._node()
        comptime if Self.mode_id == 0:
            return String(StringSpan(unsafe_from_utf8=self.key_bytes()))
        else:
            if (node.key_flags & NodeFlags.HAS_ESCAPE) == 0:
                return String(StringSpan(unsafe_from_utf8=self.key_bytes()))
            comptime V = _validation_of[Self.mode_id]()
            comptime if validation_level(V) >= 2:
                return decode_string_unchecked(self.key_bytes(), node.key_flags)
            else:
                var res = decode_string(self.key_bytes(), node.key_flags)
                if case .Ok(var s) = res:
                    var out = s^
                    _ = res^.unsafe_take_value()
                    return out^
                _ = res^.unsafe_take_error()
                return String(StringSpan(unsafe_from_utf8=self.key_bytes()))

    @always_inline
    def string_span(self) -> Optional[StringSpan[self.origin]]:
        """Return a zero-copy `StringSpan` if this is a string without pending escapes.

        In `Mode.Eager`, all strings are pre-decoded, so this always returns a
        value for strings. In lazy modes, returns `None` for escaped strings.
        """
        if self.node_idx == NO_NODE:
            return None
        ref node = self._node()
        if node.kind != NodeKind.String:
            return None
        comptime if Self.mode_id == 0:
            return StringSpan(unsafe_from_utf8=self.raw_bytes())
        else:
            if (node.flags & NodeFlags.HAS_ESCAPE) == 0:
                return StringSpan(unsafe_from_utf8=self.raw_bytes())
            return None

    # --- Eager fast-load helpers ---

    @always_inline
    def _load_int(self, ref node: Node) -> Int:
        var u = (UInt64(node.len) << 32) | UInt64(node.start)
        return Int(bitcast[DType.int64, 1](u))

    @always_inline
    def _load_float(self, ref node: Node) -> Float64:
        var u = (UInt64(node.len) << 32) | UInt64(node.start)
        return bitcast[DType.float64, 1](u)

    @always_inline
    def _load_date(self, ref node: Node) -> Date:
        return Date(
            year=Int(node.start >> 16),
            month=Int((node.start >> 8) & 0xFF),
            day=Int(node.start & 0xFF),
        )

    # --- Navigation ---

    @always_inline
    def __getitem__(self, key: StringSpan) -> Self:
        """Look up a child value by key in O(1) time (propagates `Missing`)."""
        if self.node_idx == NO_NODE:
            return self
        ref node = self._node()
        if node.kind != NodeKind.Table:
            return self._missing()
        var child_idx = self.store_ptr[].key_index.find_by_bytes(
            self.node_idx, key.as_bytes(), self.nodes_ptr, self.doc_ptr
        )
        return Self(self.doc_ptr, self.nodes_ptr, self.store_ptr, child_idx)

    @always_inline
    def __getitem__(self, index: Int) -> Self:
        """Look up an array element by index (`O(1)` in Eager, `O(i)` in lazy).
        """
        if self.node_idx == NO_NODE:
            return self
        ref node = self._node()
        if node.kind != NodeKind.Array or index < 0 or index >= Int(node.len):
            return self._missing()
        comptime if Self.mode_id == 0:
            var child_idx = self.store_ptr[].array_slots.unsafe_ptr()[
                unsafe_offset=Int(node.start) + index
            ]
            return Self(self.doc_ptr, self.nodes_ptr, self.store_ptr, child_idx)
        else:
            var curr = node.first_child
            var i = 0
            while curr != NO_NODE:
                if i == index:
                    return Self(
                        self.doc_ptr, self.nodes_ptr, self.store_ptr, curr
                    )
                curr = self.nodes_ptr[unsafe_offset=Int(curr)].next_sibling
                i += 1
            return self._missing()

    @always_inline
    def get(self, key: StringSpan) -> Optional[Self]:
        """Look up a child value by key, returning `None` if absent."""
        var v = self[key]
        if v:
            return v
        return None

    @always_inline
    def get(self, index: Int) -> Optional[Self]:
        """Look up an array element by index, returning `None` if absent."""
        var v = self[index]
        if v:
            return v
        return None

    @always_inline
    def __contains__(self, key: StringSpan) -> Bool:
        """Return `True` if this value is a table containing `key`."""
        return Bool(self[key])

    @always_inline
    def __len__(self) -> Int:
        """Return the number of entries in a table or array in O(1) time."""
        if self.node_idx == NO_NODE:
            return 0
        ref node = self._node()
        if node.kind == NodeKind.Table or node.kind == NodeKind.Array:
            return Int(node.len)
        return 0

    # --- Casting by Kind ---

    @always_inline
    def __getitem_param__[key: StaticString](self) -> Self:
        """Forward compile-time string subscripts (e.g. `toml["key"]`) to `__getitem__`.
        """
        var ks: StaticString = materialize[key]()
        return self[StringSpan(ks)]

    @always_inline
    def __getitem_param__[index: Int](self) -> Self:
        """Forward compile-time integer subscripts (e.g. `toml[0]`) to `__getitem__`.
        """
        var idx: Int = materialize[index]()
        return self[idx]

    @always_inline
    def __getitem_param__[
        id: Int, //, k: _Kind[id]
    ](self) -> KindPayload[id, Self.origin, Self.mode_id]:
        """Cast this value to `KindPayload[k]`, aborting on missing or mismatch.
        """
        comptime assert id != 9, "Cannot cast to Kind.Missing."
        comptime R = KindPayload[id, Self.origin, Self.mode_id]

        if self.node_idx == NO_NODE:
            abort("Cannot cast Missing TOML value.")
        ref node = self._node()
        if not self._matches_node_kind[id](node.kind):
            abort("TOML value Kind does not match requested Kind.")

        comptime if Self.mode_id == 0:
            comptime if id == 0:
                var s = String(StringSpan(unsafe_from_utf8=self.raw_bytes()))
                return rebind_var[R](s^)
            elif id == 1:
                return rebind_var[R](self._load_int(node))
            elif id == 2:
                return rebind_var[R](self._load_float(node))
            elif id == 3:
                return rebind_var[R](node.start != 0)
            elif id == 4:
                return rebind_var[R](self._load_date(node))
            elif id == 5:
                return rebind_var[R](
                    self.store_ptr[].temporals[Int(node.start)].time
                )
            elif id == 6:
                return rebind_var[R](
                    self.store_ptr[].temporals[Int(node.start)]
                )
            elif id == 7:
                return rebind_var[R](
                    TomlArray[Self.origin, Self.mode](
                        self.doc_ptr,
                        self.nodes_ptr,
                        self.store_ptr,
                        self.node_idx,
                    )
                )
            elif id == 8:
                return rebind_var[R](
                    TomlTable[Self.origin, Self.mode](
                        self.doc_ptr,
                        self.nodes_ptr,
                        self.store_ptr,
                        self.node_idx,
                    )
                )
            else:
                abort("Invalid Kind.")
        else:
            comptime V = _validation_of[Self.mode_id]()
            comptime checked = validation_level(V) < 2
            comptime if id == 0:
                comptime if not checked:
                    var s = decode_string_unchecked(
                        self.raw_bytes(), node.flags
                    )
                    return rebind_var[R](s^)
                else:
                    var res = decode_string(self.raw_bytes(), node.flags)
                    if case .Err = res:
                        _ = res^.unsafe_take_error()
                        abort("Invalid TOML string value.")
                    var s = res^.unsafe_take_value()
                    return rebind_var[R](s^)
            elif id == 1:
                comptime if not checked:
                    return rebind_var[R](
                        decode_int_unchecked(self.raw_bytes(), node.flags)
                    )
                else:
                    var sr = decode_int(self.raw_bytes())
                    return rebind_var[R](sr.unsafe_take_value())
            elif id == 2:
                comptime if not checked:
                    return rebind_var[R](
                        decode_float_unchecked(self.raw_bytes(), node.flags)
                    )
                else:
                    var sr = decode_float(self.raw_bytes())
                    return rebind_var[R](sr.unsafe_take_value())
            elif id == 3:
                comptime if not checked:
                    return rebind_var[R](
                        decode_bool_unchecked(self.raw_bytes())
                    )
                else:
                    var sr = decode_bool(self.raw_bytes())
                    return rebind_var[R](sr.unsafe_take_value())
            elif id == 4:
                comptime if not checked:
                    return rebind_var[R](
                        decode_date_unchecked(self.raw_bytes())
                    )
                else:
                    var sr = decode_date(self.raw_bytes())
                    return rebind_var[R](sr.unsafe_take_value())
            elif id == 5:
                comptime if not checked:
                    return rebind_var[R](
                        decode_time_unchecked(self.raw_bytes())
                    )
                else:
                    var sr = decode_time(self.raw_bytes())
                    return rebind_var[R](sr.unsafe_take_value())
            elif id == 6:
                comptime if not checked:
                    return rebind_var[R](
                        decode_datetime_unchecked(self.raw_bytes())
                    )
                else:
                    var sr = decode_datetime(self.raw_bytes())
                    return rebind_var[R](sr.unsafe_take_value())
            elif id == 7:
                return rebind_var[R](
                    TomlArray[Self.origin, Self.mode](
                        self.doc_ptr,
                        self.nodes_ptr,
                        self.store_ptr,
                        self.node_idx,
                    )
                )
            elif id == 8:
                return rebind_var[R](
                    TomlTable[Self.origin, Self.mode](
                        self.doc_ptr,
                        self.nodes_ptr,
                        self.store_ptr,
                        self.node_idx,
                    )
                )
            else:
                abort("Invalid Kind.")

    @always_inline
    def take[
        id: Int, //, k: _Kind[id]
    ](self) raises -> KindPayload[id, Self.origin, Self.mode_id]:
        """Checked extraction by `Kind`, raising on missing, mismatch, or invalid scalar.
        """
        comptime assert id != 9, "Cannot take Kind.Missing."
        comptime R = KindPayload[id, Self.origin, Self.mode_id]

        if self.node_idx == NO_NODE:
            raise Error("Missing TOML value.")
        ref node = self._node()
        if not self._matches_node_kind[id](node.kind):
            raise Error(
                String(
                    "TOML kind mismatch: expected ",
                    k,
                    ", got ",
                    self.kind(),
                    ".",
                )
            )

        comptime if Self.mode_id == 0:
            return self[k]
        else:
            comptime V = _validation_of[Self.mode_id]()
            comptime checked = validation_level(V) < 2
            comptime if id == 0:
                comptime if not checked:
                    var s = decode_string_unchecked(
                        self.raw_bytes(), node.flags
                    )
                    return rebind_var[R](s^)
                else:
                    var s = decode_string(self.raw_bytes(), node.flags).take()
                    return rebind_var[R](s^)
            elif id == 1:
                comptime if not checked:
                    return rebind_var[R](
                        decode_int_unchecked(self.raw_bytes(), node.flags)
                    )
                else:
                    return rebind_var[R](decode_int(self.raw_bytes()).take())
            elif id == 2:
                comptime if not checked:
                    return rebind_var[R](
                        decode_float_unchecked(self.raw_bytes(), node.flags)
                    )
                else:
                    return rebind_var[R](decode_float(self.raw_bytes()).take())
            elif id == 3:
                comptime if not checked:
                    return rebind_var[R](
                        decode_bool_unchecked(self.raw_bytes())
                    )
                else:
                    return rebind_var[R](decode_bool(self.raw_bytes()).take())
            elif id == 4:
                comptime if not checked:
                    return rebind_var[R](
                        decode_date_unchecked(self.raw_bytes())
                    )
                else:
                    return rebind_var[R](decode_date(self.raw_bytes()).take())
            elif id == 5:
                comptime if not checked:
                    return rebind_var[R](
                        decode_time_unchecked(self.raw_bytes())
                    )
                else:
                    return rebind_var[R](decode_time(self.raw_bytes()).take())
            elif id == 6:
                comptime if not checked:
                    return rebind_var[R](
                        decode_datetime_unchecked(self.raw_bytes())
                    )
                else:
                    return rebind_var[R](
                        decode_datetime(self.raw_bytes()).take()
                    )
            elif id == 7:
                return rebind_var[R](
                    TomlArray[Self.origin, Self.mode](
                        self.doc_ptr,
                        self.nodes_ptr,
                        self.store_ptr,
                        self.node_idx,
                    )
                )
            elif id == 8:
                return rebind_var[R](
                    TomlTable[Self.origin, Self.mode](
                        self.doc_ptr,
                        self.nodes_ptr,
                        self.store_ptr,
                        self.node_idx,
                    )
                )
            else:
                raise Error("Invalid Kind.")

    # --- Struct / container reflection ---

    def _take_list[Elem: Movable & Deinitable](self) raises -> List[Elem]:
        if not self.is_kind[Kind.Array]():
            raise Error("[TYPE ERROR]: Toml value is not an Array.")
        var out = List[Elem](capacity=len(self))
        for item in self:
            out.append(item.take[Elem]())
        return out^

    def _take_struct[T: Movable](self) raises -> T:
        if not self.is_kind[Kind.Table]():
            raise Error("The toml value doesn't correspond to a Table.")

        comptime Tr = reflect[T]
        comptime field_types = Tr.field_types()
        comptime field_count = Tr.field_count()
        comptime field_names = Tr.field_names()

        var layout = Layout[T](length=1)
        var allocation = alloc(layout)

        comptime for fi in range(field_count):
            comptime TYPE = field_types[fi]
            comptime RTYPE = reflect[TYPE]
            comptime NAME = field_names[fi]
            comptime assert conforms_to(TYPE, Movable & Deinitable), String(
                t"Each field of struct {Tr.name()} must be Movable and"
                t" Deinitable. field: {NAME} (idx {fi})"
            )

            ref field_ptr = Tr.field_ref[fi](allocation.unsafe_ptr()[])

            comptime if RTYPE.base_name() == "Optional":
                comptime assert conforms_to(TYPE, Iterable)
                comptime Inner = TYPE.IteratorType[origin_of()].Element
                comptime assert conforms_to(Inner, Movable & Deinitable)

                var opt_child = self.get(NAME)
                if not opt_child:
                    Pointer(to=field_ptr).unsafe_write(
                        rebind_var[TYPE](Optional[Inner](None))
                    )
                else:
                    try:
                        var inner_val = opt_child.value().take[Inner]()
                        Pointer(to=field_ptr).unsafe_write(
                            rebind_var[TYPE](Optional[Inner](inner_val^))
                        )
                    except e:
                        _destroy_partial_struct[T](allocation^, fi)
                        raise e^
            else:
                var opt_child = self.get(NAME)
                if not opt_child:
                    _destroy_partial_struct[T](allocation^, fi)
                    raise Error(
                        String("Struct field '", NAME, "' missing in table.")
                    )
                try:
                    Pointer(to=field_ptr).unsafe_write(
                        opt_child.value().take[TYPE]()
                    )
                except e:
                    _destroy_partial_struct[T](allocation^, fi)
                    raise e^

        return allocation^.unsafe_leak().unsafe_take_pointee()

    def take[T: Movable & Deinitable](self) raises -> T:
        """Deserialize this TOML value into `T` (scalar, `List`, `Optional`, or struct).
        """
        comptime Tr = reflect[T]

        comptime if T == Self:
            return rebind_var[T](self)
        elif T == TomlTable[Self.origin, Self.mode]:
            var tb = self.take[Kind.Table]()
            return rebind_var[T](tb)
        elif T == TomlArray[Self.origin, Self.mode]:
            var arr = self.take[Kind.Array]()
            return rebind_var[T](arr)
        elif T == String:
            var s = self.take[Kind.String]()
            return rebind_var[T](s^)
        elif T == Int:
            var iv = self.take[Kind.Integer]()
            return rebind_var[T](iv)
        elif T == Float64:
            var fv = self.take[Kind.Float]()
            return rebind_var[T](fv)
        elif T == Bool:
            var bv = self.take[Kind.Boolean]()
            return rebind_var[T](bv)
        elif T == Date:
            var d = self.take[Kind.Date]()
            return rebind_var[T](d)
        elif T == Time:
            var t = self.take[Kind.Time]()
            return rebind_var[T](t)
        elif T == DateTime:
            var dt = self.take[Kind.DateTime]()
            return rebind_var[T](dt)
        elif Tr.base_name() == "Optional":
            comptime assert conforms_to(T, Iterable)
            comptime Inner = T.IteratorType[origin_of()].Element
            comptime assert conforms_to(Inner, Movable & Deinitable)
            if self.node_idx == NO_NODE:
                return rebind_var[T](Optional[Inner](None))
            var inner_v = self.take[Inner]()
            return rebind_var[T](Optional[Inner](inner_v^))
        elif Tr.base_name() == "List":
            comptime assert conforms_to(T, Iterable)
            comptime Elem = T.IteratorType[origin_of()].Element
            comptime assert conforms_to(Elem, Movable & Deinitable)
            var lst = self._take_list[Elem]()
            return rebind_var[T](lst^)
        elif Tr.is_struct():
            return self._take_struct[T]()
        elif Tr.base_name() == "Variant":
            raise Error("Variant types not supported yet!")
        else:
            raise Error("Type Not Supported!")

    # --- Iteration ---

    @always_inline
    def __iter__(self) -> TomlIter[Self.origin, Self.mode]:
        """Iterate children of a table (entries) or array (elements) in order.
        """
        if self.node_idx == NO_NODE:
            return TomlIter[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE, 0
            )
        ref node = self._node()
        if node.kind != NodeKind.Table and node.kind != NodeKind.Array:
            return TomlIter[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE, 0
            )
        return TomlIter[Self.origin, Self.mode](
            self.doc_ptr,
            self.nodes_ptr,
            self.store_ptr,
            node.first_child,
            node.len,
        )

    @always_inline
    def items(self) -> TomlItemIter[Self.origin, Self.mode]:
        """Iterate `(key, value)` pairs of a table in document order."""
        if self.node_idx == NO_NODE:
            return TomlItemIter[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE, 0
            )
        ref node = self._node()
        if node.kind != NodeKind.Table:
            return TomlItemIter[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE, 0
            )
        return TomlItemIter[Self.origin, Self.mode](
            self.doc_ptr,
            self.nodes_ptr,
            self.store_ptr,
            node.first_child,
            node.len,
        )

    @always_inline
    def keys(self) -> TomlKeyIter[Self.origin, Self.mode]:
        """Iterate decoded keys of a table in document order."""
        if self.node_idx == NO_NODE:
            return TomlKeyIter[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE, 0
            )
        ref node = self._node()
        if node.kind != NodeKind.Table:
            return TomlKeyIter[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE, 0
            )
        return TomlKeyIter[Self.origin, Self.mode](
            self.doc_ptr,
            self.nodes_ptr,
            self.store_ptr,
            node.first_child,
            node.len,
        )

    # --- Serialization ---

    def to_json[W: Writer](self, mut w: W) raises:
        """Stream this value and all its children as tagged JSON to a writer."""
        if self.node_idx == NO_NODE:
            raise Error("Cannot serialize Missing TOML value to JSON.")
        ref node = self._node()
        var k = node.kind
        if k == NodeKind.String:
            w.write('{"type": "string", "value": "')
            comptime if Self.mode_id == 0:
                _write_json_escaped_bytes(self.raw_bytes(), w)
            else:
                if (node.flags & NodeFlags.LITERAL) != 0 or (
                    node.flags & NodeFlags.HAS_ESCAPE
                ) == 0:
                    _write_json_escaped_bytes(self.raw_bytes(), w)
                else:
                    comptime V = _validation_of[Self.mode_id]()
                    comptime if validation_level(V) >= 2:
                        write_toml_string_as_json_unchecked(
                            self.raw_bytes(), node.flags, w
                        )
                    else:
                        write_toml_string_as_json(
                            self.raw_bytes(), node.flags, w
                        )
            w.write('"}')
        elif k == NodeKind.Integer:
            comptime if Self.mode_id == 0:
                w.write(
                    '{"type": "integer", "value": "',
                    self._load_int(node),
                    '"}',
                )
            else:
                comptime V = _validation_of[Self.mode_id]()
                comptime if validation_level(V) >= 2:
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
                                StringSpan(unsafe_from_utf8=raw_b),
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
                        self.take[Kind.Integer](),
                        '"}',
                    )
        elif k == NodeKind.Float:
            comptime if Self.mode_id == 0:
                w.write(
                    '{"type": "float", "value": "',
                    self._load_float(node),
                    '"}',
                )
            else:
                comptime V = _validation_of[Self.mode_id]()
                comptime if validation_level(V) >= 2:
                    w.write(
                        '{"type": "float", "value": "',
                        decode_float_unchecked(self.raw_bytes(), node.flags),
                        '"}',
                    )
                else:
                    w.write(
                        '{"type": "float", "value": "',
                        self.take[Kind.Float](),
                        '"}',
                    )
        elif k == NodeKind.NaN:
            w.write('{"type": "float", "value": "nan"}')
        elif k == NodeKind.Inf:
            comptime if Self.mode_id == 0:
                if self._load_float(node) < 0.0:
                    w.write('{"type": "float", "value": "-inf"}')
                else:
                    w.write('{"type": "float", "value": "inf"}')
            else:
                var b = self.raw_bytes()
                if len(b) > 0 and b.unsafe_ptr()[unsafe_offset=0] == Byte(
                    ord("-")
                ):
                    w.write('{"type": "float", "value": "-inf"}')
                else:
                    w.write('{"type": "float", "value": "inf"}')
        elif k == NodeKind.Boolean:
            comptime if Self.mode_id == 0:
                w.write(
                    '{"type": "bool", "value": "true"}' if node.start
                    != 0 else '{"type": "bool", "value": "false"}'
                )
            else:
                comptime V = _validation_of[Self.mode_id]()
                comptime if validation_level(V) >= 2:
                    w.write(
                        '{"type": "bool", "value": "true"}' if decode_bool_unchecked(
                            self.raw_bytes()
                        ) else '{"type": "bool", "value": "false"}'
                    )
                else:
                    w.write(
                        '{"type": "bool", "value": "true"}' if (
                            self.take[Kind.Boolean]()
                        ) else '{"type": "bool", "value": "false"}'
                    )
        elif k == NodeKind.Date:
            comptime if Self.mode_id == 0:
                w.write(
                    '{"type": "date-local", "value": "',
                    self._load_date(node),
                    '"}',
                )
            else:
                comptime V = _validation_of[Self.mode_id]()
                comptime if validation_level(V) < 2:
                    _ = self.take[Kind.Date]()
                w.write(
                    '{"type": "date-local", "value": "',
                    StringSpan(unsafe_from_utf8=self.raw_bytes()),
                    '"}',
                )
        elif k == NodeKind.Time:
            comptime if Self.mode_id == 0:
                w.write(
                    '{"type": "time-local", "value": "',
                    self.store_ptr[].temporals[Int(node.start)].time,
                    '"}',
                )
            else:
                comptime V = _validation_of[Self.mode_id]()
                comptime if validation_level(V) >= 2:
                    w.write(
                        '{"type": "time-local", "value": "',
                        decode_time_unchecked(self.raw_bytes()),
                        '"}',
                    )
                else:
                    w.write(
                        '{"type": "time-local", "value": "',
                        self.take[Kind.Time](),
                        '"}',
                    )
        elif k == NodeKind.DateTime:
            comptime if Self.mode_id == 0:
                var dt = self.store_ptr[].temporals[Int(node.start)]
                var nm = "datetime-local" if dt.is_local else "datetime"
                w.write('{"type": "', nm, '", "value": "', dt, '"}')
            else:
                comptime V = _validation_of[Self.mode_id]()
                comptime if validation_level(V) >= 2:
                    var dt = decode_datetime_unchecked(self.raw_bytes())
                    var nm = "datetime-local" if dt.is_local else "datetime"
                    w.write('{"type": "', nm, '", "value": "', dt, '"}')
                else:
                    var dt = self.take[Kind.DateTime]()
                    var nm = "datetime-local" if dt.is_local else "datetime"
                    w.write('{"type": "', nm, '", "value": "', dt, '"}')
        elif k == NodeKind.Array:
            w.write("[")
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    w.write(", ")
                first = False
                var child_val = Self(
                    self.doc_ptr, self.nodes_ptr, self.store_ptr, curr
                )
                child_val.to_json(w)
                curr = self.nodes_ptr[unsafe_offset=Int(curr)].next_sibling
            w.write("]")
        elif k == NodeKind.Table:
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
                comptime if Self.mode_id == 0:
                    _write_json_escaped_bytes(k_span, w)
                else:
                    if (child_node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
                        comptime V = _validation_of[Self.mode_id]()
                        comptime if validation_level(V) >= 2:
                            write_toml_string_as_json_unchecked(
                                k_span, child_node.key_flags, w
                            )
                        else:
                            write_toml_string_as_json(
                                k_span, child_node.key_flags, w
                            )
                    else:
                        _write_json_escaped_bytes(k_span, w)
                w.write('": ')
                var child_val = Self(
                    self.doc_ptr, self.nodes_ptr, self.store_ptr, curr
                )
                child_val.to_json(w)
                curr = child_node.next_sibling
            w.write("}")

    def write_to(self, mut w: Some[Writer]):
        if self.node_idx == NO_NODE:
            w.write("Toml(Missing)")
            return
        w.write("Toml(")
        var k = self.kind()
        if k == KindTag.Table:
            w.write("{")
            var first = True
            for entry in self:
                if not first:
                    w.write(", ")
                first = False
                w.write('"', entry._decode_key(), '": ', entry)
            w.write("}")
        elif k == KindTag.Array:
            w.write("[")
            var first = True
            for elem in self:
                if not first:
                    w.write(", ")
                first = False
                w.write(elem)
            w.write("]")
        elif k == KindTag.String:
            try:
                w.write("'", self.take[Kind.String](), "'")
            except:
                w.write("<invalid string>")
        elif k == KindTag.Integer:
            try:
                w.write(self.take[Kind.Integer]())
            except:
                w.write("<invalid int>")
        elif k == KindTag.Float:
            try:
                w.write(self.take[Kind.Float]())
            except:
                w.write("<invalid float>")
        elif k == KindTag.Boolean:
            try:
                w.write("true" if self.take[Kind.Boolean]() else "false")
            except:
                w.write("<invalid bool>")
        elif k == KindTag.Date:
            try:
                w.write(self.take[Kind.Date]())
            except:
                w.write("<invalid date>")
        elif k == KindTag.Time:
            try:
                w.write(self.take[Kind.Time]())
            except:
                w.write("<invalid time>")
        elif k == KindTag.DateTime:
            try:
                w.write(self.take[Kind.DateTime]())
            except:
                w.write("<invalid datetime>")
        w.write(")")


struct TomlDocument[
    mode_id: Int,
    //,
    mode: _Mode[mode_id],
    origin: ImmOrigin = ImmUntrackedOrigin,
](Movable, Sized, Writable):
    """Owning handle for a parsed TOML document.

    In lazy modes, borrows the source byte span (`origin`). In `Mode.Eager`,
    owns its decoded arena and scalar columns and carries no source origin.
    All reads go through `Toml` views obtained via `.root()` or forwarding
    indexers.
    """

    var data: Span[Byte, Self.origin]
    var nodes: List[Node]
    var store: _Store
    var root_idx: UInt32

    def __init__(
        out self,
        data: Span[Byte, Self.origin],
        var nodes: List[Node],
        var store: _Store,
        root_idx: UInt32 = 0,
    ):
        self.data = data
        self.nodes = nodes^
        self.store = store^
        self.root_idx = root_idx

    @always_inline
    def root(
        ref self,
    ) -> Toml[ImmOrigin(origin_of(self)), Self.mode]:
        """Return the root `Toml` table view."""
        var doc_p: Pointer[Byte, ImmOrigin(origin_of(self))]
        comptime if Self.mode_id == 0:
            doc_p = (
                self.store.arena.unsafe_ptr()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmOrigin(origin_of(self))]()
            )
        else:
            doc_p = self.data.unsafe_ptr().unsafe_origin_cast[
                ImmOrigin(origin_of(self))
            ]()
        return Toml[ImmOrigin(origin_of(self)), Self.mode](
            doc_p,
            Pointer(to=self.nodes[0])
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            Pointer(to=self.store)
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            self.root_idx,
        )

    @always_inline
    def __getitem__(
        ref self, key: StringSpan
    ) -> Toml[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root()[key]

    @always_inline
    def get(
        ref self, key: StringSpan
    ) -> Optional[Toml[ImmOrigin(origin_of(self)), Self.mode]]:
        return self.root().get(key)

    @always_inline
    def __contains__(ref self, key: StringSpan) -> Bool:
        return key in self.root()

    @always_inline
    def __len__(self) -> Int:
        return Int(self.nodes[Int(self.root_idx)].len)

    @always_inline
    def __iter__(ref self) -> TomlIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().__iter__()

    @always_inline
    def items(ref self) -> TomlItemIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().items()

    @always_inline
    def keys(ref self) -> TomlKeyIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().keys()

    @always_inline
    def take[T: Movable & Deinitable](ref self) raises -> T:
        return self.root().take[T]()

    def to_json[W: Writer](ref self, mut w: W) raises:
        self.root().to_json(w)

    def write_to(ref self, mut w: Some[Writer]):
        self.root().write_to(w)


def _materialize(
    data: Span[Byte, _], var tape: _ParsedTape
) -> TomlDocument[Mode.Eager, ImmUntrackedOrigin]:
    """Convert a Strict-validated tape into an owned, pre-decoded Eager document.
    """
    var nodes = List[Node]()
    var key_index = KeyIndex()
    tape^.take_into(nodes, key_index)
    var n_nodes = len(nodes)
    var n_ptr = nodes.unsafe_ptr()
    var src_len = len(data)

    # Pre-scan to size arena, array_slots, and temporals in one pass.
    var extra_bytes = 0
    var array_slot_count = 0
    var temporal_count = 0
    for i in range(n_nodes):
        ref node = n_ptr[unsafe_offset=i]
        if (node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
            extra_bytes += Int(node.key_len)
        if node.kind == NodeKind.String:
            if (node.flags & NodeFlags.HAS_ESCAPE) != 0 and (
                node.flags & NodeFlags.LITERAL
            ) == 0:
                extra_bytes += Int(node.len)
        elif node.kind == NodeKind.Array:
            array_slot_count += Int(node.len)
        elif node.kind == NodeKind.Time or node.kind == NodeKind.DateTime:
            temporal_count += 1

    var total_cap = src_len + extra_bytes
    var arena = List[Byte](capacity=total_cap)
    if total_cap > 0:
        arena.resize(unsafe_uninit_length=total_cap)
    if src_len > 0:
        unsafe_memcpy(
            dest=arena.unsafe_ptr(), src=data.unsafe_ptr(), count=src_len
        )

    var array_slots = List[UInt32](capacity=array_slot_count)
    var temporals = List[DateTime](capacity=temporal_count)

    var src_ptr = data.unsafe_ptr()
    var arena_ptr = arena.unsafe_ptr()
    var write_pos = src_len
    var any_escaped_key = False

    for i in range(n_nodes):
        ref node = n_ptr[unsafe_offset=i]

        if (node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
            var k_raw = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(Int(node.key_start)),
                length=Int(node.key_len),
            )
            var kw = _ArenaWriter(arena_ptr.unsafe_offset(write_pos))
            decode_string_to_writer_unchecked(k_raw, node.key_flags, kw)
            node.key_start = UInt32(write_pos)
            node.key_len = UInt32(kw.pos)
            node.key_flags = 0
            write_pos += kw.pos
            any_escaped_key = True

        var k = node.kind
        if k == NodeKind.String:
            if (node.flags & NodeFlags.HAS_ESCAPE) != 0 and (
                node.flags & NodeFlags.LITERAL
            ) == 0:
                var s_raw = Span[Byte, data.origin](
                    unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                var sw = _ArenaWriter(arena_ptr.unsafe_offset(write_pos))
                decode_string_to_writer_unchecked(s_raw, node.flags, sw)
                node.start = UInt32(write_pos)
                node.len = UInt32(sw.pos)
                write_pos += sw.pos
            node.flags = 0
        elif k == NodeKind.Integer:
            var raw_b = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            var iv = decode_int_unchecked(raw_b, node.flags)
            var u = bitcast[DType.uint64, 1](Int64(iv))
            node.start = UInt32(u & 0xFFFFFFFF)
            node.len = UInt32(u >> 32)
        elif k == NodeKind.Float or k == NodeKind.Inf:
            var raw_b = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            var fv = decode_float_unchecked(raw_b, node.flags)
            var u = bitcast[DType.uint64, 1](fv)
            node.start = UInt32(u & 0xFFFFFFFF)
            node.len = UInt32(u >> 32)
        elif k == NodeKind.NaN:
            var fv = nan[DType.float64]()
            var u = bitcast[DType.uint64, 1](fv)
            node.start = UInt32(u & 0xFFFFFFFF)
            node.len = UInt32(u >> 32)
        elif k == NodeKind.Boolean:
            var raw_b = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            node.start = UInt32(1) if decode_bool_unchecked(raw_b) else UInt32(
                0
            )
        elif k == NodeKind.Date:
            var raw_b = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            var d = decode_date_unchecked(raw_b)
            node.start = (
                (UInt32(d.year) << 16) | (UInt32(d.month) << 8) | UInt32(d.day)
            )
        elif k == NodeKind.Time:
            var raw_b = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            var t = decode_time_unchecked(raw_b)
            var idx = UInt32(len(temporals))
            temporals.append(
                DateTime(Date(year=0, month=0, day=0), t, Offset(), True)
            )
            node.start = idx
        elif k == NodeKind.DateTime:
            var raw_b = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                length=Int(node.len),
            )
            var dt = decode_datetime_unchecked(raw_b)
            var idx = UInt32(len(temporals))
            temporals.append(dt)
            node.start = idx
        elif k == NodeKind.Array:
            var slot_start = UInt32(len(array_slots))
            var curr = node.first_child
            while curr != NO_NODE:
                array_slots.append(curr)
                curr = n_ptr[unsafe_offset=Int(curr)].next_sibling
            node.start = slot_start

    if write_pos != total_cap:
        arena.resize(unsafe_uninit_length=write_pos)

    if any_escaped_key:
        var slots_ptr = key_index.slots.unsafe_ptr()
        var cap = len(key_index.slots)
        for s_idx in range(cap):
            ref slot = slots_ptr[unsafe_offset=s_idx]
            if (
                not slot.is_empty()
                and (slot.key_len_flags & KEY_ESCAPE_BIT) != 0
            ):
                slot.key_len_flags = n_ptr[
                    unsafe_offset=Int(slot.node_idx)
                ].key_len

    var store = _Store(key_index^, arena^, array_slots^, temporals^)
    return TomlDocument[Mode.Eager, ImmUntrackedOrigin](
        Span[Byte, ImmUntrackedOrigin](), nodes^, store^, 0
    )
