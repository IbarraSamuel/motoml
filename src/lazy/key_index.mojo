"""Flat hash index for O(1) table key lookups and collision detection.
"""

from .node import Node, NodeFlags, KeySeg, NO_NODE
from .scalar_decode import decode_string, decode_string_to_writer
from std.collections import Span, List

comptime FNV_OFFSET_BASIS: UInt32 = 2166136261
comptime FNV_PRIME: UInt32 = 16777619
comptime KEY_ESCAPE_BIT: UInt32 = 0x80000000


@always_inline
def hash_raw_bytes(ptr: Pointer[Byte, _], length: Int) -> UInt32:
    """Compute a parent-independent 32-bit FNV-1a hash over a raw byte range."""
    var h: UInt32 = FNV_OFFSET_BASIS
    for i in range(length):
        h = (h ^ UInt32(ptr[unsafe_offset=i])) * FNV_PRIME
    return h


@always_inline
def mix_parent_hash(key_hash: UInt32, parent: UInt32) -> UInt32:
    """Combine a precomputed key hash with its scoping parent node index."""
    var h = key_hash ^ (parent * 0x9E3779B9)
    h ^= h >> 15
    h *= 0x85EBCA6B
    h ^= h >> 13
    return h


@always_inline
def hash_key(parent: UInt32, key: Span[Byte, _]) -> UInt32:
    """Compute a 32-bit hash over a raw byte slice scoped by parent table index.
    """
    return mix_parent_hash(hash_raw_bytes(key.unsafe_ptr(), len(key)), parent)


@always_inline
def compute_escaped_key_hash(
    raw_bytes: Span[Byte, _], mut scratch: String
) -> Tuple[Bool, UInt32]:
    """Decode an escaped key into `scratch` and return `(ok, logical_fnv1a_hash)`.
    """
    scratch.resize(unsafe_uninit_length=0)
    var res = decode_string_to_writer(raw_bytes, NodeFlags.HAS_ESCAPE, scratch)
    if case .Ok = res:
        _ = res^.unsafe_take_value()
        var sb = scratch.as_bytes()
        return (True, hash_raw_bytes(sb.unsafe_ptr(), len(sb)))
    else:
        _ = res^.unsafe_take_error()
        return (False, hash_raw_bytes(raw_bytes.unsafe_ptr(), len(raw_bytes)))


@always_inline
def keys_equal_slow(
    s1: UInt32,
    l1: UInt32,
    esc1: Bool,
    s2: UInt32,
    l2: UInt32,
    esc2: Bool,
    doc_bytes: Span[Byte, _],
) -> Bool:
    """Compare two key segments when at least one contains escape sequences."""
    var str1 = String()
    if esc1:
        var r1 = decode_string(
            doc_bytes[Int(s1) : Int(s1 + l1)], NodeFlags.HAS_ESCAPE
        )
        if case .Ok(var s) = r1:
            str1 = s^
            _ = r1^.unsafe_take_value()
        else:
            _ = r1^.unsafe_take_error()
    else:
        str1 = String(
            StringSpan(unsafe_from_utf8=doc_bytes[Int(s1) : Int(s1 + l1)])
        )

    var str2 = String()
    if esc2:
        var r2 = decode_string(
            doc_bytes[Int(s2) : Int(s2 + l2)], NodeFlags.HAS_ESCAPE
        )
        if case .Ok(var s) = r2:
            str2 = s^
            _ = r2^.unsafe_take_value()
        else:
            _ = r2^.unsafe_take_error()
    else:
        str2 = String(
            StringSpan(unsafe_from_utf8=doc_bytes[Int(s2) : Int(s2 + l2)])
        )

    return str1 == str2


struct KeySlot(Copyable, Movable, TrivialRegisterPassable):
    """A 16-byte entry in the open-addressing key index hash table."""

    var parent: UInt32
    var node_idx: UInt32
    var hash_val: UInt32
    var key_len_flags: UInt32

    @always_inline
    def __init__(
        out self,
        parent: UInt32 = 0,
        node_idx: UInt32 = NO_NODE,
        hash_val: UInt32 = 0,
        key_len_flags: UInt32 = 0,
    ):
        self.parent = parent
        self.node_idx = node_idx
        self.hash_val = hash_val
        self.key_len_flags = key_len_flags

    @always_inline
    def is_empty(self) -> Bool:
        return self.node_idx == NO_NODE


struct KeyIndex(Movable):
    """Flat open-addressing hash table for fast key lookup and duplicate detection.

    Maps `(parent_node_idx, key)` to child node index on the tape using linear
    probing without storing heap-allocated strings.
    """

    var slots: List[KeySlot]
    var count: Int
    var mask: Int

    def __init__(out self, initial_capacity: Int = 64):
        var cap = 64
        while cap < initial_capacity:
            cap <<= 1
        self.count = 0
        self.mask = cap - 1
        self.slots = List[KeySlot](length=cap, fill=KeySlot())

    def _grow(mut self):
        var old_cap = len(self.slots)
        var new_cap = old_cap << 1
        var new_mask = new_cap - 1

        var new_slots = List[KeySlot](length=new_cap, fill=KeySlot())
        var old_ptr = self.slots.unsafe_ptr()
        var new_ptr = new_slots.unsafe_ptr()

        for i in range(old_cap):
            var old_slot = old_ptr[unsafe_offset=i]
            if not old_slot.is_empty():
                var idx = Int(old_slot.hash_val) & new_mask
                while not new_ptr[unsafe_offset=idx].is_empty():
                    idx = (idx + 1) & new_mask
                new_ptr[unsafe_offset=idx] = old_slot

        self.slots = new_slots^
        self.mask = new_mask

    @always_inline
    def find_or_insert[
        check_existing: Bool = True
    ](
        mut self,
        parent: UInt32,
        seg: KeySeg,
        new_node_idx: UInt32,
        ref nodes: List[Node],
        doc_bytes: Span[Byte, _],
    ) -> UInt32:
        """Single-probe lookup and conditional insertion.

        If `(parent, seg)` does not exist in the table (or `check_existing` is False),
        inserts `new_node_idx` into the first empty slot and returns `NO_NODE`.
        If it already exists, leaves the table unchanged and returns the existing node index.
        """
        if self.count * 10 >= len(self.slots) * 7:
            self._grow()

        var h = mix_parent_hash(seg.hash, parent)
        var klen_flags = seg.len | (KEY_ESCAPE_BIT if seg.has_escape else 0)
        var idx = Int(h) & self.mask
        var s_ptr = self.slots.unsafe_ptr()
        var n_ptr = nodes.unsafe_ptr()
        var doc_ptr = doc_bytes.unsafe_ptr()

        while True:
            var slot = s_ptr[unsafe_offset=idx]
            if slot.is_empty():
                s_ptr[unsafe_offset=idx] = KeySlot(
                    parent, new_node_idx, h, klen_flags
                )
                self.count += 1
                return NO_NODE

            comptime if check_existing:
                if slot.parent == parent and slot.hash_val == h:
                    if not seg.has_escape and slot.key_len_flags == seg.len:
                        ref node = n_ptr[unsafe_offset=Int(slot.node_idx)]
                        var p1 = Int(seg.start)
                        var p2 = Int(node.key_start)
                        var n = Int(seg.len)
                        var eq = True
                        for i in range(n):
                            if (
                                doc_ptr[unsafe_offset=p1 + i]
                                != doc_ptr[unsafe_offset=p2 + i]
                            ):
                                eq = False
                                break
                        if eq:
                            return slot.node_idx
                    elif seg.has_escape or (
                        (slot.key_len_flags & KEY_ESCAPE_BIT) != 0
                    ):
                        ref node = n_ptr[unsafe_offset=Int(slot.node_idx)]
                        var node_esc = (
                            slot.key_len_flags & KEY_ESCAPE_BIT
                        ) != 0
                        if keys_equal_slow(
                            seg.start,
                            seg.len,
                            seg.has_escape,
                            node.key_start,
                            node.key_len,
                            node_esc,
                            doc_bytes,
                        ):
                            return slot.node_idx
            idx = (idx + 1) & self.mask

    @always_inline
    def find_by_bytes(
        self,
        parent: UInt32,
        key: Span[Byte, _],
        nodes_ptr: Pointer[Node, _],
        doc_ptr: Pointer[Byte, _],
    ) -> UInt32:
        """Find a child node by raw byte slice within a parent node scope."""
        if self.count == 0 or len(self.slots) == 0:
            return NO_NODE

        var h = hash_key(parent, key)
        var idx = Int(h) & self.mask
        var s_ptr = self.slots.unsafe_ptr()
        var key_ptr = key.unsafe_ptr()
        var key_n = len(key)
        var key_n_u32 = UInt32(key_n)

        while True:
            var slot = s_ptr[unsafe_offset=idx]
            if slot.is_empty():
                return NO_NODE
            if slot.parent == parent and slot.hash_val == h:
                if slot.key_len_flags == key_n_u32:
                    ref node = nodes_ptr[unsafe_offset=Int(slot.node_idx)]
                    var matches = True
                    var ns = Int(node.key_start)
                    for i in range(key_n):
                        if (
                            doc_ptr[unsafe_offset=ns + i]
                            != key_ptr[unsafe_offset=i]
                        ):
                            matches = False
                            break
                    if matches:
                        return slot.node_idx
                elif (slot.key_len_flags & KEY_ESCAPE_BIT) != 0:
                    ref node = nodes_ptr[unsafe_offset=Int(slot.node_idx)]
                    var r = decode_string(
                        Span(
                            unsafe_ptr=doc_ptr.unsafe_offset(
                                Int(node.key_start)
                            ),
                            length=Int(node.key_len),
                        ),
                        NodeFlags.HAS_ESCAPE,
                    )
                    if case .Ok(var s) = r:
                        var sb = s.as_bytes()
                        var matches = len(sb) == key_n
                        if matches:
                            var sb_ptr = sb.unsafe_ptr()
                            for i in range(key_n):
                                if (
                                    sb_ptr[unsafe_offset=i]
                                    != key_ptr[unsafe_offset=i]
                                ):
                                    matches = False
                                    break
                        _ = r^.unsafe_take_value()
                        if matches:
                            return slot.node_idx
                    else:
                        _ = r^.unsafe_take_error()
            idx = (idx + 1) & self.mask
