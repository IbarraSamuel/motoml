"""Flat hash index for O(1) table key lookups and collision detection.
"""

from .node import Node, NodeFlags, NO_NODE
from .scalar_decode import decode_string
from std.collections import Span, List


@always_inline
def hash_key(parent: UInt32, key: Span[Byte, _]) -> UInt32:
    var h: UInt32 = 2166136261 ^ (parent * 16777619)
    for i in range(len(key)):
        h = (h ^ UInt32(key[i])) * 16777619
    return h


def hash_key_segment(
    parent: UInt32,
    key_start: UInt32,
    key_len: UInt32,
    has_escape: Bool,
    doc_bytes: Span[Byte, _],
) -> UInt32:
    if not has_escape:
        var h: UInt32 = 2166136261 ^ (parent * 16777619)
        for i in range(Int(key_len)):
            h = (h ^ UInt32(doc_bytes[Int(key_start) + i])) * 16777619
        return h

    var res = decode_string(
        doc_bytes[Int(key_start) : Int(key_start + key_len)],
        NodeFlags.HAS_ESCAPE,
    )
    if case .Ok(var s) = res:
        var h: UInt32 = 2166136261 ^ (parent * 16777619)
        var s_bytes = s.as_bytes()
        for i in range(len(s_bytes)):
            h = (h ^ UInt32(s_bytes[i])) * 16777619
        _ = res^.unsafe_take_value()
        return h
    else:
        _ = res^.unsafe_take_error()
        return hash_key(
            parent, doc_bytes[Int(key_start) : Int(key_start + key_len)]
        )


def keys_equal(
    s1: UInt32,
    l1: UInt32,
    esc1: Bool,
    s2: UInt32,
    l2: UInt32,
    esc2: Bool,
    doc_bytes: Span[Byte, _],
) -> Bool:
    if not esc1 and not esc2:
        if l1 != l2:
            return False
        for i in range(Int(l1)):
            if doc_bytes[Int(s1) + i] != doc_bytes[Int(s2) + i]:
                return False
        return True

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
            StringSlice(unsafe_from_utf8=doc_bytes[Int(s1) : Int(s1 + l1)])
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
            StringSlice(unsafe_from_utf8=doc_bytes[Int(s2) : Int(s2 + l2)])
        )

    return str1 == str2


struct KeySlot(Copyable, Movable, TrivialRegisterPassable):
    var parent: UInt32
    var node_idx: UInt32
    var hash_val: UInt32

    @always_inline
    def __init__(
        out self,
        parent: UInt32 = 0,
        node_idx: UInt32 = NO_NODE,
        hash_val: UInt32 = 0,
    ):
        self.parent = parent
        self.node_idx = node_idx
        self.hash_val = hash_val

    @always_inline
    def is_empty(self) -> Bool:
        return self.node_idx == NO_NODE


struct KeyIndex(Movable):
    var slots: List[KeySlot]
    var count: Int
    var mask: Int

    def __init__(out self, initial_capacity: Int = 64):
        var cap = 64
        while cap < initial_capacity:
            cap <<= 1
        self.count = 0
        self.mask = cap - 1
        self.slots = List[KeySlot](capacity=cap)
        for _ in range(cap):
            self.slots.append(KeySlot())

    def _grow(mut self):
        var old_cap = len(self.slots)
        var new_cap = old_cap << 1
        var new_mask = new_cap - 1

        var new_slots = List[KeySlot](capacity=new_cap)
        for _ in range(new_cap):
            new_slots.append(KeySlot())

        for i in range(old_cap):
            ref old_slot = self.slots[i]
            if not old_slot.is_empty():
                var idx = Int(old_slot.hash_val) & new_mask
                while not new_slots[idx].is_empty():
                    idx = (idx + 1) & new_mask
                new_slots[idx] = old_slot

        self.slots = new_slots^
        self.mask = new_mask

    @always_inline
    def _insert_slot(mut self, parent: UInt32, node_idx: UInt32, h: UInt32):
        var idx = Int(h) & self.mask
        while not self.slots[idx].is_empty():
            idx = (idx + 1) & self.mask
        self.slots[idx] = KeySlot(parent, node_idx, h)
        self.count += 1

    def find(
        self,
        parent: UInt32,
        key_start: UInt32,
        key_len: UInt32,
        ref nodes: List[Node],
        doc_bytes: Span[Byte, _],
        has_escape: Bool = False,
    ) -> UInt32:
        if self.count == 0 or len(self.slots) == 0:
            return NO_NODE

        var h = hash_key_segment(
            parent, key_start, key_len, has_escape, doc_bytes
        )
        var idx = Int(h) & self.mask

        while True:
            ref slot = self.slots[idx]
            if slot.is_empty():
                return NO_NODE
            if slot.parent == parent and slot.hash_val == h:
                ref node = nodes[Int(slot.node_idx)]
                var node_has_escape = (
                    node.key_flags & NodeFlags.HAS_ESCAPE
                ) != 0
                if keys_equal(
                    key_start,
                    key_len,
                    has_escape,
                    node.key_start,
                    node.key_len,
                    node_has_escape,
                    doc_bytes,
                ):
                    return slot.node_idx
            idx = (idx + 1) & self.mask

    def find_by_bytes(
        self,
        parent: UInt32,
        key: Span[Byte, _],
        nodes_ptr: Pointer[Node, _],
        doc_bytes: Span[Byte, _],
    ) -> UInt32:
        if self.count == 0 or len(self.slots) == 0:
            return NO_NODE

        var h = hash_key(parent, key)
        var idx = Int(h) & self.mask

        while True:
            ref slot = self.slots[idx]
            if slot.is_empty():
                return NO_NODE
            if slot.parent == parent and slot.hash_val == h:
                ref node = nodes_ptr.unsafe_offset(Int(slot.node_idx))[]
                var node_has_escape = (
                    node.key_flags & NodeFlags.HAS_ESCAPE
                ) != 0
                if not node_has_escape:
                    if Int(node.key_len) == len(key):
                        var matches = True
                        for i in range(len(key)):
                            if doc_bytes[Int(node.key_start) + i] != key[i]:
                                matches = False
                                break
                        if matches:
                            return slot.node_idx
                else:
                    var r = decode_string(
                        doc_bytes[
                            Int(node.key_start) : Int(
                                node.key_start + node.key_len
                            )
                        ],
                        NodeFlags.HAS_ESCAPE,
                    )
                    if case .Ok(var s) = r:
                        var sb = s.as_bytes()
                        var matches = len(sb) == len(key)
                        if matches:
                            for i in range(len(key)):
                                if sb[i] != key[i]:
                                    matches = False
                                    break
                        _ = r^.unsafe_take_value()
                        if matches:
                            return slot.node_idx
                    else:
                        _ = r^.unsafe_take_error()
            idx = (idx + 1) & self.mask

    def insert(
        mut self,
        parent: UInt32,
        key_start: UInt32,
        key_len: UInt32,
        node_idx: UInt32,
        doc_bytes: Span[Byte, _],
        has_escape: Bool = False,
    ):
        if self.count * 10 >= len(self.slots) * 7:
            self._grow()

        var h = hash_key_segment(
            parent, key_start, key_len, has_escape, doc_bytes
        )
        self._insert_slot(parent, node_idx, h)
