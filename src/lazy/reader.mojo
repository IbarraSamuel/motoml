"""Fast, low-allocation lazy TOML reader using a flat node tape.
"""

from .node import Node, Kind, NodeFlags, KeySeg, NO_NODE
from .key_index import KeyIndex
from .validation import Validation
from .document import Document, Value
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
    classify_scalar,
)
from ..result import Result
from std.collections import Span, List
from std.collections.string._utf8 import _is_valid_utf8


@always_inline
def _link_child(mut nodes: List[Node], parent: UInt32, child: UInt32):
    """Link a newly created child node into its parent's intrusive child list.

    Updates `first_child`, `last_child`, and `next_sibling` links on the tape.

    Args:
        nodes: Tape array of nodes.
        parent: Tape index of parent node (`NO_NODE` if none).
        child: Tape index of child node to append.
    """
    if parent == NO_NODE:
        return
    ref p = nodes[Int(parent)]
    if p.first_child == NO_NODE:
        p.first_child = child
        p.last_child = child
    else:
        nodes[Int(p.last_child)].next_sibling = child
        p.last_child = child


def parse_key_segments(
    data: Span[Byte, _],
    mut idx: Int,
    stop_byte: Byte,
) -> Result[List[KeySeg]]:
    """Parse a sequence of dotted key segments (bare or quoted).

    Scans bare identifiers, double-quoted basic strings, and single-quoted
    literal strings separated by periods (`.`) until encountering `stop_byte`
    (`=` or `]`).

    Args:
        data: Document byte buffer.
        idx: In-out scanning index pointing to key start.
        stop_byte: Delimiter byte indicating the end of the full key sequence.

    Returns:
        A `Result` containing the list of parsed `KeySeg` elements or a syntax error.
    """
    var segs = List[KeySeg](capacity=4)

    while idx < len(data):
        skip_spaces_and_tabs(data, idx)
        if idx >= len(data):
            return .Err("Unexpected EOF while parsing key.")

        var b = data[idx]
        if b == stop_byte:
            break

        if b == DoubleQuote or b == SingleQuote:
            var quote = b
            var is_literal = b == SingleQuote
            idx += 1
            var start = idx
            var has_escape = False
            while idx < len(data) and data[idx] != quote:
                var kb = data[idx]
                if kb == NewLine or kb == Enter:
                    return .Err("Newline in quoted key is not allowed.")
                if (kb < 0x20 and kb != 0x09) or kb == 0x7F:
                    return .Err(
                        "Control character in quoted key is not allowed."
                    )
                if kb == Escape and not is_literal:
                    has_escape = True
                    idx += 1  # skip escaped char
                idx += 1
            if idx >= len(data):
                return .Err("Unclosed quoted key.")
            var seg_len = idx - start
            idx += 1  # skip closing quote
            segs.append(KeySeg(UInt32(start), UInt32(seg_len), has_escape))
        elif is_bare_key_byte(b):
            var start = idx
            while idx < len(data) and is_bare_key_byte(data[idx]):
                idx += 1
            var seg_len = idx - start
            segs.append(KeySeg(UInt32(start), UInt32(seg_len), False))
        else:
            return .Err("Invalid character in key.")

        skip_spaces_and_tabs(data, idx)
        if idx < len(data) and data[idx] == Period:
            idx += 1
            skip_spaces_and_tabs(data, idx)
            if (
                idx >= len(data)
                or data[idx] == stop_byte
                or data[idx] == Period
            ):
                return .Err("Empty key segment or trailing dot in key.")
            continue
        elif idx < len(data) and data[idx] == stop_byte:
            break
        else:
            return .Err("Expected '.' or '=' in key.")

    if len(segs) == 0:
        return .Err("Empty key.")
    return .Ok(segs^)


def parse_string_value(
    data: Span[Byte, _],
    mut idx: Int,
) -> Result[Tuple[UInt32, UInt32, UInt8]]:
    """Scan a single-line or multiline basic or literal string value.

    Validates quotation delimiters, detects multiline triple quotes, checks for
    illegal unescaped control characters, and records offset, length, and flags.

    Args:
        data: Document byte buffer.
        idx: In-out scanning index pointing to opening quote.

    Returns:
        A `Result` containing `(start_offset, length, node_flags)` or a syntax error.
    """
    var quote = data[idx]
    var is_literal = quote == SingleQuote

    # Check for multiline (triple quote)
    var is_multiline = False
    if (
        idx + 2 < len(data)
        and data[idx + 1] == quote
        and data[idx + 2] == quote
    ):
        is_multiline = True
        idx += 3
        # In multiline, trim a leading newline if immediately following opening quotes
        if idx < len(data) and data[idx] == NewLine:
            idx += 1
        elif (
            idx + 1 < len(data)
            and data[idx] == Enter
            and data[idx + 1] == NewLine
        ):
            idx += 2
    else:
        idx += 1

    var start = idx
    var has_escape = False

    if is_multiline:
        while idx < len(data):
            if data[idx] == quote:
                var q_count = 0
                while (
                    idx + q_count < len(data) and data[idx + q_count] == quote
                ):
                    q_count += 1
                if q_count >= 3:
                    var extra_quotes = q_count - 3
                    if extra_quotes > 2:
                        return .Err(
                            "Too many consecutive quotes in multiline string."
                        )
                    var v_len = (idx + extra_quotes) - start
                    idx += q_count
                    var flags: UInt8 = NodeFlags.MULTILINE
                    if is_literal:
                        flags |= NodeFlags.LITERAL
                    if has_escape:
                        flags |= NodeFlags.HAS_ESCAPE
                    return .Ok((UInt32(start), UInt32(v_len), flags))
                else:
                    idx += q_count
                    continue
            var cb = data[idx]
            if cb == Enter:
                if idx + 1 >= len(data) or data[idx + 1] != NewLine:
                    return .Err("Bare carriage return in multiline string.")
            if (
                cb < 0x20 and cb != 0x09 and cb != 0x0A and cb != 0x0D
            ) or cb == 0x7F:
                return .Err("Unescaped control character in multiline string.")
            if cb == Escape and not is_literal:
                has_escape = True
                idx += 1
            idx += 1
        return .Err("Unclosed multiline string.")
    else:
        while idx < len(data) and data[idx] != quote:
            var cb = data[idx]
            if cb == NewLine or cb == Enter:
                return .Err("Newline in single-line string.")
            if (cb < 0x20 and cb != 0x09) or cb == 0x7F:
                return .Err("Unescaped control character in string.")
            if cb == Escape and not is_literal:
                has_escape = True
                idx += 1
            idx += 1
        if idx >= len(data):
            return .Err("Unclosed string.")
        var v_len = idx - start
        idx += 1  # skip closing quote
        var flags: UInt8 = 0
        if is_literal:
            flags |= NodeFlags.LITERAL
        if has_escape:
            flags |= NodeFlags.HAS_ESCAPE
        return .Ok((UInt32(start), UInt32(v_len), flags))


def parse_value_node[
    validation: Validation
](
    data: Span[Byte, _],
    mut idx: Int,
    mut nodes: List[Node],
    mut key_index: KeyIndex,
) -> Result[UInt32]:
    """Parse any TOML value (string, inline array, inline table, or scalar).

    Appends the parsed AST node(s) to the tape and returns the index of the
    root node for this value.

    Parameters:
        validation: Validation mode (`Validation.Strict` or `Validation.Trusted`).

    Args:
        data: Document byte buffer.
        idx: In-out scanning index pointing to value.
        nodes: Tape array of nodes.
        key_index: Hash index for key collision checks and lookups.

    Returns:
        A `Result` containing the tape index of the parsed node or a syntax error.
    """
    skip_spaces_and_tabs(data, idx)
    if idx >= len(data):
        return .Err("Expected value, found EOF.")

    var b = data[idx]
    if b == DoubleQuote or b == SingleQuote:
        var s_res = parse_string_value(data, idx)
        if case .Err = s_res:
            return .Err(s_res^.unsafe_take_error())
        var res = s_res^.unsafe_take_value()
        var node_idx = UInt32(len(nodes))
        nodes.append(
            Node(kind=Kind.String, flags=res[2], start=res[0], len=res[1])
        )
        return .Ok(node_idx)

    elif b == SquareBracketOpen:
        # Inline Array
        idx += 1
        var arr_idx = UInt32(len(nodes))
        nodes.append(Node(kind=Kind.Array, flags=NodeFlags.INLINE))

        while True:
            skip_whitespace_and_comments(data, idx)
            if idx >= len(data):
                return .Err("Unclosed inline array.")
            if data[idx] == SquareBracketClose:
                idx += 1
                break

            var elem_res = parse_value_node[validation](
                data, idx, nodes, key_index
            )
            if case .Err = elem_res:
                return .Err(elem_res^.unsafe_take_error())
            var elem_idx = elem_res^.unsafe_take_value()
            _link_child(nodes, arr_idx, elem_idx)

            skip_whitespace_and_comments(data, idx)
            if idx >= len(data):
                return .Err("Unclosed inline array.")
            if data[idx] == Comma:
                idx += 1
            elif data[idx] == SquareBracketClose:
                idx += 1
                break
            else:
                return .Err("Expected ',' or ']' in inline array.")

        return .Ok(arr_idx)

    elif b == CurlyBracketOpen:
        # Inline Table
        idx += 1
        var tbl_idx = UInt32(len(nodes))
        nodes.append(Node(kind=Kind.Table, flags=NodeFlags.INLINE))

        while True:
            skip_whitespace_and_comments(data, idx)
            if idx >= len(data):
                return .Err("Unclosed inline table.")
            if data[idx] == CurlyBracketClose:
                idx += 1
                break

            var k_res = parse_key_segments(data, idx, Equal)
            if case .Err = k_res:
                return .Err(k_res^.unsafe_take_error())
            var keys = k_res^.unsafe_take_value()

            if idx >= len(data) or data[idx] != Equal:
                return .Err("Expected '=' in inline table entry.")
            idx += 1

            var val_res = parse_value_node[validation](
                data, idx, nodes, key_index
            )
            if case .Err = val_res:
                return .Err(val_res^.unsafe_take_error())
            var val_idx = val_res^.unsafe_take_value()

            var target_parent = tbl_idx
            for i in range(len(keys) - 1):
                ref kseg = keys[i]
                var child = key_index.find(
                    target_parent, kseg.start, kseg.len, nodes, data
                )
                if child == NO_NODE:
                    child = UInt32(len(nodes))
                    nodes.append(
                        Node(
                            kind=Kind.Table,
                            flags=NodeFlags.DOTTED,
                            key_start=kseg.start,
                            key_len=kseg.len,
                            key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                        )
                    )
                    _link_child(nodes, target_parent, child)
                    key_index.insert(
                        target_parent,
                        kseg.start,
                        kseg.len,
                        child,
                        data,
                        kseg.has_escape,
                    )
                    target_parent = child
                else:
                    ref cnode = nodes[Int(child)]
                    if cnode.kind != Kind.Table:
                        return .Err("Cannot define dotted key on non-table.")
                    if (cnode.flags & NodeFlags.INLINE) != 0:
                        return .Err("Cannot extend inline table.")
                    target_parent = child

            ref final_kseg = keys[len(keys) - 1]
            nodes[Int(val_idx)].key_start = final_kseg.start
            nodes[Int(val_idx)].key_len = final_kseg.len
            if final_kseg.has_escape:
                nodes[Int(val_idx)].key_flags = NodeFlags.HAS_ESCAPE
            _link_child(nodes, target_parent, val_idx)

            comptime if validation != Validation.Trusted:
                if (
                    key_index.find(
                        target_parent,
                        final_kseg.start,
                        final_kseg.len,
                        nodes,
                        data,
                        final_kseg.has_escape,
                    )
                    != NO_NODE
                ):
                    return .Err("Duplicate key in inline table.")
                key_index.insert(
                    target_parent,
                    final_kseg.start,
                    final_kseg.len,
                    val_idx,
                    data,
                    final_kseg.has_escape,
                )

            skip_whitespace_and_comments(data, idx)
            if idx >= len(data):
                return .Err("Unclosed inline table.")
            if data[idx] == Comma:
                idx += 1
            elif data[idx] == CurlyBracketClose:
                idx += 1
                break
            else:
                return .Err("Expected ',' or '}' in inline table.")

        return .Ok(tbl_idx)

    else:
        # Scalar (int, float, bool, date, etc.)
        var start = idx
        while idx < len(data):
            var sb = data[idx]
            if sb == Space:
                # Check if this space separates date and time (YYYY-MM-DD HH:MM...)
                if (
                    (idx - start == 10)
                    and idx + 1 < len(data)
                    and (Byte(ord("0")) <= data[idx + 1] <= Byte(ord("9")))
                ):
                    idx += 1
                    continue
                break
            if (
                sb == Tab
                or sb == NewLine
                or sb == Enter
                or sb == Comma
                or sb == SquareBracketClose
                or sb == CurlyBracketClose
                or sb == Comment
            ):
                break
            idx += 1

        var s_len = idx - start
        if s_len == 0:
            return .Err("Empty scalar value.")

        var kind = classify_scalar(data, start, idx)
        if kind == Kind.Empty:
            return .Err(
                "Invalid scalar value: "
                + String(StringSlice(unsafe_from_utf8=data[start:idx]))
            )
        var node_idx = UInt32(len(nodes))
        nodes.append(Node(kind=kind, start=UInt32(start), len=UInt32(s_len)))
        return .Ok(node_idx)


def parse_lazy[
    validation: Validation = Validation.Strict,
](content: Span[Byte, _]) -> Result[Document[content.origin, validation]]:
    """Parse a TOML document into a zero-allocation `Document` view backed by a flat tape.

    Scans headers, keys, and values without allocating heap objects for intermediate
    strings, tables, or arrays. Keys and values borrow directly from `content`.

    Parameters:
        validation: Validation mode:
            - `Validation.Strict` (default): Enforces UTF-8, duplicate key checks,
              and full TOML 1.1 spec conformance.
            - `Validation.Trusted`: Omits UTF-8 and duplicate key checks for maximum
              parsing speed on known-valid inputs.

    Args:
        content: Borrowed span of document UTF-8 bytes.

    Returns:
        A `Result` containing the parsed `Document` view, or a parsing error.
    """
    comptime if validation != Validation.Trusted:
        if not _is_valid_utf8(content):
            return .Err("TOML document is not valid UTF-8.")

    var nodes = List[Node](capacity=max(16, len(content) // 16))
    nodes.append(Node(kind=Kind.Table, flags=NodeFlags.DEFINED))  # Root table

    var key_index = KeyIndex(initial_capacity=max(64, len(content) // 16))
    var curr_table: UInt32 = 0
    var idx = 0

    while idx < len(content):
        skip_spaces_and_tabs(content, idx)
        if idx >= len(content):
            break

        var b = content[idx]
        if b == NewLine:
            idx += 1
            continue
        if b == Enter:
            if idx + 1 < len(content) and content[idx + 1] == NewLine:
                idx += 2
                continue
            return .Err("Bare carriage return.")
        if b == Comment:
            if not skip_comment(content, idx):
                return .Err("Invalid control character or bare CR in comment.")
            continue

        if b == SquareBracketOpen:
            # Table header [table] or [[array_of_tables]]
            idx += 1
            var is_array_of_tables = False
            if idx < len(content) and content[idx] == SquareBracketOpen:
                is_array_of_tables = True
                idx += 1

            var k_res = parse_key_segments(content, idx, SquareBracketClose)
            if case .Err = k_res:
                return .Err(k_res^.unsafe_take_error())
            var keys = k_res^.unsafe_take_value()

            if idx >= len(content) or content[idx] != SquareBracketClose:
                return .Err("Unclosed table header.")
            idx += 1

            if is_array_of_tables:
                if idx >= len(content) or content[idx] != SquareBracketClose:
                    return .Err("Unclosed array of tables header.")
                idx += 1

            # Traverse / create tables under root
            var parent: UInt32 = 0
            for i in range(len(keys) - 1):
                ref kseg = keys[i]
                var child = key_index.find(
                    parent, kseg.start, kseg.len, nodes, content
                )
                if child == NO_NODE:
                    child = UInt32(len(nodes))
                    nodes.append(
                        Node(
                            kind=Kind.Table,
                            flags=NodeFlags.IMPLICIT,
                            key_start=kseg.start,
                            key_len=kseg.len,
                            key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                        )
                    )
                    _link_child(nodes, parent, child)
                    key_index.insert(
                        parent, kseg.start, kseg.len, child, content
                    )
                    parent = child
                else:
                    ref cnode = nodes[Int(child)]
                    if cnode.kind == Kind.Array:
                        if (cnode.flags & NodeFlags.ARRAY_OF_TABLES) == 0:
                            return .Err("Cannot extend static array as table.")
                        if cnode.last_child == NO_NODE:
                            return .Err("Array of tables is empty.")
                        parent = cnode.last_child
                    elif cnode.kind == Kind.Table:
                        if (cnode.flags & NodeFlags.INLINE) != 0:
                            return .Err("Cannot extend inline table.")
                        parent = child
                    else:
                        return .Err("Cannot extend non-table container.")

            if parent == NO_NODE:
                return .Err("Invalid table header hierarchy.")

            ref final_kseg = keys[len(keys) - 1]

            if is_array_of_tables:
                var arr_child = key_index.find(
                    parent, final_kseg.start, final_kseg.len, nodes, content
                )
                var arr_idx: UInt32
                if arr_child == NO_NODE:
                    arr_idx = UInt32(len(nodes))
                    nodes.append(
                        Node(
                            kind=Kind.Array,
                            flags=NodeFlags.ARRAY_OF_TABLES,
                            key_start=final_kseg.start,
                            key_len=final_kseg.len,
                            key_flags=NodeFlags.HAS_ESCAPE if final_kseg.has_escape else 0,
                        )
                    )
                    _link_child(nodes, parent, arr_idx)
                    key_index.insert(
                        parent,
                        final_kseg.start,
                        final_kseg.len,
                        arr_idx,
                        content,
                    )
                else:
                    arr_idx = arr_child
                    if (
                        nodes[Int(arr_idx)].kind != Kind.Array
                        or (
                            nodes[Int(arr_idx)].flags
                            & NodeFlags.ARRAY_OF_TABLES
                        )
                        == 0
                    ):
                        return .Err(
                            "Expected array of tables, found non-array or"
                            " static array."
                        )

                var new_table = UInt32(len(nodes))
                nodes.append(Node(kind=Kind.Table, flags=NodeFlags.DEFINED))
                _link_child(nodes, arr_idx, new_table)
                curr_table = new_table
            else:
                var existing = key_index.find(
                    parent, final_kseg.start, final_kseg.len, nodes, content
                )
                if existing == NO_NODE:
                    var new_table = UInt32(len(nodes))
                    nodes.append(
                        Node(
                            kind=Kind.Table,
                            flags=NodeFlags.DEFINED,
                            key_start=final_kseg.start,
                            key_len=final_kseg.len,
                            key_flags=NodeFlags.HAS_ESCAPE if final_kseg.has_escape else 0,
                        )
                    )
                    _link_child(nodes, parent, new_table)
                    key_index.insert(
                        parent,
                        final_kseg.start,
                        final_kseg.len,
                        new_table,
                        content,
                    )
                    curr_table = new_table
                else:
                    ref enode = nodes[Int(existing)]
                    if enode.kind != Kind.Table:
                        return .Err("Cannot redefine non-table as table.")
                    if (enode.flags & NodeFlags.INLINE) != 0:
                        return .Err("Cannot extend inline table.")
                    comptime if validation != Validation.Trusted:
                        if (enode.flags & NodeFlags.DEFINED) != 0 or (
                            enode.flags & NodeFlags.DOTTED
                        ) != 0:
                            return .Err("Table has already been defined.")
                    enode.set_flag(NodeFlags.DEFINED)
                    curr_table = existing

            skip_spaces_and_tabs(content, idx)
            if idx < len(content):
                if content[idx] == Comment:
                    if not skip_comment(content, idx):
                        return .Err(
                            "Invalid control character or bare CR in comment."
                        )
                if idx < len(content):
                    if content[idx] == NewLine:
                        idx += 1
                    elif content[idx] == Enter:
                        if (
                            idx + 1 < len(content)
                            and content[idx + 1] == NewLine
                        ):
                            idx += 2
                        else:
                            return .Err(
                                "Bare carriage return after table header."
                            )
                    else:
                        return .Err("Expected newline after table header.")

        else:
            # Key-value pair
            var k_res = parse_key_segments(content, idx, Equal)
            if case .Err = k_res:
                return .Err(k_res^.unsafe_take_error())
            var keys = k_res^.unsafe_take_value()

            if idx >= len(content) or content[idx] != Equal:
                return .Err("Expected '=' after key.")
            idx += 1

            # Traverse intermediate dotted segments under curr_table
            var target_parent = curr_table
            for i in range(len(keys) - 1):
                ref kseg = keys[i]
                var child = key_index.find(
                    target_parent, kseg.start, kseg.len, nodes, content
                )
                if child == NO_NODE:
                    child = UInt32(len(nodes))
                    nodes.append(
                        Node(
                            kind=Kind.Table,
                            flags=NodeFlags.DOTTED,
                            key_start=kseg.start,
                            key_len=kseg.len,
                            key_flags=NodeFlags.HAS_ESCAPE if kseg.has_escape else 0,
                        )
                    )
                    _link_child(nodes, target_parent, child)
                    key_index.insert(
                        target_parent,
                        kseg.start,
                        kseg.len,
                        child,
                        content,
                        kseg.has_escape,
                    )
                    target_parent = child
                else:
                    ref cnode = nodes[Int(child)]
                    if cnode.kind != Kind.Table:
                        return .Err("Cannot define dotted key on non-table.")
                    if (cnode.flags & NodeFlags.DEFINED) != 0:
                        return .Err(
                            "Cannot extend explicitly defined table with"
                            " dotted keys."
                        )
                    if (cnode.flags & NodeFlags.INLINE) != 0:
                        return .Err(
                            "Cannot extend inline table with dotted keys."
                        )
                    target_parent = child

            ref final_kseg = keys[len(keys) - 1]

            comptime if validation != Validation.Trusted:
                if (
                    key_index.find(
                        target_parent,
                        final_kseg.start,
                        final_kseg.len,
                        nodes,
                        content,
                        final_kseg.has_escape,
                    )
                    != NO_NODE
                ):
                    return .Err(
                        "Duplicate key: "
                        + String(
                            StringSlice(
                                unsafe_from_utf8=content[
                                    Int(final_kseg.start) : Int(
                                        final_kseg.start + final_kseg.len
                                    )
                                ]
                            )
                        )
                    )

            var val_res = parse_value_node[validation](
                content, idx, nodes, key_index
            )
            if case .Err = val_res:
                return .Err(val_res^.unsafe_take_error())
            var val_idx = val_res^.unsafe_take_value()

            nodes[Int(val_idx)].key_start = final_kseg.start
            nodes[Int(val_idx)].key_len = final_kseg.len
            if final_kseg.has_escape:
                nodes[Int(val_idx)].key_flags = NodeFlags.HAS_ESCAPE
            _link_child(nodes, target_parent, val_idx)
            key_index.insert(
                target_parent,
                final_kseg.start,
                final_kseg.len,
                val_idx,
                content,
                final_kseg.has_escape,
            )

            skip_spaces_and_tabs(content, idx)
            if idx < len(content):
                if content[idx] == Comment:
                    if not skip_comment(content, idx):
                        return .Err(
                            "Invalid control character or bare CR in comment."
                        )
                if idx < len(content):
                    if content[idx] == NewLine:
                        idx += 1
                    elif content[idx] == Enter:
                        if (
                            idx + 1 < len(content)
                            and content[idx + 1] == NewLine
                        ):
                            idx += 2
                        else:
                            return .Err("Bare carriage return after value.")
                    else:
                        return .Err("Expected newline after key-value pair.")

    return .Ok(
        Document[content.origin, validation](content, nodes^, key_index^, 0)
    )
