"""Stage-2 flat-tape and adaptive `KeyIndex` builder over compact 32-bit `UInt32` token blocks."""

from std.collections import List, Span
from std.memory import Pointer
from motoml.tape.decode import validate_scalar
from motoml.tape.key_index import KeyIndex, SMALL_TABLE_LIMIT
from motoml.tape.lexer import (
    CC_BARE,
    Enter,
    NewLine,
    Space,
    _CC_TABLE,
    scan_and_classify_scalar,
)
from motoml.tape.node import KeySeg, NO_NODE, Node, NodeFlags, NodeKind
from motoml.tape.reader import MAX_NESTING_DEPTH, _ParsedTape, _link_child
from .kernels import (
    ATOM_BARE_FLAG,
    GPU_BYTES_PER_BLOCK,
    TOK_ATOM,
    TOK_ATOM_LONG,
    TOK_COMMA,
    TOK_DOT,
    TOK_EQUAL,
    TOK_LBRACE,
    TOK_LBRACKET,
    TOK_NEWLINE,
    TOK_RBRACE,
    TOK_RBRACKET,
    TOK_STR_CLOSE,
    TOK_STR_ESC,
    TOK_STR_OPEN,
)


@fieldwise_init
struct _Tok32(Copyable, ImplicitlyCopyable, Movable, TrivialRegisterPassable):
    var abs_start: Int
    var raw: UInt32

    @always_inline
    def kind(self) -> UInt8:
        return UInt8((self.raw >> 14) & 0x0F)

    @always_inline
    def flags(self) -> UInt8:
        return UInt8((self.raw >> 18) & 0x7F)

    @always_inline
    def len7(self) -> Int:
        return Int(self.raw >> 25)


struct _CachedBlockCursor(Movable, not RegisterPassable):
    """Zero-copy sequential cursor across L1/L2-cached 32-bit `UInt32` GPU token blocks.
    """

    var block_starts: ImmPointer[UInt32, ImmUntrackedOrigin]
    var block_lens: ImmPointer[UInt32, ImmUntrackedOrigin]
    var tokens: ImmPointer[UInt32, ImmUntrackedOrigin]
    var end_block: Int
    var cur_block: Int
    var cur_byte_base: Int
    var cur_pos: Int
    var cur_end: Int

    @always_inline
    def __init__(
        out self,
        block_starts: ImmPointer[UInt32, ImmUntrackedOrigin],
        block_lens: ImmPointer[UInt32, ImmUntrackedOrigin],
        tokens: ImmPointer[UInt32, ImmUntrackedOrigin],
        start_block: Int,
        end_block: Int,
    ):
        self.block_starts = block_starts
        self.block_lens = block_lens
        self.tokens = tokens
        self.end_block = end_block
        self.cur_block = start_block
        self.cur_byte_base = start_block * GPU_BYTES_PER_BLOCK
        self.cur_pos = 0
        self.cur_end = 0
        self._advance_non_empty()

    @always_inline
    def _advance_non_empty(mut self):
        while self.cur_block < self.end_block:
            var blen = Int(self.block_lens[unsafe_offset=self.cur_block])
            if blen > 0:
                self.cur_byte_base = self.cur_block * GPU_BYTES_PER_BLOCK
                self.cur_pos = Int(
                    self.block_starts[unsafe_offset=self.cur_block]
                )
                self.cur_end = self.cur_pos + blen
                return
            self.cur_block += 1

    @always_inline
    def has_more(self) -> Bool:
        return self.cur_pos < self.cur_end

    @always_inline
    def peek(self) -> _Tok32:
        var r = self.tokens[unsafe_offset=self.cur_pos]
        return _Tok32(self.cur_byte_base + Int(r & 0x3FFF), r)

    @always_inline
    def next(mut self) -> _Tok32:
        var r = self.tokens[unsafe_offset=self.cur_pos]
        var abs_s = self.cur_byte_base + Int(r & 0x3FFF)
        self.cur_pos += 1
        if self.cur_pos >= self.cur_end:
            self.cur_block += 1
            self._advance_non_empty()
        return _Tok32(abs_s, r)


struct _Stage2Builder[strict: Bool, origin: ImmOrigin](
    Movable, not RegisterPassable
):
    """Builds `motoml` `_ParsedTape` from L1/L2-cached 32-bit `UInt32` token blocks.
    """

    var data: Span[Byte, Self.origin]
    var ptr: Pointer[Byte, Self.origin]
    var doc_offset: Int
    var doc_end: Int
    var cur: _CachedBlockCursor
    var nodes: List[Node]
    var key_index: KeyIndex
    var array_slots: List[UInt32]
    var esc_scratch: String
    var err_offset: Int
    var err_msg: StaticString

    @always_inline
    def __init__(
        out self,
        data: Span[Byte, Self.origin],
        var cur: _CachedBlockCursor,
        doc_offset: Int = 0,
        doc_end: Int = 0,
    ):
        self.data = data
        self.ptr = data.unsafe_ptr()
        self.doc_offset = doc_offset
        self.doc_end = doc_end if doc_end > 0 else len(data)
        self.cur = cur^
        var span_len = self.doc_end - self.doc_offset
        var node_cap = max(16, span_len // 12)
        if node_cap > 524288:
            node_cap = max(524288, span_len >> 4)
        self.nodes = List[Node](capacity=node_cap)
        self.nodes.append(Node(kind=NodeKind.Table, flags=NodeFlags.DEFINED))
        self.key_index = KeyIndex()
        self.array_slots = List[UInt32]()
        self.esc_scratch = String()
        self.err_offset = 0
        self.err_msg = ""

    @always_inline
    def _has_tok(self) -> Bool:
        return self.cur.has_more() and self.cur.peek().abs_start < self.doc_end

    @always_inline
    def _peek(self) -> _Tok32:
        return self.cur.peek()

    @always_inline
    def _next(mut self) -> _Tok32:
        return self.cur.next()

    @always_inline
    def _skip_newlines(mut self):
        while self._has_tok() and self._peek().kind() == TOK_NEWLINE:
            _ = self._next()

    @inline(.never)
    def _fail(mut self, msg: StaticString, abs_off: Int) -> Bool:
        self.err_msg = msg
        self.err_offset = abs_off - self.doc_offset
        return False

    @inline(.never)
    def _fail_node(mut self, msg: StaticString, abs_off: Int) -> UInt32:
        self.err_msg = msg
        self.err_offset = abs_off - self.doc_offset
        return NO_NODE

    @always_inline
    def _consume_string_span(
        mut self, open_tok: _Tok32
    ) -> Tuple[Bool, UInt32, UInt32, UInt8]:
        var sflags = open_tok.flags()
        var has_esc = False
        while self._has_tok():
            var t = self._next()
            var tk = t.kind()
            if tk == TOK_STR_ESC:
                has_esc = True
                continue
            if tk == TOK_STR_CLOSE:
                if (t.flags() & NodeFlags.HAS_ESCAPE) != 0:
                    has_esc = True
                var raw_start = open_tok.abs_start
                var raw_end = t.abs_start
                if (sflags & NodeFlags.MULTILINE) != 0 and raw_start < raw_end:
                    if self.ptr[unsafe_offset=raw_start] == NewLine:
                        raw_start += 1
                    elif (
                        raw_start + 1 < raw_end
                        and self.ptr[unsafe_offset=raw_start] == Enter
                        and self.ptr[unsafe_offset=raw_start + 1] == NewLine
                    ):
                        raw_start += 2
                if has_esc and (sflags & NodeFlags.LITERAL) == 0:
                    sflags |= NodeFlags.HAS_ESCAPE
                return (
                    True,
                    UInt32(raw_start - self.doc_offset),
                    UInt32(raw_end - raw_start),
                    sflags,
                )
            return (False, 0, 0, 0)
        return (False, 0, 0, 0)

    @always_inline
    def _parse_key_seg(mut self, mut seg: KeySeg) -> Bool:
        if not self._has_tok():
            return self._fail("Unexpected EOF while parsing key.", self.doc_end)
        var t = self._next()
        var tk = t.kind()
        var ts = t.abs_start
        if tk == TOK_ATOM:
            if (t.flags() & ATOM_BARE_FLAG) == 0:
                return self._fail("Invalid character in bare key.", ts)
            var rel_start = UInt32(ts - self.doc_offset)
            var klen = UInt32(t.len7())
            seg = KeySeg(rel_start, klen, self.ptr[unsafe_offset=ts], False)
            return True
        if tk == TOK_ATOM_LONG:
            var p = ts
            var lim = self.doc_end
            var cc_ptr = _CC_TABLE.unsafe_ptr()
            while (
                p < lim
                and (
                    cc_ptr[unsafe_offset=Int(self.ptr[unsafe_offset=p])]
                    & CC_BARE
                )
                != 0
            ):
                p += 1
            if p < lim:
                var nb = self.ptr[unsafe_offset=p]
                if not (
                    nb == Space
                    or nb == Byte(ord("\t"))
                    or nb == Byte(ord("="))
                    or nb == Byte(ord("."))
                    or nb == Byte(ord("]"))
                ):
                    return self._fail("Invalid character in bare key.", p)
            var rel_start = UInt32(ts - self.doc_offset)
            seg = KeySeg(
                rel_start,
                UInt32(p - ts),
                self.ptr[unsafe_offset=ts],
                False,
            )
            return True
        if tk == TOK_STR_OPEN:
            if (t.flags() & NodeFlags.MULTILINE) != 0:
                return self._fail(
                    "Multiline strings cannot be used as keys.", ts
                )
            var ok, r_start, r_len, sflags = self._consume_string_span(t)
            if not ok:
                return self._fail("Unclosed quoted key.", ts)
            var first_b: Byte = (
                self.ptr[unsafe_offset=self.doc_offset + Int(r_start)] if r_len
                > 0 else 0
            )
            seg = KeySeg(
                r_start,
                r_len,
                first_b,
                (sflags & NodeFlags.HAS_ESCAPE) != 0,
            )
            return True
        return self._fail("Invalid key token.", ts)

    @always_inline
    def _resolve_dotted_step[
        check_defined: Bool
    ](mut self, parent: UInt32, kseg: KeySeg) -> UInt32:
        var doc_slice = self.data[self.doc_offset : self.doc_end]
        var cand_idx = UInt32(len(self.nodes))
        var existing = self.key_index.find_or_insert(
            parent, kseg, cand_idx, self.nodes, doc_slice, self.esc_scratch
        )
        if existing == NO_NODE:
            self.nodes.append(
                Node(
                    kind=NodeKind.Table,
                    flags=NodeFlags.DOTTED,
                    key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                    key_tag=kseg.first_byte,
                    key_start=kseg.start,
                    key_len=kseg.len,
                )
            )
            _link_child(self.nodes, parent, cand_idx)
            return cand_idx

        ref cnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(existing)]
        if cnode.kind != NodeKind.Table:
            return self._fail_node(
                "Cannot define dotted key on non-table.",
                self.doc_offset + Int(kseg.start),
            )
        comptime if check_defined:
            if (cnode.flags & NodeFlags.DEFINED) != 0:
                return self._fail_node(
                    "Cannot extend explicitly defined table with dotted keys.",
                    self.doc_offset + Int(kseg.start),
                )
        if (cnode.flags & NodeFlags.INLINE) != 0:
            return self._fail_node(
                "Cannot extend inline table with dotted keys.",
                self.doc_offset + Int(kseg.start),
            )
        return existing

    @always_inline
    def _resolve_header_step(mut self, parent: UInt32, kseg: KeySeg) -> UInt32:
        var doc_slice = self.data[self.doc_offset : self.doc_end]
        var cand_idx = UInt32(len(self.nodes))
        var child = self.key_index.find_or_insert(
            parent, kseg, cand_idx, self.nodes, doc_slice, self.esc_scratch
        )
        if child == NO_NODE:
            self.nodes.append(
                Node(
                    kind=NodeKind.Table,
                    flags=NodeFlags.IMPLICIT,
                    key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                    key_tag=kseg.first_byte,
                    key_start=kseg.start,
                    key_len=kseg.len,
                )
            )
            _link_child(self.nodes, parent, cand_idx)
            return cand_idx

        ref cnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(child)]
        if cnode.kind == NodeKind.Array:
            if (cnode.flags & NodeFlags.ARRAY_OF_TABLES) == 0:
                return self._fail_node(
                    "Cannot extend static array as table.",
                    self.doc_offset + Int(kseg.start),
                )
            if cnode.last_child == NO_NODE:
                return self._fail_node(
                    "Array of tables is empty.",
                    self.doc_offset + Int(kseg.start),
                )
            return cnode.last_child
        if cnode.kind == NodeKind.Table:
            if (cnode.flags & NodeFlags.INLINE) != 0:
                return self._fail_node(
                    "Cannot extend inline table.",
                    self.doc_offset + Int(kseg.start),
                )
            return child
        return self._fail_node(
            "Cannot extend non-table container.",
            self.doc_offset + Int(kseg.start),
        )

    @always_inline
    def _insert_value_key(
        mut self, parent: UInt32, final_kseg: KeySeg, val_idx: UInt32
    ) -> Bool:
        var doc_slice = self.data[self.doc_offset : self.doc_end]
        comptime if Self.strict:
            var dup = self.key_index.find_or_insert[True](
                parent,
                final_kseg,
                val_idx,
                self.nodes,
                doc_slice,
                self.esc_scratch,
            )
            if dup != NO_NODE:
                return self._fail(
                    "Duplicate key.", self.doc_offset + Int(final_kseg.start)
                )
        else:
            _ = self.key_index.find_or_insert[False](
                parent,
                final_kseg,
                val_idx,
                self.nodes,
                doc_slice,
                self.esc_scratch,
            )

        ref vnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(val_idx)]
        vnode.key_start = final_kseg.start
        vnode.key_len = final_kseg.len
        vnode.key_tag = final_kseg.first_byte
        if final_kseg.has_escape:
            vnode.key_flags = NodeFlags.HAS_ESCAPE
        _link_child(self.nodes, parent, val_idx)
        return True

    @always_inline
    def _expect_eol(mut self) -> Bool:
        if not self._has_tok():
            return True
        var t = self._next()
        if t.kind() == TOK_NEWLINE:
            return True
        return self._fail("Expected newline or EOF.", t.abs_start)

    def _parse_scalar_from_tok(mut self, first_tok: _Tok32) -> UInt32:
        var abs_start = first_tok.abs_start
        if first_tok.kind() == TOK_ATOM:
            var slen = first_tok.len7()
            var abs_end = abs_start + slen
            var needs_rescan = False
            if self._has_tok():
                var nt = self._peek()
                var ntk = nt.kind()
                var nts = nt.abs_start
                if ntk == TOK_DOT and nts == abs_end:
                    needs_rescan = True
                elif (
                    slen == 10
                    and (ntk == TOK_ATOM or ntk == TOK_ATOM_LONG)
                    and nts == abs_start + 11
                    and self.ptr[unsafe_offset=abs_start + 10] == Space
                ):
                    needs_rescan = True

            if not needs_rescan:
                var aflags = first_tok.flags()
                var k_val = aflags & 0x0F
                var pv = (aflags >> 5) & 0x03
                if k_val != 0:
                    var kind = NodeKind(k_val)
                    comptime if Self.strict:
                        if pv == 0 and not validate_scalar(
                            kind, self.data[abs_start:abs_end]
                        ):
                            return self._fail_node(
                                "Invalid scalar value.", abs_start
                            )
                    var node_idx = UInt32(len(self.nodes))
                    self.nodes.append(
                        Node(
                            kind=kind,
                            flags=NodeFlags.CANONICAL if pv == 2 else 0,
                            start=UInt32(abs_start - self.doc_offset),
                            len=UInt32(slen),
                        )
                    )
                    return node_idx

        var idx = abs_start - self.doc_offset
        var doc_slice = self.data[self.doc_offset : self.doc_end]
        var sc = scan_and_classify_scalar(doc_slice, idx)
        var s_len = sc[0]
        var kind = sc[1]
        var pv = sc[2]
        if s_len == 0 or kind == NodeKind.Empty:
            return self._fail_node("Invalid scalar value.", abs_start)
        var abs_after = self.doc_offset + idx
        while self._has_tok() and self._peek().abs_start < abs_after:
            var skipped = self._next()
            if (
                skipped.kind() == TOK_ATOM
                and skipped.abs_start + skipped.len7() > abs_after
            ):
                return self._fail_node("Invalid scalar delimiter.", abs_start)
        comptime if Self.strict:
            if pv == 0 and not validate_scalar(
                kind, doc_slice[abs_start - self.doc_offset : idx]
            ):
                return self._fail_node("Invalid scalar value.", abs_start)
        var node_idx = UInt32(len(self.nodes))
        self.nodes.append(
            Node(
                kind=kind,
                flags=NodeFlags.CANONICAL if pv == 2 else 0,
                start=UInt32(abs_start - self.doc_offset),
                len=UInt32(s_len),
            )
        )
        return node_idx

    def _parse_value(mut self, depth: Int) -> UInt32:
        if depth > MAX_NESTING_DEPTH:
            return self._fail_node(
                "Maximum nesting depth exceeded.", self.doc_end
            )
        if not self._has_tok():
            return self._fail_node("Expected value, found EOF.", self.doc_end)
        var t = self._next()
        var tk = t.kind()
        if tk == TOK_STR_OPEN:
            var ok, r_start, r_len, sflags = self._consume_string_span(t)
            if not ok:
                return self._fail_node("Unclosed string.", t.abs_start)
            var node_idx = UInt32(len(self.nodes))
            self.nodes.append(
                Node(
                    kind=NodeKind.String,
                    flags=sflags,
                    start=r_start,
                    len=r_len,
                )
            )
            return node_idx
        if tk == TOK_LBRACKET:
            return self._parse_array(depth, t.abs_start)
        if tk == TOK_LBRACE:
            return self._parse_inline_table(depth, t.abs_start)
        if tk == TOK_ATOM or tk == TOK_ATOM_LONG:
            return self._parse_scalar_from_tok(t)
        return self._fail_node(
            "Unexpected token in value position.", t.abs_start
        )

    def _parse_array(mut self, depth: Int, open_off: Int) -> UInt32:
        if depth >= MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.", open_off)
        var arr_idx = UInt32(len(self.nodes))
        self.nodes.append(Node(kind=NodeKind.Array, flags=NodeFlags.INLINE))

        while True:
            self._skip_newlines()
            if not self._has_tok():
                return self._fail_node("Unclosed inline array.", open_off)
            if self._peek().kind() == TOK_RBRACKET:
                _ = self._next()
                break

            var elem_idx = self._parse_value(depth + 1)
            if elem_idx == NO_NODE:
                return NO_NODE
            _link_child(self.nodes, arr_idx, elem_idx)

            self._skip_newlines()
            if not self._has_tok():
                return self._fail_node("Unclosed inline array.", open_off)
            var after = self._next()
            var ak = after.kind()
            if ak == TOK_COMMA:
                continue
            if ak == TOK_RBRACKET:
                break
            return self._fail_node(
                "Expected ',' or ']' in inline array.", after.abs_start
            )

        var n_ptr = self.nodes.unsafe_ptr()
        ref anode = n_ptr[unsafe_offset=Int(arr_idx)]
        if (
            anode.len <= 1
            or (anode.last_child - anode.first_child) == anode.len - 1
        ):
            anode.flags |= NodeFlags.CONTIGUOUS
        elif Int(anode.len) > SMALL_TABLE_LIMIT:
            var slot_start = UInt32(len(self.array_slots))
            var curr = anode.first_child
            while curr != NO_NODE:
                self.array_slots.append(curr)
                curr = n_ptr[unsafe_offset=Int(curr)].next_sibling
            anode.start = slot_start
            anode.flags |= NodeFlags.SLOTTED
        return arr_idx

    def _parse_inline_table(mut self, depth: Int, open_off: Int) -> UInt32:
        if depth >= MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.", open_off)
        var tbl_idx = UInt32(len(self.nodes))
        self.nodes.append(Node(kind=NodeKind.Table, flags=NodeFlags.INLINE))

        while True:
            self._skip_newlines()
            if not self._has_tok():
                return self._fail_node("Unclosed inline table.", open_off)
            if self._peek().kind() == TOK_RBRACE:
                _ = self._next()
                break

            var seg = KeySeg()
            if not self._parse_key_seg(seg):
                return NO_NODE

            var target_parent = tbl_idx
            while self._has_tok() and self._peek().kind() == TOK_DOT:
                var dot_t = self._next()
                target_parent = self._resolve_dotted_step[False](
                    target_parent, seg
                )
                if target_parent == NO_NODE:
                    return NO_NODE
                if not self._parse_key_seg(seg):
                    return self._fail_node(
                        "Empty key segment or trailing dot in key.",
                        dot_t.abs_start,
                    )

            if not self._has_tok() or self._peek().kind() != TOK_EQUAL:
                return self._fail_node(
                    "Expected '=' in inline table entry.",
                    self.doc_offset + Int(seg.start),
                )
            _ = self._next()

            var val_idx = self._parse_value(depth + 1)
            if val_idx == NO_NODE:
                return NO_NODE
            if not self._insert_value_key(target_parent, seg, val_idx):
                return NO_NODE

            self._skip_newlines()
            if not self._has_tok():
                return self._fail_node("Unclosed inline table.", open_off)
            var after = self._next()
            var ak = after.kind()
            if ak == TOK_COMMA:
                continue
            if ak == TOK_RBRACE:
                break
            return self._fail_node(
                "Expected ',' or '}' in inline table.", after.abs_start
            )

        return tbl_idx

    def _parse_header(
        mut self, open_tok: _Tok32, mut curr_table: UInt32, mut has_aot: Bool
    ) -> Bool:
        var open_s = open_tok.abs_start
        var is_aot = False
        if (
            self._has_tok()
            and self._peek().kind() == TOK_LBRACKET
            and self._peek().abs_start == open_s + 1
        ):
            _ = self._next()
            is_aot = True
            has_aot = True

        if not self._has_tok():
            return self._fail("Unexpected EOF in table header.", open_s)
        if self._peek().kind() == TOK_RBRACKET:
            return self._fail("Empty key in table header.", open_s)

        var seg = KeySeg()
        if not self._parse_key_seg(seg):
            return False

        var parent: UInt32 = 0
        while self._has_tok() and self._peek().kind() == TOK_DOT:
            _ = self._next()
            parent = self._resolve_header_step(parent, seg)
            if parent == NO_NODE:
                return False
            if not self._parse_key_seg(seg):
                return False

        if not self._has_tok() or self._peek().kind() != TOK_RBRACKET:
            return self._fail("Unclosed table header.", open_s)
        var close1 = self._next()

        if is_aot:
            if (
                not self._has_tok()
                or self._peek().kind() != TOK_RBRACKET
                or self._peek().abs_start != close1.abs_start + 1
            ):
                return self._fail(
                    "Unclosed array of tables header.", close1.abs_start
                )
            _ = self._next()

            var doc_slice = self.data[self.doc_offset : self.doc_end]
            var cand_arr = UInt32(len(self.nodes))
            var arr_child = self.key_index.find_or_insert(
                parent, seg, cand_arr, self.nodes, doc_slice, self.esc_scratch
            )
            var arr_idx: UInt32
            if arr_child == NO_NODE:
                arr_idx = cand_arr
                self.nodes.append(
                    Node(
                        kind=NodeKind.Array,
                        flags=NodeFlags.ARRAY_OF_TABLES,
                        key_flags=NodeFlags.HAS_ESCAPE if seg.has_escape else 0,
                        key_tag=seg.first_byte,
                        key_start=seg.start,
                        key_len=seg.len,
                    )
                )
                _link_child(self.nodes, parent, arr_idx)
            else:
                arr_idx = arr_child
                ref anode = self.nodes.unsafe_ptr()[unsafe_offset=Int(arr_idx)]
                if (
                    anode.kind != NodeKind.Array
                    or (anode.flags & NodeFlags.ARRAY_OF_TABLES) == 0
                ):
                    return self._fail(
                        (
                            "Expected array of tables, found non-array or"
                            " static array."
                        ),
                        open_s,
                    )

            var new_table = UInt32(len(self.nodes))
            self.nodes.append(
                Node(kind=NodeKind.Table, flags=NodeFlags.DEFINED)
            )
            _link_child(self.nodes, arr_idx, new_table)
            curr_table = new_table
        else:
            var doc_slice = self.data[self.doc_offset : self.doc_end]
            var cand_tbl = UInt32(len(self.nodes))
            var existing = self.key_index.find_or_insert(
                parent, seg, cand_tbl, self.nodes, doc_slice, self.esc_scratch
            )
            if existing == NO_NODE:
                self.nodes.append(
                    Node(
                        kind=NodeKind.Table,
                        flags=NodeFlags.DEFINED,
                        key_flags=NodeFlags.HAS_ESCAPE if seg.has_escape else 0,
                        key_tag=seg.first_byte,
                        key_start=seg.start,
                        key_len=seg.len,
                    )
                )
                _link_child(self.nodes, parent, cand_tbl)
                curr_table = cand_tbl
            else:
                ref enode = self.nodes.unsafe_ptr()[unsafe_offset=Int(existing)]
                if enode.kind != NodeKind.Table:
                    return self._fail(
                        "Cannot redefine non-table as table.", open_s
                    )
                if (enode.flags & NodeFlags.INLINE) != 0:
                    return self._fail("Cannot extend inline table.", open_s)
                comptime if Self.strict:
                    if (enode.flags & NodeFlags.DEFINED) != 0 or (
                        enode.flags & NodeFlags.DOTTED
                    ) != 0:
                        return self._fail(
                            "Table has already been defined.", open_s
                        )
                enode.set_flag(NodeFlags.DEFINED)
                curr_table = existing

        return self._expect_eol()

    @inline(.never)
    def _finalize_aot_slots(mut self):
        var n_nodes = len(self.nodes)
        var n_ptr = self.nodes.unsafe_ptr()
        for i in range(n_nodes):
            ref node = n_ptr[unsafe_offset=i]
            if (
                node.kind == NodeKind.Array
                and (node.flags & NodeFlags.ARRAY_OF_TABLES) != 0
            ):
                if (
                    node.len <= 1
                    or (node.last_child - node.first_child) == node.len - 1
                ):
                    node.flags |= NodeFlags.CONTIGUOUS
                elif Int(node.len) > SMALL_TABLE_LIMIT:
                    var slot_start = UInt32(len(self.array_slots))
                    var curr = node.first_child
                    while curr != NO_NODE:
                        self.array_slots.append(curr)
                        curr = n_ptr[unsafe_offset=Int(curr)].next_sibling
                    node.start = slot_start
                    node.flags |= NodeFlags.SLOTTED

    def parse_document(mut self) -> Bool:
        var curr_table: UInt32 = 0
        var has_aot = False

        while True:
            self._skip_newlines()
            if not self._has_tok():
                break

            if self._peek().kind() == TOK_LBRACKET:
                var open_t = self._next()
                if not self._parse_header(open_t, curr_table, has_aot):
                    return False
                continue

            var seg = KeySeg()
            if not self._parse_key_seg(seg):
                return False

            if self._has_tok() and self._peek().kind() == TOK_EQUAL:
                _ = self._next()
                var val_idx = self._parse_value(0)
                if val_idx == NO_NODE:
                    return False
                if not self._insert_value_key(curr_table, seg, val_idx):
                    return False
                if not self._expect_eol():
                    return False
                continue

            var target_parent = curr_table
            while self._has_tok() and self._peek().kind() == TOK_DOT:
                _ = self._next()
                target_parent = self._resolve_dotted_step[True](
                    target_parent, seg
                )
                if target_parent == NO_NODE:
                    return False
                if not self._parse_key_seg(seg):
                    return False

            if not self._has_tok() or self._peek().kind() != TOK_EQUAL:
                return self._fail(
                    "Expected '=' after key.",
                    self.doc_offset + Int(seg.start),
                )
            _ = self._next()

            var val_idx = self._parse_value(0)
            if val_idx == NO_NODE:
                return False
            if not self._insert_value_key(target_parent, seg, val_idx):
                return False
            if not self._expect_eol():
                return False

        if has_aot:
            self._finalize_aot_slots()
        return True

    @always_inline
    def into_tape(deinit self) -> _ParsedTape:
        return _ParsedTape(self.nodes^, self.key_index^, self.array_slots^)

    @inline(.never)
    def format_error(self) -> Error:
        var doc_slice = self.data[self.doc_offset : self.doc_end]
        var limit = min(max(self.err_offset, 0), len(doc_slice))
        var s_ptr = doc_slice.unsafe_ptr()
        var line = 1
        var line_start = 0
        for i in range(limit):
            if s_ptr[unsafe_offset=i] == NewLine:
                line += 1
                line_start = i + 1
        var col = (limit - line_start) + 1
        return Error(
            String(t"TOML parse error at {line}:{col}: {self.err_msg}")
        )
