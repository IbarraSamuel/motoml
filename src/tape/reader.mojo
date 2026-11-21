"""High-throughput flat-tape TOML 1.1 parser."""

from std.bit import count_trailing_zeros
from std.collections import List, Span
from std.memory import pack_bits
from ..result import Result
from .decode import check_escape_at, validate_scalar
from .key_index import (
    FNV_OFFSET_BASIS,
    FNV_PRIME,
    KeyIndex,
    compute_escaped_key_hash,
)
from .lexer import (
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
    SquareBracketClose,
    SquareBracketOpen,
    is_bare_key_byte,
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


struct _Parser[strict: Bool, origin: ImmOrigin](Movable):
    """Stateful flat-tape parser reusing scratch buffers across keys and values.
    """

    var data: Span[Byte, Self.origin]
    var ptr: Pointer[Byte, Self.origin]
    var length: Int
    var idx: Int
    var nodes: List[Node]
    var key_index: KeyIndex
    var key_segs: List[KeySeg]
    var esc_scratch: String
    var err_msg: String

    @always_inline
    def __init__(out self, data: Span[Byte, Self.origin]):
        self.data = data
        self.ptr = data.unsafe_ptr()
        self.length = len(data)
        self.idx = 0
        self.nodes = List[Node](capacity=max(16, self.length // 10))
        self.nodes.append(Node(kind=NodeKind.Table, flags=NodeFlags.DEFINED))
        self.key_index = KeyIndex(initial_capacity=max(16, self.length // 12))
        self.key_segs = List[KeySeg](capacity=32)
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
        return _ParsedTape(self.nodes^, self.key_index^)

    # --- Key scanning ---

    def _parse_quoted_key_seg(mut self, quote: Byte, mut seg: KeySeg) -> Bool:
        """Scan a quoted key segment and compute its logical FNV-1a hash."""
        var n = self.length
        var is_literal = quote == SingleQuote
        self.idx += 1
        var start = self.idx
        var has_escape = False
        var h: UInt32 = FNV_OFFSET_BASIS
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
            else:
                h = (h ^ UInt32(kb)) * FNV_PRIME
            self.idx += 1
        if self.idx >= n:
            return self._fail("Unclosed quoted key.")
        var seg_len = self.idx - start
        self.idx += 1
        if has_escape:
            var eh = compute_escaped_key_hash(
                self.data[start : start + seg_len], self.esc_scratch
            )
            comptime if Self.strict:
                if not eh[0]:
                    return self._fail_at(
                        "Invalid escape sequence in quoted key.", start
                    )
            h = eh[1]
        seg = KeySeg(UInt32(start), UInt32(seg_len), h, has_escape)
        return True

    @always_inline
    def _parse_one_key_seg(mut self, mut seg: KeySeg) -> Bool:
        """Parse a single bare or quoted key segment at `self.idx`."""
        var n = self.length
        var b = self._at(self.idx)
        if is_bare_key_byte(b):
            var start = self.idx
            var ptr = self.ptr
            var h: UInt32 = (FNV_OFFSET_BASIS ^ UInt32(b)) * FNV_PRIME
            var p = start + 1
            while p < n:
                var kb = ptr[unsafe_offset=p]
                if not is_bare_key_byte(kb):
                    break
                h = (h ^ UInt32(kb)) * FNV_PRIME
                p += 1
            self.idx = p
            seg = KeySeg(UInt32(start), UInt32(p - start), h, False)
            return True

        if b == DoubleQuote or b == SingleQuote:
            return self._parse_quoted_key_seg(b, seg)

        return self._fail("Invalid character in key.")

    def _parse_key_segments(mut self, stop_byte: Byte, base: Int) -> Bool:
        """Append dotted key segments onto `self.key_segs` starting at `base`.
        """
        var n = self.length
        while self.idx < n:
            skip_spaces_and_tabs(self.data, self.idx)
            if self.idx >= n:
                return self._fail("Unexpected EOF while parsing key.")

            if self._at(self.idx) == stop_byte:
                break

            var seg = KeySeg()
            if not self._parse_one_key_seg(seg):
                return False
            self.key_segs.append(seg)

            skip_spaces_and_tabs(self.data, self.idx)
            if self.idx < n and self._at(self.idx) == Period:
                self.idx += 1
                skip_spaces_and_tabs(self.data, self.idx)
                if (
                    self.idx >= n
                    or self._at(self.idx) == stop_byte
                    or self._at(self.idx) == Period
                ):
                    return self._fail(
                        "Empty key segment or trailing dot in key."
                    )
                continue
            elif self.idx < n and self._at(self.idx) == stop_byte:
                break
            else:
                return self._fail("Expected '.' or '=' in key.")

        if len(self.key_segs) == base:
            return self._fail("Empty key.")
        return True

    # --- Shared dotted-key, insertion, and EOL helpers ---

    @always_inline
    def _resolve_dotted_parent[
        check_defined: Bool
    ](mut self, start_parent: UInt32, key_base: Int, key_end: Int) -> UInt32:
        """Walk or create intermediate `NodeFlags.DOTTED` tables for a dotted key.
        """
        var target = start_parent
        for i in range(key_base, key_end - 1):
            var kseg = self.key_segs.unsafe_ptr()[unsafe_offset=i]
            var cand_idx = UInt32(len(self.nodes))
            var existing = self.key_index.find_or_insert(
                target, kseg, cand_idx, self.nodes, self.data
            )
            if existing == NO_NODE:
                self.nodes.append(
                    Node(
                        kind=NodeKind.Table,
                        flags=NodeFlags.DOTTED,
                        key_start=kseg.start,
                        key_len=kseg.len,
                        key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                    )
                )
                _link_child(self.nodes, target, cand_idx)
                target = cand_idx
            else:
                ref cnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(existing)]
                if cnode.kind != NodeKind.Table:
                    return self._fail_node(
                        "Cannot define dotted key on non-table."
                    )
                comptime if check_defined:
                    if (cnode.flags & NodeFlags.DEFINED) != 0:
                        return self._fail_node(
                            "Cannot extend explicitly defined table with dotted"
                            " keys."
                        )
                if (cnode.flags & NodeFlags.INLINE) != 0:
                    return self._fail_node(
                        "Cannot extend inline table with dotted keys."
                    )
                target = existing
        return target

    @always_inline
    def _insert_value_key[
        in_inline_table: Bool
    ](mut self, parent: UInt32, final_kseg: KeySeg, val_idx: UInt32) -> Bool:
        """Insert `val_idx` under `(parent, final_kseg)` and link it as a child.
        """
        comptime if Self.strict:
            var dup = self.key_index.find_or_insert[True](
                parent, final_kseg, val_idx, self.nodes, self.data
            )
            if dup != NO_NODE:
                return self._fail_duplicate_key[in_inline_table](final_kseg)
        else:
            _ = self.key_index.find_or_insert[False](
                parent, final_kseg, val_idx, self.nodes, self.data
            )

        ref vnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(val_idx)]
        vnode.key_start = final_kseg.start
        vnode.key_len = final_kseg.len
        if final_kseg.has_escape:
            vnode.key_flags = NodeFlags.HAS_ESCAPE
        _link_child(self.nodes, parent, val_idx)
        return True

    @always_inline
    def _expect_comment_and_eol(mut self, expected_msg: StaticString) -> Bool:
        """Consume optional horizontal whitespace, comment, and newline/EOF."""
        var n = self.length
        if self.idx < n and self._at(self.idx) == NewLine:
            self.idx += 1
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
                var mask = pack_bits(stop)
                if not mask:
                    self.idx += W
                else:
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
        self.idx += 1
        var start = self.idx
        var has_escape = False

        while self.idx + W <= n:
            var v = self.ptr.unsafe_load[width=W](self.idx)
            var stop = v.eq(quote)
            comptime if not is_literal:
                stop |= v.eq(Escape)
            comptime if Self.strict:
                stop |= (v.lt(0x20) & v.ne(0x09)) | v.eq(0x7F)
            var mask = pack_bits(stop)
            if not mask:
                self.idx += W
                continue

            var base = self.idx
            var m = UInt32(mask)
            var pos = 0
            while m != 0:
                var step = Int(count_trailing_zeros(m))
                var cur = base + pos + step
                var cb = self._at(cur)
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
                            if not check_escape_at[False](self.ptr, n, esc_idx):
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
            self.idx = base + pos if pos > W else base + W

        while self.idx < n and self._at(self.idx) != quote:
            var cb = self._at(self.idx)
            comptime if Self.strict:
                if cb == NewLine or cb == Enter:
                    return self._fail_node("Newline in single-line string.")
                if (cb < 0x20 and cb != 0x09) or cb == 0x7F:
                    return self._fail_node(
                        "Unescaped control character in string."
                    )
            comptime if not is_literal:
                if cb == Escape:
                    has_escape = True
                    self.idx += 1
                    comptime if Self.strict:
                        if not check_escape_at[False](self.ptr, n, self.idx):
                            return self._fail_node(
                                "Invalid escape sequence in string."
                            )
            self.idx += 1
        if self.idx >= n:
            return self._fail_node("Unclosed string.")
        var v_len = self.idx - start
        self.idx += 1
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

            var first_seg = KeySeg()
            if not self._parse_one_key_seg(first_seg):
                return NO_NODE

            skip_spaces_and_tabs(self.data, self.idx)
            var final_kseg = first_seg
            if self.idx < n and self._at(self.idx) == Period:
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
                var key_base = len(self.key_segs)
                self.key_segs.append(first_seg)
                if not self._parse_key_segments(Equal, key_base):
                    self.key_segs.shrink(key_base)
                    return NO_NODE
                var key_end = len(self.key_segs)
                if self.idx >= n or self._at(self.idx) != Equal:
                    self.key_segs.shrink(key_base)
                    return self._fail_node(
                        "Expected '=' in inline table entry."
                    )
                self.idx += 1

                var val_idx = self._parse_value_node(depth + 1)
                if val_idx == NO_NODE:
                    self.key_segs.shrink(key_base)
                    return NO_NODE

                var target_parent = self._resolve_dotted_parent[False](
                    tbl_idx, key_base, key_end
                )
                if target_parent == NO_NODE:
                    self.key_segs.shrink(key_base)
                    return NO_NODE

                final_kseg = self.key_segs.unsafe_ptr()[
                    unsafe_offset=key_end - 1
                ]
                self.key_segs.shrink(key_base)

                if not self._insert_value_key[True](
                    target_parent, final_kseg, val_idx
                ):
                    return NO_NODE
            else:
                if self.idx >= n or self._at(self.idx) != Equal:
                    return self._fail_node(
                        "Expected '=' in inline table entry."
                    )
                self.idx += 1

                var val_idx = self._parse_value_node(depth + 1)
                if val_idx == NO_NODE:
                    return NO_NODE

                if not self._insert_value_key[True](
                    tbl_idx, final_kseg, val_idx
                ):
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

        self.key_segs.shrink(0)
        if not self._parse_key_segments(SquareBracketClose, 0):
            return False
        var num_keys = len(self.key_segs)

        if self.idx >= n or self._at(self.idx) != SquareBracketClose:
            return self._fail("Unclosed table header.")
        self.idx += 1

        if is_array_of_tables:
            if self.idx >= n or self._at(self.idx) != SquareBracketClose:
                return self._fail("Unclosed array of tables header.")
            self.idx += 1

        var parent: UInt32 = 0
        for i in range(num_keys - 1):
            var kseg = self.key_segs.unsafe_ptr()[unsafe_offset=i]
            var cand_idx = UInt32(len(self.nodes))
            var child = self.key_index.find_or_insert(
                parent, kseg, cand_idx, self.nodes, self.data
            )
            if child == NO_NODE:
                self.nodes.append(
                    Node(
                        kind=NodeKind.Table,
                        flags=NodeFlags.IMPLICIT,
                        key_start=kseg.start,
                        key_len=kseg.len,
                        key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                    )
                )
                _link_child(self.nodes, parent, cand_idx)
                parent = cand_idx
            else:
                ref cnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(child)]
                if cnode.kind == NodeKind.Array:
                    if (cnode.flags & NodeFlags.ARRAY_OF_TABLES) == 0:
                        return self._fail(
                            "Cannot extend static array as table."
                        )
                    if cnode.last_child == NO_NODE:
                        return self._fail("Array of tables is empty.")
                    parent = cnode.last_child
                elif cnode.kind == NodeKind.Table:
                    if (cnode.flags & NodeFlags.INLINE) != 0:
                        return self._fail("Cannot extend inline table.")
                    parent = child
                else:
                    return self._fail("Cannot extend non-table container.")

        var final_kseg = self.key_segs.unsafe_ptr()[unsafe_offset=num_keys - 1]

        if is_array_of_tables:
            var cand_arr = UInt32(len(self.nodes))
            var arr_child = self.key_index.find_or_insert(
                parent, final_kseg, cand_arr, self.nodes, self.data
            )
            var arr_idx: UInt32
            if arr_child == NO_NODE:
                arr_idx = cand_arr
                self.nodes.append(
                    Node(
                        kind=NodeKind.Array,
                        flags=NodeFlags.ARRAY_OF_TABLES,
                        key_start=final_kseg.start,
                        key_len=final_kseg.len,
                        key_flags=NodeFlags.HAS_ESCAPE if final_kseg.has_escape else 0,
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
                parent, final_kseg, cand_tbl, self.nodes, self.data
            )
            if existing == NO_NODE:
                self.nodes.append(
                    Node(
                        kind=NodeKind.Table,
                        flags=NodeFlags.DEFINED,
                        key_start=final_kseg.start,
                        key_len=final_kseg.len,
                        key_flags=NodeFlags.HAS_ESCAPE if final_kseg.has_escape else 0,
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

    def parse_document(mut self) -> Bool:
        """Main document scanning loop."""
        if self.length > MAX_DOCUMENT_BYTES:
            return self._fail("TOML document exceeds maximum size (2 GiB).")

        comptime if Self.strict:
            if not is_valid_utf8_fast(self.data):
                return self._fail("TOML document is not valid UTF-8.")

        var curr_table: UInt32 = 0
        var n = self.length

        while self.idx < n:
            skip_spaces_and_tabs(self.data, self.idx)
            if self.idx >= n:
                break

            var b = self._at(self.idx)
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
                if not self._parse_table_header(curr_table):
                    return False
                continue

            # Key-value pair in `curr_table`
            var first_seg = KeySeg()
            if not self._parse_one_key_seg(first_seg):
                return False

            skip_spaces_and_tabs(self.data, self.idx)
            var target_parent = curr_table
            var final_kseg = first_seg
            if self.idx < n and self._at(self.idx) == Period:
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
                self.key_segs.shrink(0)
                self.key_segs.append(first_seg)
                if not self._parse_key_segments(Equal, 0):
                    return False
                var num_keys = len(self.key_segs)
                if self.idx >= n or self._at(self.idx) != Equal:
                    return self._fail("Expected '=' after key.")
                self.idx += 1

                target_parent = self._resolve_dotted_parent[True](
                    curr_table, 0, num_keys
                )
                if target_parent == NO_NODE:
                    return False
                final_kseg = self.key_segs.unsafe_ptr()[
                    unsafe_offset=num_keys - 1
                ]
            else:
                if self.idx >= n or self._at(self.idx) != Equal:
                    return self._fail("Expected '=' after key.")
                self.idx += 1

            var val_idx = self._parse_value_node(0)
            if val_idx == NO_NODE:
                return False

            if not self._insert_value_key[False](
                target_parent, final_kseg, val_idx
            ):
                return False

            if not self._expect_comment_and_eol(
                "Expected newline after key-value pair."
            ):
                return False

        return True


struct _ParsedTape(Movable):
    """Internal raw tape output from `_parse_tape`."""

    var nodes: List[Node]
    var key_index: KeyIndex

    @always_inline
    def __init__(out self, var nodes: List[Node], var key_index: KeyIndex):
        self.nodes = nodes^
        self.key_index = key_index^

    @always_inline
    def into_parts(deinit self) -> Tuple[List[Node], KeyIndex]:
        return (self.nodes^, self.key_index^)


def _parse_tape[
    strict: Bool = True
](content: Span[Byte, _]) -> Result[_ParsedTape]:
    """Parse TOML bytes into a flat tape (`strict=True` for full TOML 1.1 checks).
    """
    var parser = _Parser[strict, content.origin](content)
    if not parser.parse_document():
        return .Err(parser^.into_error())
    return .Ok(parser^.into_tape())
