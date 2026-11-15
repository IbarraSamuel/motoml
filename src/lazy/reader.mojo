"""Fast, low-allocation lazy TOML reader using a flat node tape.
"""

from .node import Node, NodeKind, NodeFlags, KeySeg, NO_NODE
from .key_index import (
    KeyIndex,
    FNV_OFFSET_BASIS,
    FNV_PRIME,
    compute_escaped_key_hash,
)
from .validation import Validation, validation_level
from .scalar_decode import validate_scalar, check_escape_at
from .lexer import (
    SquareBracketOpen,
    SquareBracketClose,
    CurlyBracketOpen,
    CurlyBracketClose,
    NewLine,
    Enter,
    Space,
    Tab,
    Comment,
    Comma,
    Equal,
    Period,
    DoubleQuote,
    SingleQuote,
    Escape,
    is_bare_key_byte,
    skip_spaces_and_tabs,
    skip_to_newline,
    skip_comment,
    skip_whitespace_and_comments,
    scan_and_classify_scalar,
    is_valid_utf8_fast,
)
from ..result import Result
from std.collections import Span, List
from std.memory import pack_bits
from std.bit import count_trailing_zeros

comptime MAX_NESTING_DEPTH: Int = 512


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


struct _Parser[validation: Validation, origin: ImmOrigin](Movable):
    """Internal stateful parser that reuses scratch buffers across keys and values.
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
        self.nodes = List[Node](capacity=max(16, self.length // 14))
        self.nodes.append(Node(kind=NodeKind.Table, flags=NodeFlags.DEFINED))
        self.key_index = KeyIndex(initial_capacity=max(64, self.length // 12))
        self.key_segs = List[KeySeg](capacity=32)
        self.esc_scratch = String()
        self.err_msg = String()

    @always_inline
    def _at(self, i: Int) -> Byte:
        debug_assert(0 <= i and i < self.length, "cursor index out of bounds")
        return self.ptr[unsafe_offset=i]

    def _fail(mut self, var msg: String) -> Bool:
        self.err_msg = msg^
        return False

    def _fail_node(mut self, var msg: String) -> UInt32:
        self.err_msg = msg^
        return NO_NODE

    def _fail_invalid_scalar(mut self, start: Int) -> UInt32:
        self.err_msg = "Invalid scalar value: " + String(
            StringSpan(unsafe_from_utf8=self.data[start : self.idx])
        )
        return NO_NODE

    @always_inline
    def into_error(deinit self) -> Error:
        return Error(self.err_msg^)

    @always_inline
    def into_tape(deinit self) -> _ParsedTape:
        return _ParsedTape(self.nodes^, self.key_index^)

    def _parse_quoted_key_seg(mut self, quote: Byte, mut seg: KeySeg) -> Bool:
        """Scan a quoted key segment and compute its FNV-1a unescaped hash."""
        var n = self.length
        var is_literal = quote == SingleQuote
        self.idx += 1
        var start = self.idx
        var has_escape = False
        var h: UInt32 = FNV_OFFSET_BASIS
        while self.idx < n and self._at(self.idx) != quote:
            var kb = self._at(self.idx)
            comptime if Self.validation != Validation.Trusted:
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
            comptime if validation_level(Self.validation) >= 2:
                if not eh[0]:
                    return self._fail("Invalid escape sequence in quoted key.")
            h = eh[1]
        seg = KeySeg(UInt32(start), UInt32(seg_len), h, has_escape)
        return True

    @always_inline
    def _parse_one_key_seg(mut self, mut seg: KeySeg) -> Bool:
        """Parse a single bare or quoted key segment at `self.idx` into `seg`.
        """
        var n = self.length
        var b = self._at(self.idx)
        if is_bare_key_byte(b):
            var start = self.idx
            var h: UInt32 = (FNV_OFFSET_BASIS ^ UInt32(b)) * FNV_PRIME
            self.idx += 1
            while self.idx < n:
                var kb = self._at(self.idx)
                if not is_bare_key_byte(kb):
                    break
                h = (h ^ UInt32(kb)) * FNV_PRIME
                self.idx += 1
            seg = KeySeg(UInt32(start), UInt32(self.idx - start), h, False)
            return True

        if b == DoubleQuote or b == SingleQuote:
            return self._parse_quoted_key_seg(b, seg)

        return self._fail("Invalid character in key.")

    def parse_key_segments(mut self, stop_byte: Byte, base: Int) -> Bool:
        """Append dotted key segments onto `self.key_segs` starting at `base`, computing hashes inline.
        """
        var n = self.length
        while self.idx < n:
            skip_spaces_and_tabs(self.data, self.idx)
            if self.idx >= n:
                return self._fail("Unexpected EOF while parsing key.")

            var b = self._at(self.idx)
            if b == stop_byte:
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

    def _parse_multiline_string_node(mut self, quote: Byte) -> UInt32:
        """Scan a multiline basic or literal string and append its node."""
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
        comptime strict_ctrl = Self.validation != Validation.Trusted

        while self.idx < n:
            while self.idx + W <= n:
                var v = self.ptr.unsafe_load[width=W](self.idx)
                var stop = v.eq(quote)
                if not is_literal:
                    stop |= v.eq(Escape)
                comptime if strict_ctrl:
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
            comptime if strict_ctrl:
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
                comptime if validation_level(Self.validation) >= 2:
                    if not check_escape_at[True](self.ptr, n, self.idx):
                        return self._fail_node(
                            "Invalid escape sequence in multiline string."
                        )
            self.idx += 1
        return self._fail_node("Unclosed multiline string.")

    @always_inline
    def _scan_single_line_string[is_literal: Bool](mut self) -> UInt32:
        """Scan a single-line basic or literal string and append its node."""
        comptime quote: Byte = SingleQuote if is_literal else DoubleQuote
        comptime strict_ctrl = Self.validation != Validation.Trusted
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
            comptime if strict_ctrl:
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
                comptime if strict_ctrl:
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
                        comptime if validation_level(Self.validation) >= 2:
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
            comptime if strict_ctrl:
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
                    comptime if validation_level(Self.validation) >= 2:
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
    def parse_string_node(mut self) -> UInt32:
        """Scan a single-line or multiline basic or literal string and append its node.
        """
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
    def parse_scalar_node(mut self) -> UInt32:
        """Scan, validate, and append an unquoted scalar node at `self.idx`."""
        var start = self.idx
        var sc = scan_and_classify_scalar(self.data, self.idx)
        var s_len = sc[0]
        var kind = sc[1]
        var pv = sc[2]
        if s_len == 0:
            return self._fail_node("Empty scalar value.")
        if kind == NodeKind.Empty:
            return self._fail_invalid_scalar(start)
        comptime if validation_level(Self.validation) >= 2:
            if pv == 0 and not validate_scalar(
                kind, self.data[start : self.idx]
            ):
                return self._fail_node("Invalid scalar literal.")
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
        """Parse a value when `self.idx < self.length` and whitespace is already skipped.
        """
        var b = self._at(self.idx)
        if b == DoubleQuote or b == SingleQuote:
            return self.parse_string_node()
        if b == SquareBracketOpen:
            return self.parse_array_node(depth)
        if b == CurlyBracketOpen:
            return self.parse_inline_table_node(depth)
        return self.parse_scalar_node()

    def parse_array_node(mut self, depth: Int) -> UInt32:
        """Parse an inline array `[ ... ]` and return its node index."""
        if depth >= MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.")
        var n = self.length
        self.idx += 1
        var arr_idx = UInt32(len(self.nodes))
        self.nodes.append(Node(kind=NodeKind.Array, flags=NodeFlags.INLINE))
        comptime strict_ws = Self.validation != Validation.Trusted

        while True:
            if not skip_whitespace_and_comments[strict_ws](self.data, self.idx):
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

            if not skip_whitespace_and_comments[strict_ws](self.data, self.idx):
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

    def parse_inline_table_node(mut self, depth: Int) -> UInt32:
        """Parse an inline table `{ ... }` and return its node index."""
        if depth >= MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.")
        var n = self.length
        self.idx += 1
        var tbl_idx = UInt32(len(self.nodes))
        self.nodes.append(Node(kind=NodeKind.Table, flags=NodeFlags.INLINE))
        comptime strict_ws = Self.validation != Validation.Trusted

        while True:
            if not skip_whitespace_and_comments[strict_ws](self.data, self.idx):
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
            var target_parent = tbl_idx
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
                if not self.parse_key_segments(Equal, key_base):
                    self.key_segs.shrink(key_base)
                    return NO_NODE
                var key_end = len(self.key_segs)
                if self.idx >= n or self._at(self.idx) != Equal:
                    self.key_segs.shrink(key_base)
                    return self._fail_node(
                        "Expected '=' in inline table entry."
                    )
                self.idx += 1

                var val_idx = self.parse_value_node(depth + 1)
                if val_idx == NO_NODE:
                    self.key_segs.shrink(key_base)
                    return NO_NODE

                for i in range(key_base, key_end - 1):
                    var kseg = self.key_segs.unsafe_ptr()[unsafe_offset=i]
                    var cand_idx = UInt32(len(self.nodes))
                    var existing = self.key_index.find_or_insert(
                        target_parent,
                        kseg,
                        cand_idx,
                        self.nodes,
                        self.data,
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
                        _link_child(self.nodes, target_parent, cand_idx)
                        target_parent = cand_idx
                    else:
                        ref cnode = self.nodes.unsafe_ptr()[
                            unsafe_offset=Int(existing)
                        ]
                        if cnode.kind != NodeKind.Table:
                            self.key_segs.shrink(key_base)
                            return self._fail_node(
                                "Cannot define dotted key on non-table."
                            )
                        if (cnode.flags & NodeFlags.INLINE) != 0:
                            self.key_segs.shrink(key_base)
                            return self._fail_node(
                                "Cannot extend inline table."
                            )
                        target_parent = existing

                final_kseg = self.key_segs.unsafe_ptr()[
                    unsafe_offset=key_end - 1
                ]
                self.key_segs.shrink(key_base)

                comptime if Self.validation != Validation.Trusted:
                    var dup = self.key_index.find_or_insert[True](
                        target_parent,
                        final_kseg,
                        val_idx,
                        self.nodes,
                        self.data,
                    )
                    if dup != NO_NODE:
                        return self._fail_node("Duplicate key in inline table.")
                else:
                    _ = self.key_index.find_or_insert[False](
                        target_parent,
                        final_kseg,
                        val_idx,
                        self.nodes,
                        self.data,
                    )

                ref vnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(val_idx)]
                vnode.key_start = final_kseg.start
                vnode.key_len = final_kseg.len
                if final_kseg.has_escape:
                    vnode.key_flags = NodeFlags.HAS_ESCAPE
                _link_child(self.nodes, target_parent, val_idx)
            else:
                if self.idx >= n or self._at(self.idx) != Equal:
                    return self._fail_node(
                        "Expected '=' in inline table entry."
                    )
                self.idx += 1

                var val_idx = self.parse_value_node(depth + 1)
                if val_idx == NO_NODE:
                    return NO_NODE

                comptime if Self.validation != Validation.Trusted:
                    var dup = self.key_index.find_or_insert[True](
                        tbl_idx,
                        final_kseg,
                        val_idx,
                        self.nodes,
                        self.data,
                    )
                    if dup != NO_NODE:
                        return self._fail_node("Duplicate key in inline table.")
                else:
                    _ = self.key_index.find_or_insert[False](
                        tbl_idx,
                        final_kseg,
                        val_idx,
                        self.nodes,
                        self.data,
                    )

                ref vnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(val_idx)]
                vnode.key_start = final_kseg.start
                vnode.key_len = final_kseg.len
                if final_kseg.has_escape:
                    vnode.key_flags = NodeFlags.HAS_ESCAPE
                _link_child(self.nodes, tbl_idx, val_idx)

            if not skip_whitespace_and_comments[strict_ws](self.data, self.idx):
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

    @always_inline
    def parse_value_node(mut self, depth: Int = 0) -> UInt32:
        """Parse any TOML value and return its node index (`NO_NODE` on error).
        """
        if depth > MAX_NESTING_DEPTH:
            return self._fail_node("Maximum nesting depth exceeded.")

        var n = self.length
        skip_spaces_and_tabs(self.data, self.idx)
        if self.idx >= n:
            return self._fail_node("Expected value, found EOF.")

        return self._parse_value_at_cursor(depth)

    def parse_document(mut self) -> Bool:
        """Main document scanning loop."""
        comptime if Self.validation != Validation.Trusted:
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
                comptime if Self.validation != Validation.Trusted:
                    if not skip_comment(self.data, self.idx):
                        return self._fail(
                            "Invalid control character or bare CR in comment."
                        )
                else:
                    skip_to_newline(self.data, self.idx)
                continue

            if b == SquareBracketOpen:
                self.idx += 1
                var is_array_of_tables = False
                if self.idx < n and self._at(self.idx) == SquareBracketOpen:
                    is_array_of_tables = True
                    self.idx += 1

                self.key_segs.shrink(0)
                if not self.parse_key_segments(SquareBracketClose, 0):
                    return False
                var num_keys = len(self.key_segs)

                if self.idx >= n or self._at(self.idx) != SquareBracketClose:
                    return self._fail("Unclosed table header.")
                self.idx += 1

                if is_array_of_tables:
                    if (
                        self.idx >= n
                        or self._at(self.idx) != SquareBracketClose
                    ):
                        return self._fail("Unclosed array of tables header.")
                    self.idx += 1

                var parent: UInt32 = 0
                for i in range(num_keys - 1):
                    var kseg = self.key_segs.unsafe_ptr()[unsafe_offset=i]
                    var cand_idx = UInt32(len(self.nodes))
                    var child = self.key_index.find_or_insert(
                        parent,
                        kseg,
                        cand_idx,
                        self.nodes,
                        self.data,
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
                        ref cnode = self.nodes.unsafe_ptr()[
                            unsafe_offset=Int(child)
                        ]
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
                            return self._fail(
                                "Cannot extend non-table container."
                            )

                if parent == NO_NODE:
                    return self._fail("Invalid table header hierarchy.")

                var final_kseg = self.key_segs.unsafe_ptr()[
                    unsafe_offset=num_keys - 1
                ]

                if is_array_of_tables:
                    var cand_arr = UInt32(len(self.nodes))
                    var arr_child = self.key_index.find_or_insert(
                        parent,
                        final_kseg,
                        cand_arr,
                        self.nodes,
                        self.data,
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
                        ref anode = self.nodes.unsafe_ptr()[
                            unsafe_offset=Int(arr_idx)
                        ]
                        if (
                            anode.kind != NodeKind.Array
                            or (anode.flags & NodeFlags.ARRAY_OF_TABLES) == 0
                        ):
                            return self._fail(
                                "Expected array of tables, found non-array or"
                                " static array."
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
                        final_kseg,
                        cand_tbl,
                        self.nodes,
                        self.data,
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
                        ref enode = self.nodes.unsafe_ptr()[
                            unsafe_offset=Int(existing)
                        ]
                        if enode.kind != NodeKind.Table:
                            return self._fail(
                                "Cannot redefine non-table as table."
                            )
                        if (enode.flags & NodeFlags.INLINE) != 0:
                            return self._fail("Cannot extend inline table.")
                        comptime if Self.validation != Validation.Trusted:
                            if (enode.flags & NodeFlags.DEFINED) != 0 or (
                                enode.flags & NodeFlags.DOTTED
                            ) != 0:
                                return self._fail(
                                    "Table has already been defined."
                                )
                        enode.set_flag(NodeFlags.DEFINED)
                        curr_table = existing

                skip_spaces_and_tabs(self.data, self.idx)
                if self.idx < n:
                    if self._at(self.idx) == Comment:
                        comptime if Self.validation != Validation.Trusted:
                            if not skip_comment(self.data, self.idx):
                                return self._fail(
                                    "Invalid control character or bare CR in"
                                    " comment."
                                )
                        else:
                            skip_to_newline(self.data, self.idx)
                    if self.idx < n:
                        var end_b = self._at(self.idx)
                        if end_b == NewLine:
                            self.idx += 1
                        elif end_b == Enter:
                            if (
                                self.idx + 1 < n
                                and self._at(self.idx + 1) == NewLine
                            ):
                                self.idx += 2
                            else:
                                return self._fail(
                                    "Bare carriage return after table header."
                                )
                        else:
                            return self._fail(
                                "Expected newline after table header."
                            )

            else:
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
                    if not self.parse_key_segments(Equal, 0):
                        return False
                    var num_keys = len(self.key_segs)
                    if self.idx >= n or self._at(self.idx) != Equal:
                        return self._fail("Expected '=' after key.")
                    self.idx += 1

                    for i in range(num_keys - 1):
                        var kseg = self.key_segs.unsafe_ptr()[unsafe_offset=i]
                        var cand_idx = UInt32(len(self.nodes))
                        var child = self.key_index.find_or_insert(
                            target_parent,
                            kseg,
                            cand_idx,
                            self.nodes,
                            self.data,
                        )
                        if child == NO_NODE:
                            self.nodes.append(
                                Node(
                                    kind=NodeKind.Table,
                                    flags=NodeFlags.DOTTED,
                                    key_start=kseg.start,
                                    key_len=kseg.len,
                                    key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                                )
                            )
                            _link_child(self.nodes, target_parent, cand_idx)
                            target_parent = cand_idx
                        else:
                            ref cnode = self.nodes.unsafe_ptr()[
                                unsafe_offset=Int(child)
                            ]
                            if cnode.kind != NodeKind.Table:
                                return self._fail(
                                    "Cannot define dotted key on non-table."
                                )
                            if (cnode.flags & NodeFlags.DEFINED) != 0:
                                return self._fail(
                                    "Cannot extend explicitly defined table"
                                    " with dotted keys."
                                )
                            if (cnode.flags & NodeFlags.INLINE) != 0:
                                return self._fail(
                                    "Cannot extend inline table with dotted"
                                    " keys."
                                )
                            target_parent = child

                    final_kseg = self.key_segs.unsafe_ptr()[
                        unsafe_offset=num_keys - 1
                    ]
                else:
                    if self.idx >= n or self._at(self.idx) != Equal:
                        return self._fail("Expected '=' after key.")
                    self.idx += 1

                var val_idx = self.parse_value_node(0)
                if val_idx == NO_NODE:
                    return False

                comptime if Self.validation != Validation.Trusted:
                    var dup = self.key_index.find_or_insert[True](
                        target_parent,
                        final_kseg,
                        val_idx,
                        self.nodes,
                        self.data,
                    )
                    if dup != NO_NODE:
                        return self._fail(
                            "Duplicate key: "
                            + String(
                                StringSpan(
                                    unsafe_from_utf8=self.data[
                                        Int(final_kseg.start) : Int(
                                            final_kseg.start + final_kseg.len
                                        )
                                    ]
                                )
                            )
                        )
                else:
                    _ = self.key_index.find_or_insert[False](
                        target_parent,
                        final_kseg,
                        val_idx,
                        self.nodes,
                        self.data,
                    )

                ref vnode = self.nodes.unsafe_ptr()[unsafe_offset=Int(val_idx)]
                vnode.key_start = final_kseg.start
                vnode.key_len = final_kseg.len
                if final_kseg.has_escape:
                    vnode.key_flags = NodeFlags.HAS_ESCAPE
                _link_child(self.nodes, target_parent, val_idx)

                if self.idx < n and self._at(self.idx) == NewLine:
                    self.idx += 1
                else:
                    skip_spaces_and_tabs(self.data, self.idx)
                    if self.idx < n:
                        if self._at(self.idx) == Comment:
                            comptime if Self.validation != Validation.Trusted:
                                if not skip_comment(self.data, self.idx):
                                    return self._fail(
                                        "Invalid control character or bare CR"
                                        " in comment."
                                    )
                            else:
                                skip_to_newline(self.data, self.idx)
                        if self.idx < n:
                            var end_b = self._at(self.idx)
                            if end_b == NewLine:
                                self.idx += 1
                            elif end_b == Enter:
                                if (
                                    self.idx + 1 < n
                                    and self._at(self.idx + 1) == NewLine
                                ):
                                    self.idx += 2
                                else:
                                    return self._fail(
                                        "Bare carriage return after value."
                                    )
                            else:
                                return self._fail(
                                    "Expected newline after key-value pair."
                                )

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
    def take_into(deinit self, mut nodes: List[Node], mut key_index: KeyIndex):
        nodes = self.nodes^
        key_index = self.key_index^


def _parse_tape[
    validation: Validation = Validation.Strict,
](content: Span[Byte, _]) -> Result[_ParsedTape]:
    """Internal tape parser shared by all `Mode`s."""
    var parser = _Parser[validation, content.origin](content)
    if not parser.parse_document():
        return .Err(parser^.into_error())
    return .Ok(parser^.into_tape())
