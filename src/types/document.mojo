"""Owning `TomlDocument` handle and `Mode.Eager` materialization."""

from std.builtin.variadics import TypeList, _MLIR
from std.collections import List, Span
from std.memory import Pointer, bitcast, unsafe_memcpy
from std.utils import Variant
from std.utils.numerics import nan
from ..mode import Mode
from ..tape.decode import (
    decode_bool_unchecked,
    decode_date_unchecked,
    decode_datetime_unchecked,
    decode_float_unchecked,
    decode_int_unchecked,
    decode_string_to_writer_unchecked,
    decode_time_unchecked,
)
from ..tape.key_index import KEY_ESCAPE_BIT
from ..tape.node import NO_NODE, Node, NodeFlags, NodeKind
from ..tape.reader import _ParsedTape
from .store import _ArenaWriter, _Store
from .tempo import Date, DateTime, Offset
from .view import Toml, TomlItemIter, TomlIter, TomlKeyIter


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
    """Convert a Strict-validated tape into an owned, pre-decoded `Mode.Eager` document.

    Invariant: every TOML 1.1 escape sequence decodes to strictly fewer UTF-8
    bytes than its raw representation, so reserving `src_len + sum(escaped_len)`
    guarantees the arena never reallocates during decoding.
    """
    var nodes, key_index = tape^.into_parts()
    var n_nodes = len(nodes)
    var n_ptr = nodes.unsafe_ptr()
    var src_len = len(data)

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

        match node.kind:
            case .String:
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
                var raw_b = Span[Byte, data.origin](
                    unsafe_ptr=src_ptr.unsafe_offset(Int(node.start)),
                    length=Int(node.len),
                )
                node.start = UInt32(1) if decode_bool_unchecked(
                    raw_b
                ) else UInt32(0)
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
                var slot_start = UInt32(len(array_slots))
                var curr = node.first_child
                while curr != NO_NODE:
                    array_slots.append(curr)
                    curr = n_ptr[unsafe_offset=Int(curr)].next_sibling
                node.start = slot_start
            case .Empty | .Table:
                pass

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
