"""High-throughput flat-tape TOML 1.1 parser."""

from std.bit import count_trailing_zeros
from std.collections import List, Span
from std.memory import pack_bits
from ..result import Result
from .decode import check_escape_at, validate_scalar
from .key_index import KeyIndex, SMALL_TABLE_LIMIT
from .lexer import (
    CC_BARE,
    Comma,
    Comment,
    CurlyBracketClose,
    CurlyBracketOpen,
    DoubleQuote,
    Enter,
    Equal,
    Escape,
    NewLine,
    Period,
    SingleQuote,
    Space,
    SquareBracketClose,
    SquareBracketOpen,
    Tab,
    _CC_TABLE,
    is_valid_utf8_fast,
    scan_and_classify_scalar,
    skip_comment,
    skip_spaces_and_tabs,
    skip_to_newline,
    skip_whitespace_and_comments,
)
from .node import KeySeg, NO_NODE, Node, NodeFlags, NodeKind

comptime MAX_NESTING_DEPTH: Int = 512
comptime MAX_DOCUMENT_BYTES: Int = 0x7FFFFFFF


@always_inline
def _link_child(mut nodes: List[Node], parent: UInt32, child: UInt32):
    """Link a newly created child node into its parent's intrusive child list.
    """
    if parent == NO_NODE:
        return
    var n_ptr = nodes.unsafe_ptr()
    ref p = n_ptr[unsafe_offset=Int(parent)]
    p.len += 1
    if p.first_child == NO_NODE:
        p.first_child = child
        p.last_child = child
    else:
        n_ptr[unsafe_offset=Int(p.last_child)].next_sibling = child
        p.last_child = child


struct _Parser[strict: Bool, origin: ImmOrigin](Movable, not RegisterPassable):
    """Stateful memory-addressed flat-tape parser (`not RegisterPassable` avoids sret copies).
    """

    var data: Span[Byte, Self.origin]
    var ptr: Pointer[Byte, Self.origin]
    var length: Int
    var idx: Int
    var nodes: List[Node]
    var key_index: KeyIndex
    var array_slots: List[UInt32]
    var esc_scratch: String
    var err_msg: String

    @always_inline
    def __init__(out self, data: Span[Byte, Self.origin]):
        self.data = data
        self.ptr = data.unsafe_ptr()
        self.length = len(data)
        self.idx = 0
        var node_cap = max(16, self.length // 12)
        if node_cap > 524288:
            node_cap = max(524288, self.length >> 4)
        self.nodes = List[Node](capacity=node_cap)
        self.nodes.append(Node(kind=NodeKind.Table, flags=NodeFlags.DEFINED))
        self.key_index = KeyIndex()
        self.array_slots = List[UInt32]()
        self.esc_scratch = String()
        self.err_msg = String()

    @always_inline
    def _at(self, i: Int) -> Byte:
        debug_assert(0 <= i and i < self.length, "cursor index out of bounds")
        return self.ptr[unsafe_offset=i]

    # --- Cold error formatting (never runs on valid documents) ---

    @inline(.never)
    def _format_error(self, msg: StringSpan, offset: Int) -> String:
        var limit = min(max(offset, 0), self.length)
        var line = 1
        var line_start = 0
        for i in range(limit):
            if self.ptr[unsafe_offset=i] == NewLine:
                line += 1
                line_start = i + 1
        var col = (limit - line_start) + 1
        return String(t"TOML parse error at {line}:{col}: {msg}")

    @inline(.never)
    def _fail(mut self, msg: StringSpan) -> Bool:
        self.err_msg = self._format_error(msg, self.idx)
        return False

    @inline(.never)
    def _fail_at(mut self, msg: StringSpan, offset: Int) -> Bool:
        self.err_msg = self._format_error(msg, offset)
        return False

    @inline(.never)
    def _fail_node(mut self, msg: StringSpan) -> UInt32:
        self.err_msg = self._format_error(msg, self.idx)
        return NO_NODE

    @inline(.never)
    def _fail_invalid_scalar(mut self, start: Int) -> UInt32:
        var s = StringSpan(unsafe_from_utf8=self.data[start : self.idx])
        var msg = String(t"Invalid scalar value: {s}")
        self.err_msg = self._format_error(msg, start)
        return NO_NODE

    @inline(.never)
    def _fail_duplicate_key[
        in_inline_table: Bool
    ](mut self, final_kseg: KeySeg) -> Bool:
        comptime if in_inline_table:
            return self._fail_at(
                "Duplicate key in inline table.", Int(final_kseg.start)
            )
        var key_s = StringSpan(
            unsafe_from_utf8=self.data[
                Int(final_kseg.start) : Int(final_kseg.start + final_kseg.len)
            ]
        )
        return self._fail_at(
            String(t"Duplicate key: {key_s}"), Int(final_kseg.start)
        )

    @always_inline
    def into_error(deinit self) -> Error:
        return Error(self.err_msg^)

    @always_inline
    def into_tape(deinit self) -> _ParsedTape:
        return _ParsedTape(self.nodes^, self.key_index^, self.array_slots^)

    # --- Key scanning ---

    def _parse_quoted_key_seg(mut self, quote: Byte, mut seg: KeySeg) -> Bool:
        """Scan a quoted key segment and validate escapes in Strict mode."""
        var n = self.length
        var is_literal = quote == SingleQuote
        self.idx += 1
        var start = self.idx
        var has_escape = False
        while self.idx < n and self._at(self.idx) != quote:
            var kb = self._at(self.idx)
            comptime if Self.strict:
                if kb == NewLine or kb == Enter:
                    return self._fail("Newline in quoted key is not allowed.")
                if (kb < 0x20 and kb != 0x09) or kb == 0x7F:
                    return self._fail(
                        "Control character in quoted key is not allowed."
                    )
            if kb == Escape and not is_literal:
                has_escape = True
                self.idx += 1
                comptime if Self.strict:
                    if not check_escape_at[False](self.ptr, n, self.idx):
                        return self._fail(
                            "Invalid escape sequence in quoted key."
                        )
            self.idx += 1
        if self.idx >= n:
            return self._fail("Unclosed quoted key.")
        var seg_len = self.idx - start
        self.idx += 1
        var first_b: Byte = self.ptr[unsafe_offset=start] if seg_len > 0 else 0
        seg = KeySeg(UInt32(start), UInt32(seg_len), first_b, has_escape)
        return True

    @always_inline
    def _parse_one_key_seg(mut self, mut seg: KeySeg) -> Bool:
        """Parse a single bare or quoted key segment with zero hash overhead."""
        var n = self.length
        var start = self.idx
        var ptr = self.ptr
        var cc_ptr = _CC_TABLE.unsafe_ptr()
        var b = ptr[unsafe_offset=start]

        if (cc_ptr[unsafe_offset=Int(b)] & CC_BARE) != 0:
            var p = start + 1
            while (
                p < n
                and (cc_ptr[unsafe_offset=Int(ptr[unsafe_offset=p])] & CC_BARE)
                != 0
            ):
                p += 1
            self.idx = p
            seg = KeySeg(UInt32(start), UInt32(p - start), b, False)
            return True

        if b == DoubleQuote or b == SingleQuote:
            return self._parse_quoted_key_seg(b, seg)

        return self._fail("Invalid character in key.")

    # --- Shared dotted-key, insertion, and EOL helpers ---

    @always_inline
    def _resolve_dotted_step[
        check_defined: Bool
    ](mut self, parent: UInt32, kseg: KeySeg) -> UInt32:
        """Walk or create a single intermediate `NodeFlags.DOTTED` table for `kseg`.
        """
        var cand_idx = UInt32(len(self.nodes))
        var existing = self.key_index.find_or_insert(
            parent,
            kseg,
            cand_idx,
            self.nodes,
            self.data,
            self.esc_scratch,
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
            return self._fail_node("Cannot define dotted key on non-table.")
        comptime if check_defined:
            if (cnode.flags & NodeFlags.DEFINED) != 0:
                return self._fail_node(
                    "Cannot extend explicitly defined table with dotted keys."
                )
        if (cnode.flags & NodeFlags.INLINE) != 0:
            return self._fail_node(
                "Cannot extend inline table with dotted keys."
            )
        return existing

    @always_inline
    def _resolve_header_step(mut self, parent: UInt32, kseg: KeySeg) -> UInt32:
        """Walk or create a single intermediate header table or array-of-tables element.
        """
        var cand_idx = UInt32(len(self.nodes))
        var child = self.key_index.find_or_insert(
            parent,
            kseg,
            cand_idx,
            self.nodes,
            self.data,
            self.esc_scratch,
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
                return self._fail_node("Cannot extend static array as table.")
            if cnode.last_child == NO_NODE:
                return self._fail_node("Array of tables is empty.")
            return cnode.last_child
        if cnode.kind == NodeKind.Table:
            if (cnode.flags & NodeFlags.INLINE) != 0:
                return self._fail_node("Cannot extend inline table.")
            return child
        return self._fail_node("Cannot extend non-table container.")

    @always_inline
    def _insert_value_key[
        in_inline_table: Bool
    ](mut self, parent: UInt32, final_kseg: KeySeg, val_idx: UInt32) -> Bool:
        """Insert `val_idx` under `(parent, final_kseg)` and link it as a child.
        """
        comptime if Self.strict:
            var dup = self.key_index.find_or_insert[True](
                parent,
                final_kseg,
                val_idx,
                self.nodes,
                self.data,
                self.esc_scratch,
            )
            if dup != NO_NODE:
                return self._fail_duplicate_key[in_inline_table](final_kseg)
        else:
            _ = self.key_index.find_or_insert[False](
                parent,
                final_kseg,
                val_idx,
                self.nodes,
                self.data,
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
    def _expect_comment_and_eol(mut self, expected_msg: StaticString) -> Bool:
        """Consume optional horizontal whitespace, comment, and newline/EOF."""
        var n = self.length
        if self.idx < n:
            var b0 = self.ptr[unsafe_offset=self.idx]
            if b0 == NewLine:
                self.idx += 1
                return True
            if (
                b0 == Enter
                and self.idx + 1 < n
                and self.ptr[unsafe_offset=self.idx + 1] == NewLine
            ):
                self.idx += 2
                return True
        skip_spaces_and_tabs(self.data, self.idx)
        if self.idx >= n:
            return True
        if self._at(self.idx) == Comment:
            comptime if Self.strict:
                if not skip_comment(self.data, self.idx):
                    return self._fail(
                        "Invalid control character or bare CR in comment."
                    )
            else:
                skip_to_newline(self.data, self.idx)
        if self.idx >= n:
            return True
        var end_b = self._at(self.idx)
        if end_b == NewLine:
            self.idx += 1
            return True
        if end_b == Enter:
            if self.idx + 1 < n and self._at(self.idx + 1) == NewLine:
                self.idx += 2
                return True
            return self._fail("Bare carriage return.")
        return self._fail(expected_msg)

    # --- String, scalar, and container value parsing ---

    def _parse_multiline_string_node(mut self, quote: Byte) -> UInt32:
        """Scan a multiline basic or literal string and append its tape node."""
        var n = self.length
        var is_literal = quote == SingleQuote
        self.idx += 3
        if self.idx < n and self._at(self.idx) == NewLine:
            self.idx += 1
        elif (
            self.idx + 1 < n
            and self._at(self.idx) == Enter
            and self._at(self.idx + 1) == NewLine
        ):
            self.idx += 2

        var start = self.idx
        var has_escape = False
        comptime W = 16

        while self.idx < n:
            while self.idx + W <= n:
                var v = self.ptr.unsafe_load[width=W](self.idx)
                var stop = v.eq(quote)
                if not is_literal:
                    stop |= v.eq(Escape)
                comptime if Self.strict:
                    stop |= (v.lt(0x20) & v.ne(0x09) & v.ne(0x0A)) | v.eq(0x7F)
                if not any(stop):
                    self.idx += W
                else:
                    var mask = pack_bits(stop)
                    self.idx += Int(count_trailing_zeros(mask))
                    break
            if self.idx >= n:
                break
            if self._at(self.idx) == quote:
                var q_count = 0
                while (
                    self.idx + q_count < n
                    and self._at(self.idx + q_count) == quote
                ):
                    q_count += 1
                if q_count >= 3:
                    var extra_quotes = q_count - 3
                    if extra_quotes > 2:
                        return self._fail_node(
                            "Too many consecutive quotes in multiline string."
                        )
                    var v_len = (self.idx + extra_quotes) - start
                    self.idx += q_count
                    var flags: UInt8 = NodeFlags.MULTILINE
                    if is_literal:
                        flags |= NodeFlags.LITERAL
                    if has_escape:
                        flags |= NodeFlags.HAS_ESCAPE
                    var node_idx = UInt32(len(self.nodes))
                    self.nodes.append(
                        Node(
                            kind=NodeKind.String,
                            flags=flags,
                            start=UInt32(start),
                            len=UInt32(v_len),
                        )
                    )
                    return node_idx
                else:
                    self.idx += q_count
                    continue
            var cb = self._at(self.idx)
            comptime if Self.strict:
                if cb == Enter:
                    if self.idx + 1 >= n or self._at(self.idx + 1) != NewLine:
                        return self._fail_node(
                            "Bare carriage return in multiline string."
                        )
                if (
                    cb < 0x20 and cb != 0x09 and cb != 0x0A and cb != 0x0D
                ) or cb == 0x7F:
                    return self._fail_node(
                        "Unescaped control character in multiline string."
                    )
            if cb == Escape and not is_literal:
                has_escape = True
                self.idx += 1
                comptime if Self.strict:
                    if not check_escape_at[True](self.ptr, n, self.idx):
                        return self._fail_node(
                            "Invalid escape sequence in multiline string."
                        )
            self.idx += 1
        return self._fail_node("Unclosed multiline string.")

    @always_inline
    def _scan_single_line_string[is_literal: Bool](mut self) -> UInt32:
        """Scan a single-line basic or literal string using 16-byte SIMD."""
        comptime quote: Byte = SingleQuote if is_literal else DoubleQuote
        comptime W = 16

        var n = self.length
        var ptr = self.ptr
        var idx = self.idx + 1
        var start = idx
        var has_escape = False

        while idx + W <= n:
            var v = ptr.unsafe_load[width=W](idx)
            var stop = v.eq(quote)
            comptime if not is_literal:
                stop |= v.eq(Escape)
            comptime if Self.strict:
                stop |= (v.lt(0x20) & v.ne(0x09)) | v.eq(0x7F)
            if not any(stop):
                idx += W
                continue

            var mask = pack_bits(stop)
            var base = idx
            var m = UInt32(mask)
            var pos = 0
            while m != 0:
                var step = Int(count_trailing_zeros(m))
                var cur = base + pos + step
                var cb = ptr[unsafe_offset=cur]
                if cb == quote:
                    var v_len = cur - start
                    self.idx = cur + 1
                    var flags: UInt8 = NodeFlags.LITERAL if is_literal else 0
                    if has_escape:
                        flags |= NodeFlags.HAS_ESCAPE
                    var node_idx = UInt32(len(self.nodes))
                    self.nodes.append(
                        Node(
                            kind=NodeKind.String,
                            flags=flags,
                            start=UInt32(start),
                            len=UInt32(v_len),
                        )
                    )
                    return node_idx
                comptime if Self.strict:
                    if cb == NewLine or cb == Enter:
                        self.idx = cur
                        return self._fail_node("Newline in single-line string.")
                    if (cb < 0x20 and cb != 0x09) or cb == 0x7F:
                        self.idx = cur
                        return self._fail_node(
                            "Unescaped control character in string."
                        )
                comptime if not is_literal:
                    if cb == Escape:
                        has_escape = True
                        var esc_idx = cur + 1
                        comptime if Self.strict:
                            if not check_escape_at[False](ptr, n, esc_idx):
                                self.idx = esc_idx
                                return self._fail_node(
                                    "Invalid escape sequence in string."
                                )
                        var advance = (esc_idx + 1) - (base + pos)
                        pos += advance
                        if pos >= W:
                            break
                        m >>= UInt32(advance)
                        continue
                pos += step + 1
                m >>= UInt32(step + 1)
            idx = base + pos if pos > W else base + W

        while idx < n and ptr[unsafe_offset=idx] != quote:
            var cb = ptr[unsafe_offset=idx]
            comptime if Self.strict:
                if cb == NewLine or cb == Enter:
                    self.idx = idx
                    return self._fail_node("Newline in single-line string.")
                if (cb < 0x20 and cb != 0x09) or cb == 0x7F:
                    self.idx = idx
                    return self._fail_node(
                        "Unescaped control character in string."
                    )
            comptime if not is_literal:
                if cb == Escape:
                    has_escape = True
                    idx += 1
                    comptime if Self.strict:
                        if not check_escape_at[False](ptr, n, idx):
                            self.idx = idx
                            return self._fail_node(
                                "Invalid escape sequence in string."
                            )
            idx += 1
        if idx >= n:
            self.idx = idx
            return self._fail_node("Unclosed string.")
        var v_len = idx - start
        self.idx = idx + 1
        var flags: UInt8 = NodeFlags.LITERAL if is_literal else 0
        if has_escape:
            flags |= NodeFlags.HAS_ESCAPE
        var node_idx = UInt32(len(self.nodes))
        self.nodes.append(
            Node(
                kind=NodeKind.String,
                flags=flags,
                start=UInt32(start),
                len=UInt32(v_len),
            )
        )
        return node_idx

    @always_inline
    def _parse_string_node(mut self) -> UInt32:
        var n = self.length
        var quote = self._at(self.idx)
        if (
            self.idx + 2 < n
            and self._at(self.idx + 1) == quote
            and self._at(self.idx + 2) == quote
        ):
            return self._parse_multiline_string_node(quote)
        if quote == SingleQuote:
            return self._scan_single_line_string[True]()
        return self._scan_single_line_string[False]()

    @always_inline
    def _parse_scalar_node(mut self) -> UInt32:
        var start = self.idx
        var sc = scan_and_classify_scalar(self.data, self.idx)
        var s_len = sc[0]
        var kind = sc[1]
        var pv = sc[2]
        if s_len == 0:
            return self._fail_node("Empty scalar value.")
        if kind == NodeKind.Empty:
            return self._fail_invalid_scalar(start)
        comptime if Self.strict:
            if pv == 0 and not validate_scalar(
                kind, self.data[start : self.idx]
            ):
                return self._fail_invalid_scalar(start)
        var node_idx = UInt32(len(self.nodes))
        self.nodes.append(
            Node(
                kind=kind,
                flags=NodeFlags.CANONICAL if pv == 2 else 0,
                start=UInt32(start),
                len=UInt32(s_len),
            )
        )
        return node_idx

    @always_inline
    def _parse_value_at_cursor(mut self, depth: Int) -> UInt32:
        var b = self._at(self.idx)
        if b == DoubleQuote or b == SingleQuote:
            return self._parse_string_node()
        if b == SquareBracketOpen:
            return self._parse_array_node(depth)
        if b == CurlyBracketOpen:
            return self._parse_inline_table_node(depth)
        return self._parse_scalar_node()

    @always_inline
    def _parse_value_node(mut self, depth: Int = 0) -> UInt32:
        if depth > MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.")
        if self.idx < self.length and self.ptr[unsafe_offset=self.idx] == Space:
            self.idx += 1
        skip_spaces_and_tabs(self.data, self.idx)
        if self.idx >= self.length:
            return self._fail_node("Expected value, found EOF.")
        return self._parse_value_at_cursor(depth)

    def _parse_array_node(mut self, depth: Int) -> UInt32:
        if depth >= MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.")
        var n = self.length
        self.idx += 1
        var arr_idx = UInt32(len(self.nodes))
        self.nodes.append(Node(kind=NodeKind.Array, flags=NodeFlags.INLINE))

        while True:
            if not skip_whitespace_and_comments[Self.strict](
                self.data, self.idx
            ):
                return self._fail_node(
                    "Invalid control character or bare CR in array."
                )
            if self.idx >= n:
                return self._fail_node("Unclosed inline array.")
            if self._at(self.idx) == SquareBracketClose:
                self.idx += 1
                break

            var elem_idx = self._parse_value_at_cursor(depth + 1)
            if elem_idx == NO_NODE:
                return NO_NODE
            _link_child(self.nodes, arr_idx, elem_idx)

            if not skip_whitespace_and_comments[Self.strict](
                self.data, self.idx
            ):
                return self._fail_node(
                    "Invalid control character or bare CR in array."
                )
            if self.idx >= n:
                return self._fail_node("Unclosed inline array.")
            var after_b = self._at(self.idx)
            if after_b == Comma:
                self.idx += 1
            elif after_b == SquareBracketClose:
                self.idx += 1
                break
            else:
                return self._fail_node("Expected ',' or ']' in inline array.")

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

    def _parse_inline_table_node(mut self, depth: Int) -> UInt32:
        if depth >= MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.")
        var n = self.length
        self.idx += 1
        var tbl_idx = UInt32(len(self.nodes))
        self.nodes.append(Node(kind=NodeKind.Table, flags=NodeFlags.INLINE))

        while True:
            if not skip_whitespace_and_comments[Self.strict](
                self.data, self.idx
            ):
                return self._fail_node(
                    "Invalid control character or bare CR in inline table."
                )
            if self.idx >= n:
                return self._fail_node("Unclosed inline table.")
            if self._at(self.idx) == CurlyBracketClose:
                self.idx += 1
                break

            var seg = KeySeg()
            if not self._parse_one_key_seg(seg):
                return NO_NODE

            skip_spaces_and_tabs(self.data, self.idx)
            var target_parent = tbl_idx
            while self.idx < n and self._at(self.idx) == Period:
                self.idx += 1
                skip_spaces_and_tabs(self.data, self.idx)
                if (
                    self.idx >= n
                    or self._at(self.idx) == Equal
                    or self._at(self.idx) == Period
                ):
                    return self._fail_node(
                        "Empty key segment or trailing dot in key."
                    )
                target_parent = self._resolve_dotted_step[False](
                    target_parent, seg
                )
                if target_parent == NO_NODE:
                    return NO_NODE
                if not self._parse_one_key_seg(seg):
                    return NO_NODE
                skip_spaces_and_tabs(self.data, self.idx)

            if self.idx >= n or self._at(self.idx) != Equal:
                return self._fail_node("Expected '=' in inline table entry.")
            self.idx += 1

            var val_idx = self._parse_value_node(depth + 1)
            if val_idx == NO_NODE:
                return NO_NODE

            if not self._insert_value_key[True](target_parent, seg, val_idx):
                return NO_NODE

            if not skip_whitespace_and_comments[Self.strict](
                self.data, self.idx
            ):
                return self._fail_node(
                    "Invalid control character or bare CR in inline table."
                )
            if self.idx >= n:
                return self._fail_node("Unclosed inline table.")
            var after_b = self._at(self.idx)
            if after_b == Comma:
                self.idx += 1
            elif after_b == CurlyBracketClose:
                self.idx += 1
                break
            else:
                return self._fail_node("Expected ',' or '}' in inline table.")

        return tbl_idx

    # --- Top-level table headers and document loop ---

    def _parse_table_header(mut self, mut curr_table: UInt32) -> Bool:
        """Parse `[table]` or `[[array_of_tables]]` header and update `curr_table`.
        """
        var n = self.length
        self.idx += 1
        var is_array_of_tables = False
        if self.idx < n and self._at(self.idx) == SquareBracketOpen:
            is_array_of_tables = True
            self.idx += 1

        skip_spaces_and_tabs(self.data, self.idx)
        if self.idx >= n:
            return self._fail("Unexpected EOF while parsing table header.")
        if self._at(self.idx) == SquareBracketClose:
            return self._fail("Empty key.")

        var seg = KeySeg()
        if not self._parse_one_key_seg(seg):
            return False
        skip_spaces_and_tabs(self.data, self.idx)

        var parent: UInt32 = 0
        while self.idx < n and self._at(self.idx) == Period:
            self.idx += 1
            skip_spaces_and_tabs(self.data, self.idx)
            if (
                self.idx >= n
                or self._at(self.idx) == SquareBracketClose
                or self._at(self.idx) == Period
            ):
                return self._fail("Empty key segment or trailing dot in key.")
            parent = self._resolve_header_step(parent, seg)
            if parent == NO_NODE:
                return False
            if not self._parse_one_key_seg(seg):
                return False
            skip_spaces_and_tabs(self.data, self.idx)

        if self.idx >= n or self._at(self.idx) != SquareBracketClose:
            return self._fail("Unclosed table header.")
        self.idx += 1

        if is_array_of_tables:
            if self.idx >= n or self._at(self.idx) != SquareBracketClose:
                return self._fail("Unclosed array of tables header.")
            self.idx += 1

            var cand_arr = UInt32(len(self.nodes))
            var arr_child = self.key_index.find_or_insert(
                parent,
                seg,
                cand_arr,
                self.nodes,
                self.data,
                self.esc_scratch,
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
                        "Expected array of tables, found non-array or static"
                        " array."
                    )

            var new_table = UInt32(len(self.nodes))
            self.nodes.append(
                Node(kind=NodeKind.Table, flags=NodeFlags.DEFINED)
            )
            _link_child(self.nodes, arr_idx, new_table)
            curr_table = new_table
        else:
            var cand_tbl = UInt32(len(self.nodes))
            var existing = self.key_index.find_or_insert(
                parent,
                seg,
                cand_tbl,
                self.nodes,
                self.data,
                self.esc_scratch,
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
                    return self._fail("Cannot redefine non-table as table.")
                if (enode.flags & NodeFlags.INLINE) != 0:
                    return self._fail("Cannot extend inline table.")
                comptime if Self.strict:
                    if (enode.flags & NodeFlags.DEFINED) != 0 or (
                        enode.flags & NodeFlags.DOTTED
                    ) != 0:
                        return self._fail("Table has already been defined.")
                enode.set_flag(NodeFlags.DEFINED)
                curr_table = existing

        return self._expect_comment_and_eol(
            "Expected newline after table header."
        )

    @inline(.never)
    def _finalize_aot_slots(mut self):
        """Build `array_slots` for any `[[array_of_tables]]` with > 8 entries.
        """
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
        """Main document scanning loop."""
        if self.length > MAX_DOCUMENT_BYTES:
            return self._fail("TOML document exceeds maximum size (2 GiB).")

        comptime if Self.strict:
            if not is_valid_utf8_fast(self.data):
                return self._fail("TOML document is not valid UTF-8.")

        var curr_table: UInt32 = 0
        var n = self.length
        var has_aot = False

        while self.idx < n:
            var b = self.ptr[unsafe_offset=self.idx]
            if b == Space or b == Tab:
                skip_spaces_and_tabs(self.data, self.idx)
                if self.idx >= n:
                    break
                b = self.ptr[unsafe_offset=self.idx]

            if b == NewLine:
                self.idx += 1
                continue
            if b == Enter:
                if self.idx + 1 < n and self._at(self.idx + 1) == NewLine:
                    self.idx += 2
                    continue
                return self._fail("Bare carriage return.")
            if b == Comment:
                comptime if Self.strict:
                    if not skip_comment(self.data, self.idx):
                        return self._fail(
                            "Invalid control character or bare CR in comment."
                        )
                else:
                    skip_to_newline(self.data, self.idx)
                continue

            if b == SquareBracketOpen:
                if (
                    self.idx + 1 < n
                    and self.ptr[unsafe_offset=self.idx + 1]
                    == SquareBracketOpen
                ):
                    has_aot = True
                if not self._parse_table_header(curr_table):
                    return False
                continue

            # Key-value pair in `curr_table`
            var seg = KeySeg()
            if not self._parse_one_key_seg(seg):
                return False

            if (
                self.idx + 1 < n
                and self.ptr[unsafe_offset=self.idx] == Space
                and self.ptr[unsafe_offset=self.idx + 1] == Equal
            ):
                self.idx += 2
                var val_idx = self._parse_value_node(0)
                if val_idx == NO_NODE:
                    return False
                if not self._insert_value_key[False](curr_table, seg, val_idx):
                    return False
                if not self._expect_comment_and_eol(
                    "Expected newline after key-value pair."
                ):
                    return False
                continue

            skip_spaces_and_tabs(self.data, self.idx)
            var target_parent = curr_table
            while self.idx < n and self._at(self.idx) == Period:
                self.idx += 1
                skip_spaces_and_tabs(self.data, self.idx)
                if (
                    self.idx >= n
                    or self._at(self.idx) == Equal
                    or self._at(self.idx) == Period
                ):
                    return self._fail(
                        "Empty key segment or trailing dot in key."
                    )
                target_parent = self._resolve_dotted_step[True](
                    target_parent, seg
                )
                if target_parent == NO_NODE:
                    return False
                if not self._parse_one_key_seg(seg):
                    return False
                skip_spaces_and_tabs(self.data, self.idx)

            if self.idx >= n or self._at(self.idx) != Equal:
                return self._fail("Expected '=' after key.")
            self.idx += 1

            var val_idx = self._parse_value_node(0)
            if val_idx == NO_NODE:
                return False

            if not self._insert_value_key[False](target_parent, seg, val_idx):
                return False

            if not self._expect_comment_and_eol(
                "Expected newline after key-value pair."
            ):
                return False

        if has_aot:
            self._finalize_aot_slots()

        return True


struct _ParsedTape(Movable):
    """Internal raw tape output from `_parse_tape`."""

    var nodes: List[Node]
    var key_index: KeyIndex
    var array_slots: List[UInt32]

    @always_inline
    def __init__(
        out self,
        var nodes: List[Node],
        var key_index: KeyIndex,
        var array_slots: List[UInt32],
    ):
        self.nodes = nodes^
        self.key_index = key_index^
        self.array_slots = array_slots^

    @always_inline
    def into_parts(deinit self) -> Tuple[List[Node], KeyIndex, List[UInt32]]:
        return (self.nodes^, self.key_index^, self.array_slots^)


def _parse_tape[
    strict: Bool = True
](content: Span[Byte, _]) -> Result[_ParsedTape]:
    """Parse TOML bytes into a flat tape (`strict=True` for full TOML 1.1 checks).
    """
    var parser = _Parser[strict, content.origin](content)
    if not parser.parse_document():
        return .Err(parser^.into_error())
    return .Ok(parser^.into_tape())
