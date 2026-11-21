"""Unified 32-byte `Toml` view, typed container views, iterators, and reflection."""

from std.builtin._enum import __Union
from std.builtin.rebind import downcast
from std.builtin.tuple import __TupleLike
from std.builtin.variadics import TypeList, _MLIR
from std.collections import List, Span
from std.memory import MaybeUninit, Pointer, bitcast
from std.os import abort
from std.utils import Variant
from ..mode import Mode, _Mode, _is_eager, _is_strict
from ..tape.decode import (
    decode_bool,
    decode_bool_unchecked,
    decode_date,
    decode_date_unchecked,
    decode_datetime,
    decode_datetime_unchecked,
    decode_float,
    decode_float_unchecked,
    decode_int,
    decode_int_unchecked,
    decode_string,
    decode_string_unchecked,
    decode_time,
    decode_time_unchecked,
)
from ..tape.node import NO_NODE, Node, NodeFlags, NodeKind
from .json import _write_node_as_json
from .kind import Kind, KindTag, _Kind
from .reflection import (
    _IsValidTomlEnum,
    _VariantConstructible,
    _destroy_partial_struct,
)
from .store import _Store
from .tempo import Date, DateTime, Time


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


# --- Iterators ---


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
    """O(1)-step iterator over children of a `Toml`, `TomlTable`, or `TomlArray`.
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
    """Iterator yielding `(key, value)` pairs of a TOML table in document order.
    """

    comptime Element = Tuple[String, Toml[Self.origin, Self.mode]]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var inner: TomlIter[Self.origin, Self.mode]

    @always_inline
    def __init__(out self, inner: TomlIter[Self.origin, Self.mode]):
        self.inner = inner

    @always_inline
    def __iter__(self) -> Self:
        return self

    @always_inline
    def __len__(self) -> Int:
        return len(self.inner)

    @always_inline
    def __has_next__(self) -> Bool:
        return self.inner.__has_next__()

    @always_inline
    def __next__(mut self) raises StopIteration -> Self.Element:
        var v = self.inner.__next__()
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
    """Iterator yielding decoded key strings of a TOML table in document order.
    """

    comptime Element = String
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var inner: TomlIter[Self.origin, Self.mode]

    @always_inline
    def __init__(out self, inner: TomlIter[Self.origin, Self.mode]):
        self.inner = inner

    @always_inline
    def __iter__(self) -> Self:
        return self

    @always_inline
    def __len__(self) -> Int:
        return len(self.inner)

    @always_inline
    def __has_next__(self) -> Bool:
        return self.inner.__has_next__()

    @always_inline
    def __next__(mut self) raises StopIteration -> String:
        var v = self.inner.__next__()
        return v._decode_key()


# --- Typed container views ---


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
        var child_idx = self.store_ptr[].key_index.find_by_bytes(
            self.node_idx, key.as_bytes(), self.nodes_ptr, self.doc_ptr
        )
        return Toml[Self.origin, Self.mode](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, child_idx
        )

    @always_inline
    def get(self, key: StringSpan) -> Optional[Toml[Self.origin, Self.mode]]:
        return self.as_toml().get(key)

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

    @always_inline
    def take[T: Movable & Deinitable](self) raises -> T:
        return self.as_toml().take[T]()

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
        return self.as_toml()[index]

    @always_inline
    def get(self, index: Int) -> Optional[Toml[Self.origin, Self.mode]]:
        return self.as_toml().get(index)

    @always_inline
    def __iter__(self) -> TomlIter[Self.origin, Self.mode]:
        return self.as_toml().__iter__()

    @always_inline
    def take[T: Movable & Deinitable](self) raises -> T:
        return self.as_toml().take[T]()

    def to_json[W: Writer](self, mut w: W) raises:
        self.as_toml().to_json(w)

    def write_to(self, mut w: Some[Writer]):
        self.as_toml().write_to(w)


# --- Unified Toml view ---


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

    - `Mode.Strict`: borrows source bytes and decodes pre-validated scalars on demand.
    - `Mode.Eager`: reads pre-decoded scalars and owned arena slices in O(1).
    - `Mode.Trusted`: borrows source bytes and validates/decodes scalars on demand.
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
        """Return True if this view refers to a present node."""
        return self.node_idx != NO_NODE

    @always_inline
    def is_missing(self) -> Bool:
        """Return True if this view represents a missing key or index."""
        return self.node_idx == NO_NODE or self._node().kind == NodeKind.Empty

    @always_inline
    def kind(self) -> KindTag:
        """Return the runtime `KindTag` (`KindTag.Missing` if absent)."""
        if self.node_idx == NO_NODE:
            return KindTag.Missing
        match self._node().kind:
            case .String:
                return KindTag.String
            case .Integer:
                return KindTag.Integer
            case .Float | .NaN | .Inf:
                return KindTag.Float
            case .Boolean:
                return KindTag.Boolean
            case .Date:
                return KindTag.Date
            case .Time:
                return KindTag.Time
            case .DateTime:
                return KindTag.DateTime
            case .Array:
                return KindTag.Array
            case .Table:
                return KindTag.Table
            case .Empty:
                return KindTag.Missing

    @always_inline
    def is_kind[id: Int, //, k: _Kind[id]](self) -> Bool:
        """Return True if this value matches `k`."""
        comptime if id == 9:
            return self.is_missing()
        if self.node_idx == NO_NODE:
            return False
        return self._matches_node_kind[id](self._node().kind)

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
        comptime if _is_eager[Self.mode_id]():
            return StringSpan(unsafe_from_utf8=self.key_bytes())
        else:
            if (self._node().key_flags & NodeFlags.HAS_ESCAPE) == 0:
                return StringSpan(unsafe_from_utf8=self.key_bytes())
            return None

    def _decode_key(self) -> String:
        if self.node_idx == NO_NODE:
            return String()
        ref node = self._node()
        comptime if _is_eager[Self.mode_id]():
            return String(StringSpan(unsafe_from_utf8=self.key_bytes()))
        else:
            if (node.key_flags & NodeFlags.HAS_ESCAPE) == 0:
                return String(StringSpan(unsafe_from_utf8=self.key_bytes()))
            comptime if _is_strict[Self.mode_id]():
                return decode_string_unchecked(self.key_bytes(), node.key_flags)
            else:
                var res = decode_string(self.key_bytes(), node.key_flags)
                if case .Ok(_) = res:
                    return res^.unsafe_take_value()
                _ = res^.unsafe_take_error()
                return String(StringSpan(unsafe_from_utf8=self.key_bytes()))

    @always_inline
    def string_span(self) -> Optional[StringSpan[self.origin]]:
        """Return a zero-copy `StringSpan` if contiguous (always succeeds in `Mode.Eager`).
        """
        if self.node_idx == NO_NODE:
            return None
        ref node = self._node()
        if node.kind != NodeKind.String:
            return None
        comptime if _is_eager[Self.mode_id]():
            return StringSpan(unsafe_from_utf8=self.raw_bytes())
        else:
            if (node.flags & NodeFlags.HAS_ESCAPE) == 0:
                return StringSpan(unsafe_from_utf8=self.raw_bytes())
            return None

    # --- Internal scalar loaders (shared by `[Kind.X]` and `take[T]()`) ---

    @always_inline
    def _load_eager_int(self, ref node: Node) -> Int:
        var u = (UInt64(node.len) << 32) | UInt64(node.start)
        return Int(bitcast[DType.int64, 1](u))

    @always_inline
    def _load_eager_float(self, ref node: Node) -> Float64:
        var u = (UInt64(node.len) << 32) | UInt64(node.start)
        return bitcast[DType.float64, 1](u)

    @always_inline
    def _load_eager_date(self, ref node: Node) -> Date:
        return Date(
            year=Int(node.start >> 16),
            month=Int((node.start >> 8) & 0xFF),
            day=Int(node.start & 0xFF),
        )

    @always_inline
    def _check_kind_or_raise[id: Int](self) raises:
        if self.node_idx == NO_NODE:
            raise Error("Missing TOML value.")
        if not self._matches_node_kind[id](self._node().kind):
            raise Error(
                String(
                    "TOML kind mismatch: expected ",
                    _Kind[id](),
                    ", got ",
                    self.kind(),
                    ".",
                )
            )

    @always_inline
    def _decode_kind_trusted_safe[
        id: Int
    ](self) -> KindPayload[id, Self.origin, Self.mode_id]:
        """Decode a pre-validated (Eager or Strict) node whose kind is already verified.
        """
        comptime R = KindPayload[id, Self.origin, Self.mode_id]
        ref node = self._node()
        comptime if _is_eager[Self.mode_id]():
            comptime match id:
                case 0:
                    var s = String(
                        StringSpan(unsafe_from_utf8=self.raw_bytes())
                    )
                    return rebind_var[R](s^)
                case 1:
                    return rebind_var[R](self._load_eager_int(node))
                case 2:
                    return rebind_var[R](self._load_eager_float(node))
                case 3:
                    return rebind_var[R](node.start != 0)
                case 4:
                    return rebind_var[R](self._load_eager_date(node))
                case 5:
                    return rebind_var[R](
                        self.store_ptr[].temporals[Int(node.start)].time
                    )
                case 6:
                    return rebind_var[R](
                        self.store_ptr[].temporals[Int(node.start)]
                    )
                case 7:
                    return rebind_var[R](
                        TomlArray[Self.origin, Self.mode](
                            self.doc_ptr,
                            self.nodes_ptr,
                            self.store_ptr,
                            self.node_idx,
                        )
                    )
                case 8:
                    return rebind_var[R](
                        TomlTable[Self.origin, Self.mode](
                            self.doc_ptr,
                            self.nodes_ptr,
                            self.store_ptr,
                            self.node_idx,
                        )
                    )
                case _:
                    abort("Invalid Kind.")
        else:
            comptime match id:
                case 0:
                    var s = decode_string_unchecked(
                        self.raw_bytes(), node.flags
                    )
                    return rebind_var[R](s^)
                case 1:
                    return rebind_var[R](
                        decode_int_unchecked(self.raw_bytes(), node.flags)
                    )
                case 2:
                    return rebind_var[R](
                        decode_float_unchecked(self.raw_bytes(), node.flags)
                    )
                case 3:
                    return rebind_var[R](
                        decode_bool_unchecked(self.raw_bytes())
                    )
                case 4:
                    return rebind_var[R](
                        decode_date_unchecked(self.raw_bytes())
                    )
                case 5:
                    return rebind_var[R](
                        decode_time_unchecked(self.raw_bytes())
                    )
                case 6:
                    return rebind_var[R](
                        decode_datetime_unchecked(self.raw_bytes())
                    )
                case 7:
                    return rebind_var[R](
                        TomlArray[Self.origin, Self.mode](
                            self.doc_ptr,
                            self.nodes_ptr,
                            self.store_ptr,
                            self.node_idx,
                        )
                    )
                case 8:
                    return rebind_var[R](
                        TomlTable[Self.origin, Self.mode](
                            self.doc_ptr,
                            self.nodes_ptr,
                            self.store_ptr,
                            self.node_idx,
                        )
                    )
                case _:
                    abort("Invalid Kind.")

    @always_inline
    def _take_kind[
        id: Int
    ](self) raises -> KindPayload[id, Self.origin, Self.mode_id]:
        """Checked extraction by kind id, raising on missing, mismatch, or invalid Trusted scalar.
        """
        comptime assert id != 9, "Cannot extract Kind.Missing."
        comptime R = KindPayload[id, Self.origin, Self.mode_id]
        self._check_kind_or_raise[id]()

        comptime if _is_strict[Self.mode_id]():
            return self._decode_kind_trusted_safe[id]()
        else:
            ref node = self._node()
            comptime match id:
                case 0:
                    var s = decode_string(self.raw_bytes(), node.flags).take()
                    return rebind_var[R](s^)
                case 1:
                    return rebind_var[R](decode_int(self.raw_bytes()).take())
                case 2:
                    return rebind_var[R](decode_float(self.raw_bytes()).take())
                case 3:
                    return rebind_var[R](decode_bool(self.raw_bytes()).take())
                case 4:
                    return rebind_var[R](decode_date(self.raw_bytes()).take())
                case 5:
                    return rebind_var[R](decode_time(self.raw_bytes()).take())
                case 6:
                    return rebind_var[R](
                        decode_datetime(self.raw_bytes()).take()
                    )
                case 7 | 8:
                    return self._decode_kind_trusted_safe[id]()
                case _:
                    raise Error("Invalid Kind.")

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
        comptime if _is_eager[Self.mode_id]():
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
        """Return True if this value is a table containing `key`."""
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

    # --- Unchecked Kind subscript (`val[Kind.Integer]`) ---

    @always_inline
    def __getitem_param__[key: StaticString](self) -> Self:
        """Forward compile-time string subscripts (`toml["key"]`) to `__getitem__`.
        """
        var ks: StaticString = materialize[key]()
        return self[StringSpan(ks)]

    @always_inline
    def __getitem_param__[index: Int](self) -> Self:
        """Forward compile-time integer subscripts (`toml[0]`) to `__getitem__`.
        """
        var idx: Int = materialize[index]()
        return self[idx]

    @always_inline
    def __getitem_param__[
        id: Int, //, k: _Kind[id]
    ](self) -> KindPayload[id, Self.origin, Self.mode_id]:
        """Cast this value to `KindPayload[k]`, aborting on missing, mismatch, or invalid scalar.
        """
        comptime assert id != 9, "Cannot cast to Kind.Missing."
        if self.node_idx == NO_NODE:
            abort("Cannot cast Missing TOML value.")
        if not self._matches_node_kind[id](self._node().kind):
            abort("TOML value Kind does not match requested Kind.")

        comptime if _is_strict[Self.mode_id]():
            return self._decode_kind_trusted_safe[id]()
        else:
            comptime R = KindPayload[id, Self.origin, Self.mode_id]
            ref node = self._node()
            comptime match id:
                case 0:
                    var res = decode_string(self.raw_bytes(), node.flags)
                    if case .Err(_) = res:
                        _ = res^.unsafe_take_error()
                        abort("Invalid TOML string value.")
                    var s = res^.unsafe_take_value()
                    return rebind_var[R](s^)
                case 1:
                    return rebind_var[R](
                        decode_int(self.raw_bytes()).unsafe_take_value()
                    )
                case 2:
                    return rebind_var[R](
                        decode_float(self.raw_bytes()).unsafe_take_value()
                    )
                case 3:
                    return rebind_var[R](
                        decode_bool(self.raw_bytes()).unsafe_take_value()
                    )
                case 4:
                    return rebind_var[R](
                        decode_date(self.raw_bytes()).unsafe_take_value()
                    )
                case 5:
                    return rebind_var[R](
                        decode_time(self.raw_bytes()).unsafe_take_value()
                    )
                case 6:
                    return rebind_var[R](
                        decode_datetime(self.raw_bytes()).unsafe_take_value()
                    )
                case 7 | 8:
                    return self._decode_kind_trusted_safe[id]()
                case _:
                    abort("Invalid Kind.")

    # --- Checked extraction & compile-time reflection (`val.take[T]()`) ---

    def _take_list[Elem: Movable & Deinitable](self) raises -> List[Elem]:
        if not self.is_kind[Kind.Array]():
            raise Error("TOML value is not an Array.")
        var out = List[Elem](capacity=len(self))
        for item in self:
            out.append(item.take[Elem]())
        return out^

    def _take_struct[T: Movable](self) raises -> T:
        if not self.is_kind[Kind.Table]():
            raise Error("TOML value is not a Table.")

        comptime Tr = reflect[T]
        comptime field_types = Tr.field_types()
        comptime field_count = Tr.field_count()
        comptime field_names = Tr.field_names()

        var storage = MaybeUninit[T]()
        var struct_ptr = storage.unsafe_ptr()

        comptime for fi in range(field_count):
            comptime TYPE = field_types[fi]
            comptime RTYPE = reflect[TYPE]
            comptime NAME = field_names[fi]
            comptime assert conforms_to(TYPE, Movable & Deinitable), String(
                t"Each field of struct {Tr.name()} must be Movable and"
                t" Deinitable. field: {NAME} (idx {fi})"
            )

            ref field_ptr = Tr.field_ref[fi](struct_ptr[])

            comptime if RTYPE.base_name() == "Optional":
                comptime assert conforms_to(TYPE, Iterable)
                comptime Inner = TYPE.IteratorType[origin_of()].Element
                comptime assert conforms_to(Inner, Movable & Deinitable)

                if case .Some(child) = self.get(NAME):
                    try:
                        var inner_val = child.take[Inner]()
                        Pointer(to=field_ptr).unsafe_write(
                            rebind_var[TYPE](Optional[Inner](inner_val^))
                        )
                    except e:
                        _destroy_partial_struct[T](storage, fi)
                        storage^.unsafe_forget()
                        raise e^
                else:
                    Pointer(to=field_ptr).unsafe_write(
                        rebind_var[TYPE](Optional[Inner](None))
                    )
            else:
                __guard case .Some(child) = self.get(NAME) else:
                    _destroy_partial_struct[T](storage, fi)
                    storage^.unsafe_forget()
                    raise Error(t"Struct field '{NAME}' missing in table.")
                try:
                    Pointer(to=field_ptr).unsafe_write(child.take[TYPE]())
                except e:
                    _destroy_partial_struct[T](storage, fi)
                    storage^.unsafe_forget()
                    raise e^

        return storage^.unsafe_assume_init()

    def _take_enum[
        E: __Union & Movable & Deinitable
    ](self) raises -> E where _IsValidTomlEnum[E]:
        comptime cases = TypeList[Trait=AnyType, E._enum_case_types]()
        comptime for i in range(cases.length):
            comptime CaseTuple = cases[i]
            comptime elts = TypeList[
                Trait=AnyType, downcast[CaseTuple, __TupleLike].__element_types
            ]()
            comptime Payload = elts[0]
            comptime assert conforms_to(Payload, Movable & Deinitable)
            try:
                var val = self.take[Payload]()
                return E.__enum_init[i](val^)
            except:
                pass
        raise Error(
            String(
                "TOML value of kind ",
                self.kind(),
                " did not match any case of union ",
                reflect[E].name(),
                ".",
            )
        )

    def _take_variant[
        Trait: type_of(AnyType),
        values: _MLIR.KGENParamListType[Trait],
        //,
        ts: TypeList[Trait=Trait, values],
    ](self) raises -> Variant[*ts]:
        comptime assert ts.length > 0, "Variant must declare at least one type."
        comptime for i in range(ts.length):
            comptime Elem = ts[i]
            comptime assert conforms_to(Elem, Movable & Deinitable), String(
                t"Variant element {reflect[Elem].name()} must be Movable and"
                t" Deinitable."
            )
            try:
                var val = self.take[Elem]()
                return Variant[*ts](val^)
            except:
                pass
        raise Error(
            String(
                "TOML value of kind ",
                self.kind(),
                " did not match any variant type.",
            )
        )

    def take[T: Movable & Deinitable](self) raises -> T:
        """Checked extraction into `T` (scalar, temporal, `TomlTable`, `TomlArray`,
        `List`, `Optional`, `__union`, `OneOf`, or struct)."""
        comptime Tr = reflect[T]

        comptime if T == Self:
            return rebind_var[T](self)
        elif T == TomlTable[Self.origin, Self.mode]:
            var tb = self._take_kind[8]()
            return rebind_var[T](tb)
        elif T == TomlArray[Self.origin, Self.mode]:
            var arr = self._take_kind[7]()
            return rebind_var[T](arr)
        elif T == String:
            var s = self._take_kind[0]()
            return rebind_var[T](s^)
        elif T == Int:
            return rebind_var[T](self._take_kind[1]())
        elif T == Float64:
            return rebind_var[T](self._take_kind[2]())
        elif T == Bool:
            return rebind_var[T](self._take_kind[3]())
        elif T == Date:
            return rebind_var[T](self._take_kind[4]())
        elif T == Time:
            return rebind_var[T](self._take_kind[5]())
        elif T == DateTime:
            return rebind_var[T](self._take_kind[6]())
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
        elif conforms_to(T, _VariantConstructible):
            comptime V = downcast[T, _VariantConstructible]
            comptime ts = TypeList[Trait=AnyType, V._variant_types]()
            comptime assert (
                ts.length > 0
            ), "Variant wrapper must declare at least one type."
            return rebind_var[T](V._from_variant(self._take_variant[ts]()))
        elif conforms_to(T, __Union):
            comptime E = downcast[T, __Union & Movable & Deinitable]
            comptime assert _IsValidTomlEnum[E], (
                "Union type must have at least one case and every case must"
                " carry exactly one payload."
            )
            return rebind_var[T](self._take_enum[E]())
        elif Tr.base_name() == "Variant":
            raise Error(
                "Direct Variant reflection is not supported; use take[*Ts](),"
                " take[TypeList](), a __union, or OneOf[*Ts]."
            )
        elif Tr.is_struct():
            return self._take_struct[T]()
        else:
            raise Error("Unsupported target type for Toml.take[T]().")

    def take[
        *Ts: Movable & Deinitable
    ](self) raises -> Variant[*Ts] where Ts.length > 1:
        """Deserialize this TOML value into the first matching type in `Ts`."""
        comptime ts = TypeList[Trait=Movable & Deinitable, Ts.values]()
        return rebind_var[Variant[*Ts]](self._take_variant[ts]())

    def take[
        Trait: type_of(AnyType),
        values: _MLIR.KGENParamListType[Trait],
        //,
        ts: TypeList[Trait=Trait, values],
    ](self) raises -> Variant[*ts] where ts.length > 0:
        """Deserialize this TOML value into the first matching type in `ts`."""
        return self._take_variant[ts]()

    # --- Iteration ---

    @always_inline
    def _table_iter(self) -> TomlIter[Self.origin, Self.mode]:
        if self.node_idx == NO_NODE or self._node().kind != NodeKind.Table:
            return TomlIter[Self.origin, Self.mode](
                self.doc_ptr, self.nodes_ptr, self.store_ptr, NO_NODE, 0
            )
        ref node = self._node()
        return TomlIter[Self.origin, Self.mode](
            self.doc_ptr,
            self.nodes_ptr,
            self.store_ptr,
            node.first_child,
            node.len,
        )

    @always_inline
    def __iter__(self) -> TomlIter[Self.origin, Self.mode]:
        """Iterate children of a table or array in document order."""
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
        return TomlItemIter[Self.origin, Self.mode](self._table_iter())

    @always_inline
    def keys(self) -> TomlKeyIter[Self.origin, Self.mode]:
        """Iterate decoded keys of a table in document order."""
        return TomlKeyIter[Self.origin, Self.mode](self._table_iter())

    # --- Serialization ---

    def to_json[W: Writer](self, mut w: W) raises:
        """Stream this value and its subtree as `toml-test` tagged JSON."""
        _write_node_as_json[Self.mode_id](
            self.doc_ptr, self.nodes_ptr, self.store_ptr, self.node_idx, w
        )

    def write_to(self, mut w: Some[Writer]):
        if self.node_idx == NO_NODE:
            w.write("Toml(Missing)")
            return
        w.write("Toml(")
        match self.kind():
            case .Table:
                w.write("{")
                var first = True
                for entry in self:
                    if not first:
                        w.write(", ")
                    first = False
                    w.write('"', entry._decode_key(), '": ', entry)
                w.write("}")
            case .Array:
                w.write("[")
                var first = True
                for elem in self:
                    if not first:
                        w.write(", ")
                    first = False
                    w.write(elem)
                w.write("]")
            case .String:
                try:
                    w.write("'", self.take[String](), "'")
                except:
                    w.write("<invalid string>")
            case .Integer:
                try:
                    w.write(self.take[Int]())
                except:
                    w.write("<invalid int>")
            case .Float:
                try:
                    w.write(self.take[Float64]())
                except:
                    w.write("<invalid float>")
            case .Boolean:
                try:
                    w.write("true" if self.take[Bool]() else "false")
                except:
                    w.write("<invalid bool>")
            case .Date:
                try:
                    w.write(self.take[Date]())
                except:
                    w.write("<invalid date>")
            case .Time:
                try:
                    w.write(self.take[Time]())
                except:
                    w.write("<invalid time>")
            case .DateTime:
                try:
                    w.write(self.take[DateTime]())
                except:
                    w.write("<invalid datetime>")
            case .Missing:
                w.write("Missing")
        w.write(")")
