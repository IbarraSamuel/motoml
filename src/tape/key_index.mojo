"""Adaptive open-addressing hash index with zero-allocation small-table fast path."""

from std.collections import Array, List, Span
from std.memory import Pointer, bitcast, unsafe_memset_zero
from .decode import _decode_string_to_buf_impl, decode_string
from .node import KeySeg, NO_NODE, Node, NodeFlags

comptime KEY_ESCAPE_BIT: UInt32 = 0x80000000
comptime SMALL_TABLE_LIMIT: Int = 8

comptime _HASH_SECRET0: UInt64 = 0x9E3779B97F4A7C15
comptime _HASH_SECRET1: UInt64 = 0xBF58476D1CE4E5B9


@always_inline
def _load_u64_unaligned(ptr: ImmPointer[Byte, _], offset: Int) -> UInt64:
    return bitcast[DType.uint64, 1](ptr.unsafe_load[width=8](offset))


@always_inline
def _load_u32_unaligned(ptr: ImmPointer[Byte, _], offset: Int) -> UInt32:
    return bitcast[DType.uint32, 1](ptr.unsafe_load[width=4](offset))


@always_inline
def _bytes_equal(
    p1: ImmPointer[Byte, _], p2: ImmPointer[Byte, _], n: Int
) -> Bool:
    """Fast word-wise byte slice equality for known-equal length `n`."""
    if n <= 8:
        if n >= 4:
            return _load_u32_unaligned(p1, 0) == _load_u32_unaligned(
                p2, 0
            ) and _load_u32_unaligned(p1, n - 4) == _load_u32_unaligned(
                p2, n - 4
            )
        if n == 0:
            return True
        if p1[unsafe_offset=0] != p2[unsafe_offset=0]:
            return False
        if n == 1:
            return True
        if p1[unsafe_offset=1] != p2[unsafe_offset=1]:
            return False
        if n == 2:
            return True
        return p1[unsafe_offset=2] == p2[unsafe_offset=2]

    var i = 0
    while i + 8 < n:
        if _load_u64_unaligned(p1, i) != _load_u64_unaligned(p2, i):
            return False
        i += 8
    return _load_u64_unaligned(p1, n - 8) == _load_u64_unaligned(p2, n - 8)


@always_inline
def hash_raw_bytes(ptr: ImmPointer[Byte, _], length: Int) -> UInt32:
    """Compute a fast word-wise 32-bit hash over `ptr[0..length]` (short-key fast path first).
    """
    var h: UInt64 = UInt64(length) * _HASH_SECRET0
    if length <= 8:
        if length >= 4:
            var lo = UInt64(_load_u32_unaligned(ptr, 0))
            var hi = UInt64(_load_u32_unaligned(ptr, length - 4))
            h = (h ^ ((lo << 32) | hi)) * _HASH_SECRET1
        elif length > 0:
            var b0 = UInt64(ptr[unsafe_offset=0])
            var b1 = UInt64(ptr[unsafe_offset=length >> 1])
            var b2 = UInt64(ptr[unsafe_offset=length - 1])
            h = (h ^ ((b0 << 16) | (b1 << 8) | b2)) * _HASH_SECRET1
        else:
            h *= _HASH_SECRET1
        return UInt32((h ^ (h >> 32)) & 0xFFFFFFFF)

    var i = 0
    while i + 8 < length:
        var w = _load_u64_unaligned(ptr, i)
        h = (h ^ w) * _HASH_SECRET1
        h ^= h >> 32
        i += 8
    var tail = _load_u64_unaligned(ptr, length - 8)
    h = (h ^ tail) * _HASH_SECRET1
    return UInt32((h ^ (h >> 32)) & 0xFFFFFFFF)


@always_inline
def mix_parent_hash(key_hash: UInt32, parent: UInt32) -> UInt32:
    """Combine a 32-bit key hash with its scoping parent node index."""
    var x = (UInt64(parent) << 32) | UInt64(key_hash)
    x *= _HASH_SECRET0
    return UInt32((x ^ (x >> 32)) & 0xFFFFFFFF)


@always_inline
def hash_key(parent: UInt32, key: Span[Byte, _]) -> UInt32:
    """Compute a 32-bit hash over `key` scoped by `parent`."""
    return mix_parent_hash(hash_raw_bytes(key.unsafe_ptr(), len(key)), parent)


@inline(.never)
def compute_escaped_key_hash(
    raw_bytes: Span[Byte, _], mut scratch: String
) -> UInt32:
    """Decode a validated escaped key into `scratch` and return its logical hash.
    """
    var n = len(raw_bytes)
    if n <= 256:
        var sbuf = Array[Byte, 256](uninitialized=True)
        var err_msg: StaticString = ""
        var written = _decode_string_to_buf_impl[False](
            raw_bytes, NodeFlags.HAS_ESCAPE, sbuf.unsafe_ptr(), err_msg
        )
        return hash_raw_bytes(sbuf.unsafe_ptr(), written)
    scratch.resize(unsafe_uninit_length=0)
    var dst = scratch.unsafe_ptr_mut(n)
    var err_msg: StaticString = ""
    var written = _decode_string_to_buf_impl[False](
        raw_bytes, NodeFlags.HAS_ESCAPE, dst, err_msg
    )
    scratch.resize(unsafe_uninit_length=written)
    return hash_raw_bytes(scratch.as_bytes().unsafe_ptr(), written)


@inline(.never)
def _escaped_key_matches_bytes(
    raw_ptr: ImmPointer[Byte, _],
    raw_n: Int,
    tgt_ptr: ImmPointer[Byte, _],
    tgt_n: Int,
) -> Bool:
    """Compare an escaped raw TOML key slice against an unescaped byte span."""
    var raw_key = Span(unsafe_ptr=raw_ptr, length=raw_n)
    if raw_n <= 256:
        var sbuf = Array[Byte, 256](uninitialized=True)
        var err_msg: StaticString = ""
        var written = _decode_string_to_buf_impl[True](
            raw_key, NodeFlags.HAS_ESCAPE, sbuf.unsafe_ptr(), err_msg
        )
        if written < 0 or written != tgt_n:
            return False
        return _bytes_equal(sbuf.unsafe_ptr(), tgt_ptr, tgt_n)
    var r = decode_string(raw_key, NodeFlags.HAS_ESCAPE)
    if case .Ok(_) = r:
        var s = r^.unsafe_take_value()
        var sb = s.as_bytes()
        return len(sb) == tgt_n and _bytes_equal(
            sb.unsafe_ptr(), tgt_ptr, tgt_n
        )
    _ = r^.unsafe_take_error()
    return False


@inline(.never)
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
    var d_ptr = doc_bytes.unsafe_ptr()
    if esc1 and not esc2:
        return _escaped_key_matches_bytes(
            d_ptr.unsafe_offset(Int(s1)),
            Int(l1),
            d_ptr.unsafe_offset(Int(s2)),
            Int(l2),
        )
    if esc2 and not esc1:
        return _escaped_key_matches_bytes(
            d_ptr.unsafe_offset(Int(s2)),
            Int(l2),
            d_ptr.unsafe_offset(Int(s1)),
            Int(l1),
        )

    var str1 = String()
    if esc1:
        var r1 = decode_string(
            doc_bytes[Int(s1) : Int(s1 + l1)], NodeFlags.HAS_ESCAPE
        )
        if case .Ok(_) = r1:
            str1 = r1^.unsafe_take_value()
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
        if case .Ok(_) = r2:
            str2 = r2^.unsafe_take_value()
        else:
            _ = r2^.unsafe_take_error()
    else:
        str2 = String(
            StringSpan(unsafe_from_utf8=doc_bytes[Int(s2) : Int(s2 + l2)])
        )

    return str1 == str2


struct KeySlot(Copyable, Movable, TrivialRegisterPassable):
    """16-byte entry in the open-addressing key index hash table."""

    var parent: UInt32
    var node_idx: UInt32
    var hash_val: UInt32
    var key_len_flags: UInt32

    @always_inline
    def __init__(
        out self,
        parent: UInt32 = 0,
        node_idx: UInt32 = 0,
        hash_val: UInt32 = 0,
        key_len_flags: UInt32 = 0,
    ):
        self.parent = parent
        self.node_idx = node_idx
        self.hash_val = hash_val
        self.key_len_flags = key_len_flags

    @always_inline
    def is_empty(self) -> Bool:
        return self.node_idx == 0


struct KeyIndex(Movable, not RegisterPassable):
    """Flat open-addressing hash index allocated lazily only when a table exceeds `SMALL_TABLE_LIMIT`.
    """

    var slots: List[KeySlot]
    var count: Int
    var mask: Int
    var grow_at: Int

    @always_inline
    def __init__(out self):
        self.slots = List[KeySlot]()
        self.count = 0
        self.mask = 0
        self.grow_at = 0

    @inline(.never)
    def _init_or_grow(mut self, doc_len: Int):
        var old_cap = len(self.slots)
        var new_cap: Int
        if old_cap == 0:
            var target = max(64, doc_len // 12)
            if target > 262144:
                target = 262144
            new_cap = 64
            while new_cap < target:
                new_cap <<= 1
        else:
            new_cap = old_cap << 1

        var new_mask = new_cap - 1
        var new_slots = List[KeySlot](capacity=new_cap)
        new_slots.resize(unsafe_uninit_length=new_cap)
        unsafe_memset_zero(new_slots.unsafe_ptr(), new_cap)

        if old_cap > 0:
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
        self.grow_at = (new_cap * 7) // 10

    @always_inline
    def _insert_unique_slot(
        mut self,
        parent: UInt32,
        node_idx: UInt32,
        h: UInt32,
        klen_flags: UInt32,
        doc_len: Int,
    ):
        if self.count >= self.grow_at:
            self._init_or_grow(doc_len)
        var idx = Int(h) & self.mask
        var s_ptr = self.slots.unsafe_ptr()
        while not s_ptr[unsafe_offset=idx].is_empty():
            idx = (idx + 1) & self.mask
        s_ptr[unsafe_offset=idx] = KeySlot(parent, node_idx, h, klen_flags)
        self.count += 1

    @inline(.never)
    def _promote_table(
        mut self,
        parent: UInt32,
        seg: KeySeg,
        new_node_idx: UInt32,
        mut nodes: List[Node],
        doc_bytes: Span[Byte, _],
        mut esc_scratch: String,
    ):
        var doc_len = len(doc_bytes)
        if self.count + SMALL_TABLE_LIMIT + 1 >= self.grow_at:
            self._init_or_grow(doc_len)

        var n_ptr = nodes.unsafe_ptr()
        var doc_ptr = doc_bytes.unsafe_ptr()

        var curr = n_ptr[unsafe_offset=Int(parent)].first_child
        while curr != NO_NODE:
            ref cnode = n_ptr[unsafe_offset=Int(curr)]
            var has_esc = (cnode.key_flags & NodeFlags.HAS_ESCAPE) != 0
            var kh: UInt32
            if not has_esc:
                kh = hash_raw_bytes(
                    doc_ptr.unsafe_offset(Int(cnode.key_start)),
                    Int(cnode.key_len),
                )
            else:
                kh = compute_escaped_key_hash(
                    doc_bytes[
                        Int(cnode.key_start) : Int(
                            cnode.key_start + cnode.key_len
                        )
                    ],
                    esc_scratch,
                )
            var h = mix_parent_hash(kh, parent)
            var klf = cnode.key_len | (KEY_ESCAPE_BIT if has_esc else 0)
            self._insert_unique_slot(parent, curr, h, klf, doc_len)
            curr = cnode.next_sibling

        var nkh: UInt32
        if not seg.has_escape:
            nkh = hash_raw_bytes(
                doc_ptr.unsafe_offset(Int(seg.start)), Int(seg.len)
            )
        else:
            nkh = compute_escaped_key_hash(
                doc_bytes[Int(seg.start) : Int(seg.start + seg.len)],
                esc_scratch,
            )
        var nh = mix_parent_hash(nkh, parent)
        var nklf = seg.len | (KEY_ESCAPE_BIT if seg.has_escape else 0)
        self._insert_unique_slot(parent, new_node_idx, nh, nklf, doc_len)

        n_ptr[unsafe_offset=Int(parent)].flags |= NodeFlags.INDEXED

    @always_inline
    def find_or_insert[
        check_existing: Bool = True
    ](
        mut self,
        parent: UInt32,
        seg: KeySeg,
        new_node_idx: UInt32,
        mut nodes: List[Node],
        doc_bytes: Span[Byte, _],
        mut esc_scratch: String,
    ) -> UInt32:
        var n_ptr = nodes.unsafe_ptr()
        ref pnode = n_ptr[unsafe_offset=Int(parent)]
        var doc_ptr = doc_bytes.unsafe_ptr()

        if (pnode.flags & NodeFlags.INDEXED) == 0:
            comptime if check_existing:
                var curr = pnode.first_child
                while curr != NO_NODE:
                    ref cnode = n_ptr[unsafe_offset=Int(curr)]
                    if (
                        not seg.has_escape
                        and (cnode.key_flags & NodeFlags.HAS_ESCAPE) == 0
                    ):
                        if (
                            cnode.key_len == seg.len
                            and cnode.key_tag == seg.first_byte
                        ):
                            if _bytes_equal(
                                doc_ptr.unsafe_offset(Int(seg.start)),
                                doc_ptr.unsafe_offset(Int(cnode.key_start)),
                                Int(seg.len),
                            ):
                                return curr
                    else:
                        if keys_equal_slow(
                            seg.start,
                            seg.len,
                            seg.has_escape,
                            cnode.key_start,
                            cnode.key_len,
                            (cnode.key_flags & NodeFlags.HAS_ESCAPE) != 0,
                            doc_bytes,
                        ):
                            return curr
                    curr = cnode.next_sibling

            if Int(pnode.len) < SMALL_TABLE_LIMIT:
                return NO_NODE

            self._promote_table(
                parent, seg, new_node_idx, nodes, doc_bytes, esc_scratch
            )
            return NO_NODE

        if self.count >= self.grow_at:
            self._init_or_grow(len(doc_bytes))

        var kh: UInt32
        if not seg.has_escape:
            kh = hash_raw_bytes(
                doc_ptr.unsafe_offset(Int(seg.start)), Int(seg.len)
            )
        else:
            kh = compute_escaped_key_hash(
                doc_bytes[Int(seg.start) : Int(seg.start + seg.len)],
                esc_scratch,
            )

        var h = mix_parent_hash(kh, parent)
        var klen_flags = seg.len | (KEY_ESCAPE_BIT if seg.has_escape else 0)
        var idx = Int(h) & self.mask
        var s_ptr = self.slots.unsafe_ptr()

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
                        if _bytes_equal(
                            doc_ptr.unsafe_offset(Int(seg.start)),
                            doc_ptr.unsafe_offset(Int(node.key_start)),
                            Int(seg.len),
                        ):
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
        nodes_ptr: ImmPointer[Node, _],
        doc_ptr: ImmPointer[Byte, _],
    ) -> UInt32:
        """Find a child node by raw byte slice within `parent`."""
        ref pnode = nodes_ptr[unsafe_offset=Int(parent)]
        if pnode.len == 0:
            return NO_NODE

        if (pnode.flags & NodeFlags.INDEXED) == 0:
            var key_n = len(key)
            var key_n_u32 = UInt32(key_n)
            var key_ptr = key.unsafe_ptr()
            var first_b: Byte = key_ptr[unsafe_offset=0] if key_n > 0 else 0
            var curr = pnode.first_child
            while curr != NO_NODE:
                ref cnode = nodes_ptr[unsafe_offset=Int(curr)]
                if (cnode.key_flags & NodeFlags.HAS_ESCAPE) == 0:
                    if cnode.key_len == key_n_u32 and cnode.key_tag == first_b:
                        if _bytes_equal(
                            doc_ptr.unsafe_offset(Int(cnode.key_start)),
                            key_ptr,
                            key_n,
                        ):
                            return curr
                else:
                    if _escaped_key_matches_bytes(
                        doc_ptr.unsafe_offset(Int(cnode.key_start)),
                        Int(cnode.key_len),
                        key_ptr,
                        key_n,
                    ):
                        return curr
                curr = cnode.next_sibling
            return NO_NODE

        var key_ptr = key.unsafe_ptr()
        var key_n = len(key)
        var key_n_u32 = UInt32(key_n)
        var h = mix_parent_hash(hash_raw_bytes(key_ptr, key_n), parent)
        var idx = Int(h) & self.mask
        var s_ptr = self.slots.unsafe_ptr()

        while True:
            var slot = s_ptr[unsafe_offset=idx]
            if slot.is_empty():
                return NO_NODE
            if slot.parent == parent and slot.hash_val == h:
                if slot.key_len_flags == key_n_u32:
                    ref node = nodes_ptr[unsafe_offset=Int(slot.node_idx)]
                    if _bytes_equal(
                        doc_ptr.unsafe_offset(Int(node.key_start)),
                        key_ptr,
                        key_n,
                    ):
                        return slot.node_idx
                elif (slot.key_len_flags & KEY_ESCAPE_BIT) != 0:
                    ref node = nodes_ptr[unsafe_offset=Int(slot.node_idx)]
                    if _escaped_key_matches_bytes(
                        doc_ptr.unsafe_offset(Int(node.key_start)),
                        Int(node.key_len),
                        key_ptr,
                        key_n,
                    ):
                        return slot.node_idx
            idx = (idx + 1) & self.mask
