"""Owning `TomlDocument` handle and single-pass in-place `Mode.Eager` materializer."""

from std.builtin.variadics import TypeList, _MLIR
from std.collections import List, Span
from std.memory import Pointer, bitcast, unsafe_memcpy
from std.utils import Variant
from std.utils.numerics import nan
from ..mode import Mode
from ..result import Result
from ..tape.decode import (
    decode_bool_unchecked,
    decode_date_unchecked,
    decode_datetime_unchecked,
    decode_float_unchecked,
    decode_int_unchecked,
    decode_string_to_buf_unchecked,
    decode_time_unchecked,
)
from ..tape.key_index import KEY_ESCAPE_BIT
from ..tape.node import NO_NODE, Node, NodeFlags, NodeKind
from ..tape.reader import _ParsedTape
from .store import _Store
from .tempo import Date, DateTime, Offset
from .view import (
    Toml,
    TomlItemIter,
    TomlIter,
    TomlKeyIter,
    TomlSpanItemIter,
    TomlSpanKeyIter,
    TomlStrItemIter,
    TomlStrKeyIter,
)


struct TomlDocument[
    mode: Mode,
    origin: ImmOrigin = ImmUntrackedOrigin,
](Movable, Sized, Writable):
    """Owning handle for a parsed TOML document.

    In lazy modes (`Mode.Strict`, `Mode.Trusted`), borrows the source byte span
    (`origin`). In `Mode.Eager`, owns its decoded arena and scalar columns with
    no source lifetime dependency.
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
    def root(ref self) -> Toml[ImmOrigin(origin_of(self)), Self.mode]:
        """Return the root `Toml` table view."""
        var doc_p: Pointer[Byte, ImmOrigin(origin_of(self))]
        comptime if case .Eager = Self.mode:
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
            self.nodes.unsafe_ptr()
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
        return Int(
            self.nodes.unsafe_ptr()[unsafe_offset=Int(self.root_idx)].len
        )

    @always_inline
    def __iter__(ref self) -> TomlIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().__iter__()

    @always_inline
    def items(ref self) -> TomlItemIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().items()

    @always_inline
    def items_span(
        ref self,
    ) -> TomlSpanItemIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().items_span()

    @always_inline
    def eager_items(
        ref self,
    ) -> TomlStrItemIter[ImmOrigin(origin_of(self))] where (
        Self.mode == Mode.Eager
    ):
        return self.root().eager_items()

    @always_inline
    def keys(ref self) -> TomlKeyIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().keys()

    @always_inline
    def keys_span(
        ref self,
    ) -> TomlSpanKeyIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().keys_span()

    @always_inline
    def eager_keys(
        ref self,
    ) -> TomlStrKeyIter[ImmOrigin(origin_of(self))] where (
        Self.mode == Mode.Eager
    ):
        return self.root().eager_keys()

    @always_inline
    def take[T: Movable & Deinitable](ref self) raises -> T:
        return self.root().take[T]()

    @always_inline
    def try_take[T: Movable & Deinitable](ref self) -> Result[T]:
        return self.root().try_take[T]()

    @always_inline
    def take[
        *Ts: Movable & Deinitable
    ](ref self) raises -> Variant[*Ts] where Ts.length > 1:
        return self.root().take[*Ts]()

    @always_inline
    def take[
        Trait: type_of(AnyType),
        values: _MLIR.KGENParamListType[Trait],
        //,
        ts: TypeList[Trait=Trait, values],
    ](ref self) raises -> Variant[*ts] where ts.length > 0:
        return self.root().take[ts]()

    def to_json[W: Writer](ref self, mut w: W) raises:
        self.root().to_json(w)

    def write_to(ref self, mut w: Some[Writer]):
        self.root().write_to(w)


def _materialize(
    data: Span[Byte, _], var tape: _ParsedTape
) -> TomlDocument[Mode.Eager, ImmUntrackedOrigin]:
    """Single-pass in-place materializer converting a Strict-validated tape into `Mode.Eager`.

    Invariant: every TOML 1.1 escape sequence decodes to strictly fewer UTF-8
    bytes than its raw representation, and every node's key/string span is a
    disjoint slice of `data`, so escaped strings and keys decode directly into
    their own disjoint spans within `arena[0..src_len]` with zero extra memory
    and no pre-scan pass.
    """
    var nodes, key_index, array_slots = tape^.into_parts()
    var n_nodes = len(nodes)
    var n_ptr = nodes.unsafe_ptr()
    var src_len = len(data)

    var arena = List[Byte](capacity=src_len)
    if src_len > 0:
        arena.resize(unsafe_uninit_length=src_len)
        unsafe_memcpy(
            dest=arena.unsafe_ptr(), src=data.unsafe_ptr(), count=src_len
        )

    var temporals = List[DateTime]()
    var src_ptr = data.unsafe_ptr()
    var arena_ptr = arena.unsafe_ptr()
    var any_escaped_key = False

    for i in range(n_nodes):
        ref node = n_ptr[unsafe_offset=i]

        if (node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
            var k_off = Int(node.key_start)
            var k_raw = Span[Byte, data.origin](
                unsafe_ptr=src_ptr.unsafe_offset(k_off),
                length=Int(node.key_len),
            )
            var kw_len = decode_string_to_buf_unchecked(
                k_raw, node.key_flags, arena_ptr.unsafe_offset(k_off)
            )
            node.key_len = UInt32(kw_len)
            node.key_tag = arena_ptr[unsafe_offset=k_off] if kw_len > 0 else 0
            node.key_flags = 0
            any_escaped_key = True

        match node.kind:
            case .String:
                if (node.flags & NodeFlags.HAS_ESCAPE) != 0 and (
                    node.flags & NodeFlags.LITERAL
                ) == 0:
                    var s_off = Int(node.start)
                    var s_raw = Span[Byte, data.origin](
                        unsafe_ptr=src_ptr.unsafe_offset(s_off),
                        length=Int(node.len),
                    )
                    var sw_len = decode_string_to_buf_unchecked(
                        s_raw, node.flags, arena_ptr.unsafe_offset(s_off)
                    )
                    node.len = UInt32(sw_len)
                node.flags = 0
            case .Integer:
                var raw_b = Span[Byte, data.origin](
                    unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                var u = bitcast[DType.uint64, 1](
                    Int64(decode_int_unchecked(raw_b, node.flags))
                )
                node.start = UInt32(u & 0xFFFFFFFF)
                node.len = UInt32(u >> 32)
            case .Float | .Inf:
                var raw_b = Span[Byte, data.origin](
                    unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                var u = bitcast[DType.uint64, 1](
                    decode_float_unchecked(raw_b, node.flags)
                )
                node.start = UInt32(u & 0xFFFFFFFF)
                node.len = UInt32(u >> 32)
            case .NaN:
                var u = bitcast[DType.uint64, 1](nan[DType.float64]())
                node.start = UInt32(u & 0xFFFFFFFF)
                node.len = UInt32(u >> 32)
            case .Boolean:
                node.start = UInt32(1) if src_ptr[
                    unsafe_offset=Int(node.start)
                ] == Byte(ord("t")) else UInt32(0)
            case .Date:
                var raw_b = Span[Byte, data.origin](
                    unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                var d = decode_date_unchecked(raw_b)
                node.start = (
                    (UInt32(d.year) << 16)
                    | (UInt32(d.month) << 8)
                    | UInt32(d.day)
                )
            case .Time:
                var raw_b = Span[Byte, data.origin](
                    unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                var idx = UInt32(len(temporals))
                temporals.append(
                    DateTime(
                        Date(year=0, month=0, day=0),
                        decode_time_unchecked(raw_b),
                        Offset(),
                        True,
                    )
                )
                node.start = idx
            case .DateTime:
                var raw_b = Span[Byte, data.origin](
                    unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                var idx = UInt32(len(temporals))
                temporals.append(decode_datetime_unchecked(raw_b))
                node.start = idx
            case .Array:
                if (node.flags & NodeFlags.CONTIGUOUS) == 0 and (
                    node.flags & NodeFlags.SLOTTED
                ) == 0:
                    var slot_start = UInt32(len(array_slots))
                    var curr = node.first_child
                    while curr != NO_NODE:
                        array_slots.append(curr)
                        curr = n_ptr[unsafe_offset=Int(curr)].next_sibling
                    node.start = slot_start
                    node.flags |= NodeFlags.SLOTTED
            case .Empty | .Table:
                pass

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
