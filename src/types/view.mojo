"""Unified 32-byte `Toml` view, typed container views, iterators, and reflection."""

from std.builtin._enum import __Enum, __Union
from std.builtin.enum_like import EnumLike
from std.builtin.rebind import downcast
from std.builtin.tuple import __TupleLike
from std.builtin.variadics import TypeList, _MLIR
from std.collections import Array, Dict, List, Set, Span
from std.memory import MaybeUninit, Pointer, bitcast
from std.os import abort
from std.utils import Variant
from ..mode import Mode
from ..result import Result
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
    decode_string_to_writer,
    decode_string_to_writer_unchecked,
    decode_string_unchecked,
    decode_time,
    decode_time_unchecked,
)
from ..tape.key_index import _bytes_equal
from ..tape.lexer import is_valid_utf8_fast
from ..tape.node import NO_NODE, Node, NodeFlags, NodeKind
from .attr import (
    _effective_case_name,
    _effective_field_name,
    _field_alias_at,
    _field_alias_count,
    _field_has_default_init,
    _field_has_default_value,
    _field_is_flattened,
    _field_is_skipped,
    _struct_deny_unknown,
    _union_content,
    _union_tag,
    _write_field_default,
)
from .json import _write_node_as_json
from .kind import Kind, KindTag, _Kind
from .reflection import (
    _DictKeyType,
    _DictValType,
    _IsFieldlessEnum,
    _IsValidTomlUnion,
    _VariantConstructible,
    _destroy_partial_array,
    _destroy_partial_struct,
    _destroy_partial_tuple,
    _format_leaf_error,
    _init_union_from_case_tuple,
    _static_len,
    _struct_claims_key_bytes,
    _struct_has_flattened_dict,
    _wrap_field_error,
    _wrap_index_error,
    _wrap_key_error,
)
from .store import _Store
from .tempo import Date, DateTime, Time


comptime KindPayload[id: Int, o: ImmOrigin, m: Mode] = TypeList.of[
    String,
    Int,
    Float64,
    Bool,
    Date,
    Time,
    DateTime,
    TomlArray[o, m],
    TomlTable[o, m],
    NoneType,
    StringSpan[o],
]()[id]


# --- Iterators ---


struct TomlIter[
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
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
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
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
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
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


struct TomlSpanItemIter[
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
](
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Iterator,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """Zero-allocation iterator yielding `(Optional[StringSpan], Toml)` pairs in document order.
    """

    comptime Element = Tuple[
        Optional[StringSpan[Self.origin]], Toml[Self.origin, Self.mode]
    ]
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
        return (v.key_span(), v)


struct TomlSpanKeyIter[
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
](
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Iterator,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """Zero-allocation iterator yielding `Optional[StringSpan]` table keys in document order.
    """

    comptime Element = Optional[StringSpan[Self.origin]]
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
        return v.key_span()


struct TomlStrItemIter[
    origin: ImmOrigin,
](
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Iterator,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """Infallible zero-allocation iterator yielding `(StringSpan, Toml)` pairs in `Mode.Eager`.
    """

    comptime Element = Tuple[
        StringSpan[Self.origin], Toml[Self.origin, Mode.Eager]
    ]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var inner: TomlIter[Self.origin, Mode.Eager]

    @always_inline
    def __init__(out self, inner: TomlIter[Self.origin, Mode.Eager]):
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
        return (v.key_str(), v)


struct TomlStrKeyIter[
    origin: ImmOrigin,
](
    Copyable,
    ImplicitlyCopyable,
    Iterable,
    Iterator,
    Movable,
    Sized,
    TrivialRegisterPassable,
):
    """Infallible zero-allocation iterator yielding `StringSpan` keys in `Mode.Eager`.
    """

    comptime Element = StringSpan[Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self

    var inner: TomlIter[Self.origin, Mode.Eager]

    @always_inline
    def __init__(out self, inner: TomlIter[Self.origin, Mode.Eager]):
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
        return v.key_str()


# --- Typed container views ---


struct TomlTable[
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
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
    def items_span(self) -> TomlSpanItemIter[Self.origin, Self.mode]:
        return self.as_toml().items_span()

    @always_inline
    def eager_items(
        self,
    ) -> TomlStrItemIter[Self.origin] where Self.mode == Mode.Eager:
        return self.as_toml().eager_items()

    @always_inline
    def keys(self) -> TomlKeyIter[Self.origin, Self.mode]:
        return self.as_toml().keys()

    @always_inline
    def keys_span(self) -> TomlSpanKeyIter[Self.origin, Self.mode]:
        return self.as_toml().keys_span()

    @always_inline
    def eager_keys(
        self,
    ) -> TomlStrKeyIter[Self.origin] where Self.mode == Mode.Eager:
        return self.as_toml().eager_keys()

    @always_inline
    def take[T: Movable & Deinitable](self) raises -> T:
        return self.as_toml().take[T]()

    @always_inline
    def try_take[T: Movable & Deinitable](self) -> Result[T]:
        return self.as_toml().try_take[T]()

    def to_json[W: Writer](self, mut w: W) raises:
        self.as_toml().to_json(w)

    def write_to(self, mut w: Some[Writer]):
        self.as_toml().write_to(w)


struct TomlArray[
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
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

    @always_inline
    def try_take[T: Movable & Deinitable](self) -> Result[T]:
        return self.as_toml().try_take[T]()

    def to_json[W: Writer](self, mut w: W) raises:
        self.as_toml().to_json(w)

    def write_to(self, mut w: Some[Writer]):
        self.as_toml().write_to(w)


# --- Unified Toml view ---


struct Toml[
    origin: ImmOrigin,
    mode: Mode = Mode.Strict,
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
        ref node = self._node()
        comptime if id == 10:
            if node.kind != NodeKind.String:
                return False
            comptime if Self.mode == Mode.Eager:
                return True
            else:
                return (node.flags & NodeFlags.HAS_ESCAPE) == 0 or (
                    node.flags & NodeFlags.LITERAL
                ) != 0
        return self._matches_node_kind[id](node.kind)

    @always_inline
    def _matches_node_kind[id: Int](self, nk: NodeKind) -> Bool:
        comptime if id == 2:
            return (
                nk == NodeKind.Float or nk == NodeKind.NaN or nk == NodeKind.Inf
            )
        elif id == 10:
            return nk == NodeKind.String
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
        comptime if Self.mode == Mode.Eager:
            return StringSpan(unsafe_from_utf8=self.key_bytes())
        else:
            if (self._node().key_flags & NodeFlags.HAS_ESCAPE) == 0:
                return StringSpan(unsafe_from_utf8=self.key_bytes())
            return None

    @always_inline
    def key_str(
        self,
    ) -> StringSpan[self.origin] where Self.mode == Mode.Eager:
        """Return an infallible zero-copy `StringSpan` of this node's key in `Mode.Eager`.
        """
        if self.node_idx == NO_NODE:
            return StringSpan(
                unsafe_from_utf8=Span[Byte, self.origin](
                    unsafe_ptr=self.doc_ptr, length=0
                )
            )
        return StringSpan(unsafe_from_utf8=self.key_bytes())

    @always_inline
    def key(self) -> String:
        """Return this node's decoded key as an owned `String`."""
        return self._decode_key()

    def _decode_key(self) -> String:
        if self.node_idx == NO_NODE:
            return String()
        ref node = self._node()
        comptime if Self.mode == Mode.Eager:
            return String(StringSpan(unsafe_from_utf8=self.key_bytes()))
        else:
            if (node.key_flags & NodeFlags.HAS_ESCAPE) == 0:
                return String(StringSpan(unsafe_from_utf8=self.key_bytes()))
            comptime if Self.mode == Mode.Strict:
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
        comptime if case Mode.Eager = Self.mode:
            return StringSpan(unsafe_from_utf8=self.raw_bytes())
        else:
            if (node.flags & NodeFlags.HAS_ESCAPE) == 0 or (
                node.flags & NodeFlags.LITERAL
            ) != 0:
                return StringSpan(unsafe_from_utf8=self.raw_bytes())
            return None

    @always_inline
    def as_str(
        self,
    ) -> StringSpan[self.origin] where Self.mode == Mode.Eager:
        """Return an infallible zero-copy `StringSpan` for a `Mode.Eager` string value.
        """
        return self[Kind.Str]

    def write_string_to[W: Writer](self, mut w: W) raises:
        """Stream this string value's decoded UTF-8 bytes directly into `w` without heap allocation.
        """
        self._check_kind_or_raise[0]()
        ref node = self._node()
        comptime if Self.mode == Mode.Eager:
            w.write(StringSpan(unsafe_from_utf8=self.raw_bytes()))
        elif Self.mode == Mode.Strict:
            decode_string_to_writer_unchecked(self.raw_bytes(), node.flags, w)
        else:
            decode_string_to_writer(self.raw_bytes(), node.flags, w).take()

    def write_key_to[W: Writer](self, mut w: W) raises:
        """Stream this node's decoded key directly into `w` without heap allocation.
        """
        if self.node_idx == NO_NODE:
            raise Error("Missing TOML value has no key.")
        ref node = self._node()
        comptime if Self.mode == Mode.Eager:
            w.write(StringSpan(unsafe_from_utf8=self.key_bytes()))
        elif Self.mode == Mode.Strict:
            decode_string_to_writer_unchecked(
                self.key_bytes(), node.key_flags, w
            )
        else:
            decode_string_to_writer(self.key_bytes(), node.key_flags, w).take()

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
            raise self._leaf_err(
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
    ](self) -> KindPayload[id, Self.origin, Self.mode]:
        """Decode a pre-validated (Eager or Strict) node whose kind is already verified.
        """
        comptime R = KindPayload[id, Self.origin, Self.mode]
        ref node = self._node()
        comptime if case .Eager = Self.mode:
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
                case 10:
                    return rebind_var[R](
                        StringSpan(unsafe_from_utf8=self.raw_bytes())
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
                case 10:
                    return rebind_var[R](
                        StringSpan(unsafe_from_utf8=self.raw_bytes())
                    )
                case _:
                    abort("Invalid Kind.")

    @always_inline
    def _take_kind[
        id: Int
    ](self) raises -> KindPayload[id, Self.origin, Self.mode]:
        """Checked extraction by kind id, raising on missing, mismatch, or invalid Trusted scalar.
        """
        comptime assert id != 9, "Cannot extract Kind.Missing."
        comptime R = KindPayload[id, Self.origin, Self.mode]
        self._check_kind_or_raise[id]()

        comptime if id == 10 and Self.mode != Mode.Eager:
            ref snode = self._node()
            if (snode.flags & NodeFlags.HAS_ESCAPE) != 0 and (
                snode.flags & NodeFlags.LITERAL
            ) == 0:
                raise Error(
                    "Cannot borrow escaped TOML string as StringSpan in lazy"
                    " mode; use String or Mode.Eager."
                )

        comptime if Self.mode != Mode.Trusted:
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
                case 10:
                    var rb = self.raw_bytes()
                    if not is_valid_utf8_fast(rb):
                        raise Error("Invalid UTF-8 in TOML string.")
                    return rebind_var[R](StringSpan(unsafe_from_utf8=rb))
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
        """Look up an array element by index in O(1) time."""
        if self.node_idx == NO_NODE:
            return self
        ref node = self._node()
        if node.kind != NodeKind.Array or index < 0 or index >= Int(node.len):
            return self._missing()
        if (node.flags & NodeFlags.CONTIGUOUS) != 0:
            return Self(
                self.doc_ptr,
                self.nodes_ptr,
                self.store_ptr,
                node.first_child + UInt32(index),
            )
        if (node.flags & NodeFlags.SLOTTED) != 0:
            var child_idx = self.store_ptr[].array_slots.unsafe_ptr()[
                unsafe_offset=Int(node.start) + index
            ]
            return Self(self.doc_ptr, self.nodes_ptr, self.store_ptr, child_idx)
        var curr = node.first_child
        var i = 0
        while curr != NO_NODE:
            if i == index:
                return Self(self.doc_ptr, self.nodes_ptr, self.store_ptr, curr)
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
    ](self) -> KindPayload[id, Self.origin, Self.mode]:
        """Cast this value to `KindPayload[k]`, aborting on missing, mismatch, or invalid scalar.
        """
        comptime assert id != 9, "Cannot cast to Kind.Missing."
        if self.node_idx == NO_NODE:
            abort("Cannot cast Missing TOML value.")
        ref node = self._node()
        if not self._matches_node_kind[id](node.kind):
            abort("TOML value Kind does not match requested Kind.")
        comptime if id == 10 and Self.mode != Mode.Eager:
            if (node.flags & NodeFlags.HAS_ESCAPE) != 0 and (
                node.flags & NodeFlags.LITERAL
            ) == 0:
                abort(
                    "Cannot cast escaped TOML string to Kind.Str in lazy mode."
                )

        comptime if Self.mode != Mode.Trusted:
            return self._decode_kind_trusted_safe[id]()
        else:
            comptime R = KindPayload[id, Self.origin, Self.mode]
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
                case 10:
                    var rb = self.raw_bytes()
                    if not is_valid_utf8_fast(rb):
                        abort("Invalid UTF-8 in TOML string.")
                    return rebind_var[R](StringSpan(unsafe_from_utf8=rb))
                case _:
                    abort("Invalid Kind.")

    # --- Checked extraction & compile-time reflection (`val.take[T]()`) ---

    @inline(.never)
    def _leaf_err(self, msg: StringSpan) -> Error:
        return _format_leaf_error[Self.mode](
            self.doc_ptr, self.nodes_ptr, self.node_idx, msg
        )

    def _take_list[Elem: Movable & Deinitable](self) raises -> List[Elem]:
        if not self.is_kind[Kind.Array]():
            raise self._leaf_err("TOML value is not an Array.")
        var out = List[Elem](capacity=len(self))
        var idx = 0
        for item in self:
            try:
                out.append(item.take[Elem]())
            except e:
                raise _wrap_index_error[Self.mode](
                    idx, e, item.doc_ptr, item.nodes_ptr, item.node_idx
                )
            idx += 1
        return out^

    def _take_set[T: Movable & Deinitable](self) raises -> T:
        if not self.is_kind[Kind.Array]():
            raise self._leaf_err("TOML value is not an Array.")
        comptime assert conforms_to(T, Iterable)
        comptime Elem = T.IteratorType[origin_of()].Element
        comptime assert conforms_to(Elem, KeyElement & Deinitable)
        var out = Set[Elem]()
        var idx = 0
        for item in self:
            try:
                out.add(item.take[Elem]())
            except e:
                raise _wrap_index_error[Self.mode](
                    idx, e, item.doc_ptr, item.nodes_ptr, item.node_idx
                )
            idx += 1
        return rebind_var[T](out^)

    def _take_tuple[T: __TupleLike & Movable & Deinitable](self) raises -> T:
        if not self.is_kind[Kind.Array]():
            raise self._leaf_err("TOML value is not an Array.")
        comptime elts = TypeList[Trait=AnyType, T.__element_types]()
        comptime N = elts.length
        if len(self) != N:
            raise self._leaf_err(
                String(
                    "Tuple length mismatch: expected ",
                    N,
                    " elements, got ",
                    len(self),
                    ".",
                )
            )
        var storage = MaybeUninit[T]()
        var tup_ptr = storage.unsafe_ptr()
        var it = self.__iter__()
        comptime for i in range(N):
            comptime Elem = elts[i]
            comptime assert conforms_to(Elem, Movable & Deinitable)
            try:
                var item = it.__next__()
                try:
                    Pointer(to=tup_ptr[][i]).unsafe_write(item.take[Elem]())
                except e:
                    raise _wrap_index_error[Self.mode](
                        i, e, item.doc_ptr, item.nodes_ptr, item.node_idx
                    )
            except e:
                _destroy_partial_tuple[T](storage, i)
                storage^.unsafe_forget()
                raise e^
        return storage^.unsafe_assume_init()

    def _take_array[T: Movable & Deinitable](self) raises -> T:
        if not self.is_kind[Kind.Array]():
            raise self._leaf_err("TOML value is not an Array.")
        comptime assert conforms_to(T, Iterable)
        comptime Elem = T.IteratorType[origin_of()].Element
        comptime assert conforms_to(Elem, Movable & Deinitable)
        comptime N = _static_len[T]()
        if len(self) != N:
            raise self._leaf_err(
                String(
                    "Array length mismatch: expected ",
                    N,
                    " elements, got ",
                    len(self),
                    ".",
                )
            )
        var storage = MaybeUninit[T]()
        var elem_ptr = storage.unsafe_ptr().unsafe_bitcast[Elem]()
        var idx = 0
        for item in self:
            try:
                elem_ptr.unsafe_offset(idx).unsafe_write(item.take[Elem]())
            except e:
                _destroy_partial_array(elem_ptr, idx)
                storage^.unsafe_forget()
                raise _wrap_index_error[Self.mode](
                    idx, e, item.doc_ptr, item.nodes_ptr, item.node_idx
                )
            idx += 1
        return storage^.unsafe_assume_init()

    @always_inline
    def _parse_enum_from_bytes[
        E: __Enum
    ](self, bytes: Span[Byte, _]) raises -> E:
        comptime cases = TypeList[Trait=AnyType, E._enum_case_types]()
        comptime for i in range(cases.length):
            comptime CNAME = _effective_case_name[E, i]()
            var cs: StaticString = materialize[CNAME]()
            if bytes == cs.as_bytes():
                return E.__enum_init[i]()
        raise self._leaf_err(
            String(
                "Unknown variant '",
                StringSpan(unsafe_from_utf8=bytes),
                "' for enum ",
                reflect[E].name(),
                ".",
            )
        )

    def _take_fieldless_enum[E: __Enum](self) raises -> E:
        if not self.is_kind[Kind.String]():
            raise self._leaf_err(
                String(
                    "TOML kind mismatch: expected String for enum ",
                    reflect[E].name(),
                    ", got ",
                    self.kind(),
                    ".",
                )
            )
        if case .Some(sp) = self.string_span():
            comptime if Self.mode == Mode.Trusted:
                if not is_valid_utf8_fast(sp.as_bytes()):
                    raise self._leaf_err("Invalid UTF-8 in TOML string.")
            return self._parse_enum_from_bytes[E](sp.as_bytes())
        var decoded = self._take_kind[0]()
        return self._parse_enum_from_bytes[E](decoded.as_bytes())

    def _decode_dict_key[K: KeyElement & Deinitable](self) raises -> K:
        comptime if K == String:
            var ks: String
            comptime if Self.mode == Mode.Trusted:
                ref node = self._node()
                if (node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
                    ks = decode_string(self.key_bytes(), node.key_flags).take()
                else:
                    var kb = self.key_bytes()
                    if not is_valid_utf8_fast(kb):
                        raise self._leaf_err("Invalid UTF-8 in TOML table key.")
                    ks = String(StringSpan(unsafe_from_utf8=kb))
            else:
                ks = self._decode_key()
            return rebind_var[K](ks^)
        elif K == StringSpan[Self.origin]:
            comptime if Self.mode == Mode.Eager:
                return rebind_var[K](self.key_str())
            else:
                ref node = self._node()
                if (node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
                    raise self._leaf_err(
                        "Cannot borrow escaped TOML key as StringSpan in lazy"
                        " mode; use String or Mode.Eager."
                    )
                var kb = self.key_bytes()
                comptime if Self.mode == Mode.Trusted:
                    if not is_valid_utf8_fast(kb):
                        raise self._leaf_err("Invalid UTF-8 in TOML table key.")
                return rebind_var[K](StringSpan(unsafe_from_utf8=kb))
        elif _IsFieldlessEnum[K]:
            comptime E = downcast[K, __Enum]
            if case .Some(ksp) = self.key_span():
                comptime if Self.mode == Mode.Trusted:
                    if not is_valid_utf8_fast(ksp.as_bytes()):
                        raise self._leaf_err("Invalid UTF-8 in TOML table key.")
                return rebind_var[K](
                    self._parse_enum_from_bytes[E](ksp.as_bytes())
                )
            var ks = self._decode_key()
            return rebind_var[K](self._parse_enum_from_bytes[E](ks.as_bytes()))
        else:
            comptime assert False, String(
                t"Unsupported Dict key type {reflect[K].name()} for"
                t" Toml.take[Dict](); expected String, StringSpan, or __enum."
            )

    def _take_dict_filtered[
        T: Movable & Deinitable,
        ParentT: AnyType,
        filter_known: Bool,
    ](self, ignore_key: StaticString, mut matched_count: Int) raises -> T:
        if not self.is_kind[Kind.Table]():
            raise self._leaf_err("TOML value is not a Table.")
        comptime assert conforms_to(T, Iterable)
        comptime K = _DictKeyType[T]
        comptime V = _DictValType[T]
        comptime assert conforms_to(K, KeyElement & Deinitable)
        comptime assert conforms_to(V, Movable & Deinitable)

        var out = Dict[K, V]()
        for child in self:
            comptime if filter_known:
                var skip_child = False
                if case .Some(ksp) = child.key_span():
                    var kb = ksp.as_bytes()
                    if (
                        ignore_key.byte_length() > 0
                        and kb == ignore_key.as_bytes()
                    ) or _struct_claims_key_bytes[ParentT](kb):
                        skip_child = True
                else:
                    var k_check_str = child._decode_key()
                    var kb = k_check_str.as_bytes()
                    if (
                        ignore_key.byte_length() > 0
                        and kb == ignore_key.as_bytes()
                    ) or _struct_claims_key_bytes[ParentT](kb):
                        skip_child = True
                if skip_child:
                    continue
                matched_count += 1

            var key_val = child._decode_dict_key[K]()
            try:
                out[key_val^] = child.take[V]()
            except e:
                var key_label = child._decode_key()
                raise _wrap_key_error[Self.mode](
                    StringSpan(key_label),
                    e,
                    child.doc_ptr,
                    child.nodes_ptr,
                    child.node_idx,
                )
        return rebind_var[T](out^)

    @always_inline
    def _get_field[name: StaticString](self, mut hint_idx: UInt32) -> Self:
        """O(1) sequential-cursor field lookup with automatic fallback to `KeyIndex`.
        """
        comptime NAME_LEN = name.byte_length()
        var name_s: StaticString = materialize[name]()
        if hint_idx != NO_NODE:
            ref cnode = self.nodes_ptr[unsafe_offset=Int(hint_idx)]
            if (
                (cnode.key_flags & NodeFlags.HAS_ESCAPE) == 0
                and Int(cnode.key_len) == NAME_LEN
                and _bytes_equal(
                    self.doc_ptr.unsafe_offset(Int(cnode.key_start)),
                    name_s.unsafe_ptr(),
                    NAME_LEN,
                )
            ):
                var matched = hint_idx
                hint_idx = cnode.next_sibling
                return Self(
                    self.doc_ptr, self.nodes_ptr, self.store_ptr, matched
                )
        var found = self.store_ptr[].key_index.find_by_bytes(
            self.node_idx, name_s.as_bytes(), self.nodes_ptr, self.doc_ptr
        )
        if found != NO_NODE:
            hint_idx = self.nodes_ptr[unsafe_offset=Int(found)].next_sibling
        return Self(self.doc_ptr, self.nodes_ptr, self.store_ptr, found)

    @always_inline
    def _get_field_with_aliases[
        T: AnyType, fi: Int
    ](self, mut hint_idx: UInt32) -> Self:
        comptime NAME = _effective_field_name[T, fi]()
        var child = self._get_field[NAME](hint_idx)
        comptime ALIAS_N = _field_alias_count[T, fi]()
        comptime if ALIAS_N > 0:
            comptime for ai in range(ALIAS_N):
                if child.node_idx == NO_NODE:
                    comptime ALIAS = _field_alias_at[T, fi, ai]()
                    child = self._get_field[ALIAS](hint_idx)
        return child

    @inline(.never)
    def _raise_unknown_field_error[
        T: AnyType
    ](self, ignore_key: StaticString) raises:
        for child in self:
            var ks = child._decode_key()
            var kb = ks.as_bytes()
            if ignore_key.byte_length() > 0 and kb == ignore_key.as_bytes():
                continue
            if not _struct_claims_key_bytes[T](kb):
                raise child._leaf_err(
                    String(
                        "Unknown field '",
                        ks,
                        "' in struct ",
                        reflect[T].name(),
                        ".",
                    )
                )
        raise self._leaf_err(
            String(
                "Duplicate or conflicting keys in table for struct ",
                reflect[T].name(),
                ".",
            )
        )

    def _take_struct_impl[
        T: Movable
    ](self, mut total_matched: Int, ignore_key: StaticString = "") raises -> T:
        if not self.is_kind[Kind.Table]():
            raise self._leaf_err("TOML value is not a Table.")

        comptime Tr = reflect[T]
        comptime field_types = Tr.field_types()
        comptime field_count = Tr.field_count()

        var storage = MaybeUninit[T]()
        var struct_ptr = storage.unsafe_ptr()
        var hint_idx = self._node().first_child

        comptime for fi in range(field_count):
            comptime TYPE = field_types[fi]
            comptime RTYPE = reflect[TYPE]
            comptime NAME = _effective_field_name[T, fi]()
            comptime assert conforms_to(TYPE, Movable & Deinitable), String(
                t"Each field of struct {Tr.name()} must be Movable and"
                t" Deinitable. field: {NAME} (idx {fi})"
            )

            ref field_ptr = Tr.field_ref[fi](struct_ptr[])

            comptime if _field_is_skipped[T, fi]():
                try:
                    _write_field_default[T, fi, TYPE](Pointer(to=field_ptr))
                except e:
                    _destroy_partial_struct[T](storage, fi)
                    storage^.unsafe_forget()
                    raise _wrap_field_error[Self.mode](
                        NAME, e, self.doc_ptr, self.nodes_ptr, self.node_idx
                    )
            elif _field_is_flattened[T, fi]():
                try:
                    comptime if RTYPE.base_name() == "Dict":
                        Pointer(to=field_ptr).unsafe_write(
                            self._take_dict_filtered[TYPE, T, True](
                                ignore_key, total_matched
                            )
                        )
                    else:
                        Pointer(to=field_ptr).unsafe_write(
                            self._take_struct_impl[TYPE](
                                total_matched, ignore_key
                            )
                        )
                except e:
                    _destroy_partial_struct[T](storage, fi)
                    storage^.unsafe_forget()
                    raise e^
            else:
                var child = self._get_field_with_aliases[T, fi](hint_idx)

                if child.node_idx != NO_NODE:
                    total_matched += 1
                    comptime if RTYPE.base_name() == "Optional":
                        comptime assert conforms_to(TYPE, Iterable)
                        comptime Inner = TYPE.IteratorType[origin_of()].Element
                        comptime assert conforms_to(Inner, Movable & Deinitable)
                        try:
                            var inner_val = child.take[Inner]()
                            Pointer(to=field_ptr).unsafe_write(
                                rebind_var[TYPE](Optional[Inner](inner_val^))
                            )
                        except e:
                            _destroy_partial_struct[T](storage, fi)
                            storage^.unsafe_forget()
                            raise _wrap_field_error[Self.mode](
                                NAME,
                                e,
                                child.doc_ptr,
                                child.nodes_ptr,
                                child.node_idx,
                            )
                    else:
                        try:
                            Pointer(to=field_ptr).unsafe_write(
                                child.take[TYPE]()
                            )
                        except e:
                            _destroy_partial_struct[T](storage, fi)
                            storage^.unsafe_forget()
                            raise _wrap_field_error[Self.mode](
                                NAME,
                                e,
                                child.doc_ptr,
                                child.nodes_ptr,
                                child.node_idx,
                            )
                else:
                    comptime if _field_has_default_value[
                        T, fi
                    ]() or _field_has_default_init[T, fi]():
                        try:
                            _write_field_default[T, fi, TYPE](
                                Pointer(to=field_ptr)
                            )
                        except e:
                            _destroy_partial_struct[T](storage, fi)
                            storage^.unsafe_forget()
                            raise _wrap_field_error[Self.mode](
                                NAME,
                                e,
                                self.doc_ptr,
                                self.nodes_ptr,
                                self.node_idx,
                            )
                    elif RTYPE.base_name() == "Optional":
                        comptime assert conforms_to(TYPE, Iterable)
                        comptime Inner = TYPE.IteratorType[origin_of()].Element
                        comptime assert conforms_to(Inner, Movable & Deinitable)
                        Pointer(to=field_ptr).unsafe_write(
                            rebind_var[TYPE](Optional[Inner](None))
                        )
                    else:
                        _destroy_partial_struct[T](storage, fi)
                        storage^.unsafe_forget()
                        raise self._leaf_err(
                            String(t"Struct field '{NAME}' missing in table.")
                        )

        return storage^.unsafe_assume_init()

    def _take_struct_checked[
        T: Movable & Deinitable
    ](self, ignore_key: StaticString = "") raises -> T:
        var matched_count = 0
        var res = self._take_struct_impl[T](matched_count, ignore_key)
        comptime if _struct_deny_unknown[
            T
        ]() and not _struct_has_flattened_dict[T]():
            var expected = len(self) - (
                1 if ignore_key.byte_length() > 0 else 0
            )
            if matched_count != expected:
                self._raise_unknown_field_error[T](ignore_key)
        return res^

    def _take_struct[T: Movable & Deinitable](self) raises -> T:
        return self._take_struct_checked[T]()

    def _take_union_case_from_node[
        E: __Union & Movable & Deinitable,
        case_idx: Int,
        ignore_key: StaticString = "",
    ](self) raises -> E:
        comptime CaseTuple = TypeList[Trait=AnyType, E._enum_case_types]()[
            case_idx
        ]
        comptime assert conforms_to(
            CaseTuple, __TupleLike & Movable & Deinitable
        )
        comptime elts = TypeList[Trait=AnyType, CaseTuple.__element_types]()
        comptime if elts.length == 0:
            return E.__enum_init[case_idx]()
        elif elts.length == 1:
            comptime Payload = elts[0]
            comptime assert conforms_to(Payload, Movable & Deinitable)
            comptime if ignore_key.byte_length() > 0:
                comptime assert reflect[Payload].is_struct(), (
                    "Internally tagged union case payload must be a struct or"
                    " empty."
                )
                var val = self._take_struct_checked[Payload](ignore_key)
                return E.__enum_init[case_idx](val^)
            else:
                var val = self.take[Payload]()
                return E.__enum_init[case_idx](val^)
        else:
            var tup = self._take_tuple[CaseTuple]()
            return _init_union_from_case_tuple[E, case_idx](tup^)

    def _take_union[
        E: __Union & Movable & Deinitable
    ](self) raises -> E where _IsValidTomlUnion[E]:
        comptime cases = TypeList[Trait=AnyType, E._enum_case_types]()
        comptime tag_opt = _union_tag[E]()
        comptime content_opt = _union_content[E]()

        # 1. Internally or adjacently tagged union (`@__annotation(toml_attr.tag(...))`)
        comptime if case .Some(tag_key) = tag_opt:
            if not self.is_kind[Kind.Table]():
                raise self._leaf_err(
                    String(
                        "Tagged union ",
                        reflect[E].name(),
                        " requires a TOML Table, got ",
                        self.kind(),
                        ".",
                    )
                )
            var tag_s: StaticString = materialize[tag_key]()
            var tag_node = self[StringSpan(tag_s)]
            if tag_node.node_idx == NO_NODE:
                raise self._leaf_err(
                    String(
                        "Missing union tag field '",
                        tag_s,
                        "' for ",
                        reflect[E].name(),
                        ".",
                    )
                )
            var tag_val = tag_node.take[String]()
            var tag_bytes = tag_val.as_bytes()

            comptime for i in range(cases.length):
                comptime CNAME = _effective_case_name[E, i]()
                var cs: StaticString = materialize[CNAME]()
                if tag_bytes == cs.as_bytes():
                    comptime CaseTuple = cases[i]
                    comptime assert conforms_to(CaseTuple, __TupleLike)
                    comptime elts = TypeList[
                        Trait=AnyType, CaseTuple.__element_types
                    ]()
                    comptime if case .Some(content_key) = content_opt:
                        comptime if elts.length == 0:
                            return E.__enum_init[i]()
                        else:
                            var cont_s: StaticString = materialize[
                                content_key
                            ]()
                            var cont_node = self[StringSpan(cont_s)]
                            if cont_node.node_idx == NO_NODE:
                                raise self._leaf_err(
                                    String(
                                        "Missing union content field '",
                                        cont_s,
                                        "' for case '",
                                        cs,
                                        "'.",
                                    )
                                )
                            try:
                                return cont_node._take_union_case_from_node[
                                    E, i
                                ]()
                            except e:
                                raise _wrap_field_error[Self.mode](
                                    content_key,
                                    e,
                                    cont_node.doc_ptr,
                                    cont_node.nodes_ptr,
                                    cont_node.node_idx,
                                )
                    else:
                        return self._take_union_case_from_node[E, i, tag_key]()

            raise tag_node._leaf_err(
                String(
                    "Unknown union tag '",
                    tag_val,
                    "' for ",
                    reflect[E].name(),
                    ".",
                )
            )

        # 2. Unit case matched from TOML String (`"none"`)
        if self.is_kind[Kind.String]():
            var str_val = self._take_kind[0]()
            var sb = str_val.as_bytes()
            comptime for i in range(cases.length):
                comptime CaseTuple = cases[i]
                comptime assert conforms_to(CaseTuple, __TupleLike)
                comptime elts = TypeList[
                    Trait=AnyType, CaseTuple.__element_types
                ]()
                comptime if elts.length == 0:
                    comptime CNAME = _effective_case_name[E, i]()
                    var cs: StaticString = materialize[CNAME]()
                    if sb == cs.as_bytes():
                        return E.__enum_init[i]()

        # 3. Externally tagged single-key TOML Table (`{ tcp = ... }`)
        if self.is_kind[Kind.Table]() and len(self) == 1:
            var sole_idx = self._node().first_child
            var sole_child = Self(
                self.doc_ptr, self.nodes_ptr, self.store_ptr, sole_idx
            )
            var sole_key = sole_child._decode_key()
            var kb = sole_key.as_bytes()
            comptime for i in range(cases.length):
                comptime CaseTuple = cases[i]
                comptime assert conforms_to(CaseTuple, __TupleLike)
                comptime elts = TypeList[
                    Trait=AnyType, CaseTuple.__element_types
                ]()
                comptime if elts.length > 0:
                    comptime CNAME = _effective_case_name[E, i]()
                    var cs: StaticString = materialize[CNAME]()
                    if kb == cs.as_bytes():
                        try:
                            return sole_child._take_union_case_from_node[E, i]()
                        except:
                            pass

        # 4. Untagged payload matching in declaration order
        comptime for i in range(cases.length):
            comptime CaseTuple = cases[i]
            comptime assert conforms_to(CaseTuple, __TupleLike)
            comptime elts = TypeList[Trait=AnyType, CaseTuple.__element_types]()
            comptime if elts.length == 1:
                try:
                    return self._take_union_case_from_node[E, i]()
                except:
                    pass
            elif elts.length > 1:
                if self.is_kind[Kind.Array]():
                    try:
                        return self._take_union_case_from_node[E, i]()
                    except:
                        pass

        raise self._leaf_err(
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
        raise self._leaf_err(
            String(
                "TOML value of kind ",
                self.kind(),
                " did not match any variant type.",
            )
        )

    def take[T: Movable & Deinitable](self) raises -> T:
        """Checked extraction into `T` (scalar, temporal, `TomlTable`, `TomlArray`,
        `List`, `Array`, `Tuple`, `Set`, `Dict`, `Optional`, `__enum`, `__union`,
        `OneOf`, or struct)."""
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
        elif T == StringSpan[Self.origin]:
            var sp = self._take_kind[10]()
            return rebind_var[T](sp)
        elif T == Int:
            return rebind_var[T](self._take_kind[1]())
        elif T == Int64:
            return rebind_var[T](Int64(self._take_kind[1]()))
        elif T == Int32:
            var iv = self._take_kind[1]()
            if iv < -2147483648 or iv > 2147483647:
                raise self._leaf_err("TOML integer out of Int32 range.")
            return rebind_var[T](Int32(iv))
        elif T == Int16:
            var iv = self._take_kind[1]()
            if iv < -32768 or iv > 32767:
                raise self._leaf_err("TOML integer out of Int16 range.")
            return rebind_var[T](Int16(iv))
        elif T == Int8:
            var iv = self._take_kind[1]()
            if iv < -128 or iv > 127:
                raise self._leaf_err("TOML integer out of Int8 range.")
            return rebind_var[T](Int8(iv))
        elif T == UInt:
            var iv = self._take_kind[1]()
            if iv < 0:
                raise self._leaf_err(
                    "Negative TOML integer cannot convert to UInt."
                )
            return rebind_var[T](UInt(iv))
        elif T == UInt64:
            var iv = self._take_kind[1]()
            if iv < 0:
                raise self._leaf_err(
                    "Negative TOML integer cannot convert to UInt64."
                )
            return rebind_var[T](UInt64(iv))
        elif T == UInt32:
            var iv = self._take_kind[1]()
            if iv < 0 or iv > 4294967295:
                raise self._leaf_err("TOML integer out of UInt32 range.")
            return rebind_var[T](UInt32(iv))
        elif T == UInt16:
            var iv = self._take_kind[1]()
            if iv < 0 or iv > 65535:
                raise self._leaf_err("TOML integer out of UInt16 range.")
            return rebind_var[T](UInt16(iv))
        elif T == UInt8:
            var iv = self._take_kind[1]()
            if iv < 0 or iv > 255:
                raise self._leaf_err("TOML integer out of UInt8 range.")
            return rebind_var[T](UInt8(iv))
        elif T == Float64:
            return rebind_var[T](self._take_kind[2]())
        elif T == Float32:
            return rebind_var[T](Float32(self._take_kind[2]()))
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
        elif Tr.base_name() == "Array":
            return self._take_array[T]()
        elif Tr.base_name() == "Set":
            return self._take_set[T]()
        elif Tr.base_name() == "Dict":
            var dummy_matched = 0
            return self._take_dict_filtered[T, NoneType, False](
                "", dummy_matched
            )
        elif conforms_to(T, __TupleLike):
            comptime Tup = downcast[T, __TupleLike & Movable & Deinitable]
            return rebind_var[T](self._take_tuple[Tup]())
        elif conforms_to(T, _VariantConstructible):
            comptime V = downcast[T, _VariantConstructible]
            comptime ts = TypeList[Trait=AnyType, V._variant_types]()
            comptime assert (
                ts.length > 0
            ), "Variant wrapper must declare at least one type."
            return rebind_var[T](V._from_variant(self._take_variant[ts]()))
        elif _IsFieldlessEnum[T]:
            comptime E = downcast[T, __Enum]
            return rebind_var[T](self._take_fieldless_enum[E]())
        elif conforms_to(T, __Union):
            comptime E = downcast[T, __Union & Movable & Deinitable]
            comptime assert _IsValidTomlUnion[E], (
                "Union type must have at least one case and all case payloads"
                " must be Movable and Deinitable."
            )
            return rebind_var[T](self._take_union[E]())
        elif Tr.base_name() == "Variant":
            raise self._leaf_err(
                "Direct Variant reflection is not supported; use take[*Ts](),"
                " take[TypeList](), a __union, or OneOf[*Ts]."
            )
        elif Tr.is_struct():
            return self._take_struct[T]()
        else:
            raise self._leaf_err("Unsupported target type for Toml.take[T]().")

    def try_take[T: Movable & Deinitable](self) -> Result[T]:
        """Non-raising extraction into `T` returning `Result[T]` (usable at `comptime`).
        """
        try:
            return .Ok(self.take[T]())
        except e:
            return .Err(String(e))

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
    def items_span(self) -> TomlSpanItemIter[Self.origin, Self.mode]:
        """Iterate `(Optional[StringSpan], value)` pairs with zero heap allocation.
        """
        return TomlSpanItemIter[Self.origin, Self.mode](self._table_iter())

    @always_inline
    def eager_items(
        self,
    ) -> TomlStrItemIter[Self.origin] where Self.mode == Mode.Eager:
        """Iterate `(StringSpan, value)` pairs in `Mode.Eager` with zero heap allocation.
        """
        return TomlStrItemIter[Self.origin](
            rebind_var[TomlIter[Self.origin, Mode.Eager]](self._table_iter())
        )

    @always_inline
    def keys(self) -> TomlKeyIter[Self.origin, Self.mode]:
        """Iterate decoded keys of a table in document order."""
        return TomlKeyIter[Self.origin, Self.mode](self._table_iter())

    @always_inline
    def keys_span(self) -> TomlSpanKeyIter[Self.origin, Self.mode]:
        """Iterate `Optional[StringSpan]` keys of a table with zero heap allocation.
        """
        return TomlSpanKeyIter[Self.origin, Self.mode](self._table_iter())

    @always_inline
    def eager_keys(
        self,
    ) -> TomlStrKeyIter[Self.origin] where Self.mode == Mode.Eager:
        """Iterate `StringSpan` keys of a `Mode.Eager` table with zero heap allocation.
        """
        return TomlStrKeyIter[Self.origin](
            rebind_var[TomlIter[Self.origin, Mode.Eager]](self._table_iter())
        )

    # --- Serialization ---

    def to_json[W: Writer](self, mut w: W) raises:
        """Stream this value and its subtree as `toml-test` tagged JSON."""
        _write_node_as_json[Self.mode](
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
