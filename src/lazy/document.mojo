"""Lazy Document and Value views over the node tape.
"""

from .node import Node, Kind, NodeFlags, NO_NODE
from .key_index import KeyIndex
from .validation import Validation
from .scalar_decode import (
    decode_int,
    decode_float,
    decode_bool,
    decode_date,
    decode_time,
    decode_datetime,
    decode_string,
    decode_string_to_writer,
)
from ..types.tempo import Date, Time, DateTime
from ..types.toml import Toml
from ..result import Result
from std.collections import Span, Dict, List


struct Value[origin: ImmOrigin, validation: Validation = Validation.Strict](
    Copyable, ImplicitlyCopyable, Movable, Sized
):
    var doc_bytes: Span[Byte, Self.origin]
    var nodes_ptr: Pointer[Node, Self.origin]
    var nodes_len: Int
    var key_index_ptr: Pointer[KeyIndex, Self.origin]
    var node_idx: UInt32

    @always_inline
    def __init__(
        out self,
        doc_bytes: Span[Byte, Self.origin],
        nodes_ptr: Pointer[Node, Self.origin],
        nodes_len: Int,
        key_index_ptr: Pointer[KeyIndex, Self.origin],
        node_idx: UInt32,
    ):
        self.doc_bytes = doc_bytes
        self.nodes_ptr = nodes_ptr
        self.nodes_len = nodes_len
        self.key_index_ptr = key_index_ptr
        self.node_idx = node_idx

    @always_inline
    def _node(self) -> ref[self.origin] Node:
        return self.nodes_ptr.unsafe_offset(Int(self.node_idx))[]

    @always_inline
    def kind(self) -> UInt8:
        return self._node().kind

    @always_inline
    def is_table(self) -> Bool:
        return self.kind() == Kind.Table

    @always_inline
    def is_array(self) -> Bool:
        return self.kind() == Kind.Array

    @always_inline
    def is_string(self) -> Bool:
        return self.kind() == Kind.String

    @always_inline
    def is_int(self) -> Bool:
        return self.kind() == Kind.Integer

    @always_inline
    def is_float(self) -> Bool:
        return self.kind() == Kind.Float

    @always_inline
    def is_bool(self) -> Bool:
        return self.kind() == Kind.Boolean

    @always_inline
    def key_bytes(self) -> Span[Byte, self.origin]:
        ref node = self._node()
        return self.doc_bytes[
            Int(node.key_start) : Int(node.key_start + node.key_len)
        ]

    @always_inline
    def key_slice(self) -> StringSlice[self.origin]:
        return StringSlice(unsafe_from_utf8=self.key_bytes())

    @always_inline
    def raw_bytes(self) -> Span[Byte, self.origin]:
        ref node = self._node()
        return self.doc_bytes[Int(node.start) : Int(node.start + node.len)]

    @always_inline
    def as_slice(self) -> Optional[StringSlice[self.origin]]:
        ref node = self._node()
        if (node.flags & NodeFlags.HAS_ESCAPE) == 0:
            return StringSlice(unsafe_from_utf8=self.raw_bytes())
        return None

    def as_string(self) -> Result[String]:
        ref node = self._node()
        return decode_string(self.raw_bytes(), node.flags)

    def as_int(self) -> Result[Int]:
        return decode_int(self.raw_bytes())

    def as_float(self) -> Result[Float64]:
        return decode_float(self.raw_bytes())

    def as_bool(self) -> Result[Bool]:
        return decode_bool(self.raw_bytes())

    def as_date(self) -> Result[Date]:
        return decode_date(self.raw_bytes())

    def as_time(self) -> Result[Time]:
        return decode_time(self.raw_bytes())

    def as_datetime(self) -> Result[DateTime]:
        return decode_datetime(self.raw_bytes())

    def __getitem__(self, key: StringSlice) -> Optional[Self]:
        ref node = self._node()
        if node.kind != Kind.Table:
            return None

        var key_b = key.as_bytes()
        var child_idx = self.key_index_ptr[].find_by_bytes(
            self.node_idx, key_b, self.nodes_ptr, self.doc_bytes
        )
        if child_idx == NO_NODE:
            return None

        return Self(
            self.doc_bytes,
            self.nodes_ptr,
            self.nodes_len,
            self.key_index_ptr,
            child_idx,
        )

    def __getitem__(self, index: Int) -> Optional[Self]:
        ref node = self._node()
        if node.kind != Kind.Array:
            return None

        var curr = node.first_child
        var i = 0
        while curr != NO_NODE:
            if i == index:
                return Self(
                    self.doc_bytes,
                    self.nodes_ptr,
                    self.nodes_len,
                    self.key_index_ptr,
                    curr,
                )
            curr = self.nodes_ptr.unsafe_offset(Int(curr))[].next_sibling
            i += 1
        return None

    def __len__(self) -> Int:
        ref node = self._node()
        var count = 0
        var curr = node.first_child
        while curr != NO_NODE:
            count += 1
            curr = self.nodes_ptr.unsafe_offset(Int(curr))[].next_sibling
        return count

    def to_json[W: Writer](self, mut w: W) raises:
        ref node = self._node()
        var k = node.kind
        if k == Kind.String:
            w.write('{"type": "string", "value": "')
            var str_res = self.as_string()
            if case .Err = str_res:
                raise Error(str_res^.unsafe_take_error())
            var s = str_res^.unsafe_take_value()
            var s_bytes = s.as_bytes()
            var s_idx = 0
            while s_idx < len(s_bytes):
                var chunk_start = s_idx
                while s_idx < len(s_bytes):
                    var b = s_bytes[s_idx]
                    if (
                        b == Byte(ord('"'))
                        or b == Byte(ord("\\"))
                        or b == Byte(ord("\n"))
                        or b == Byte(ord("\r"))
                        or b == Byte(ord("\t"))
                        or b == Byte(ord("\b"))
                        or b == Byte(ord("\x0c"))
                    ):
                        break
                    s_idx += 1
                if s_idx > chunk_start:
                    w.write(
                        StringSlice(unsafe_from_utf8=s_bytes[chunk_start:s_idx])
                    )
                if s_idx >= len(s_bytes):
                    break
                var esc_b = s_bytes[s_idx]
                if esc_b == Byte(ord('"')):
                    w.write('\\"')
                elif esc_b == Byte(ord("\\")):
                    w.write("\\\\")
                elif esc_b == Byte(ord("\n")):
                    w.write("\\n")
                elif esc_b == Byte(ord("\r")):
                    w.write("\\r")
                elif esc_b == Byte(ord("\t")):
                    w.write("\\t")
                elif esc_b == Byte(ord("\b")):
                    w.write("\\b")
                elif esc_b == Byte(ord("\x0c")):
                    w.write("\\f")
                s_idx += 1
            w.write('"}')
        elif k == Kind.Integer:
            var val = self.as_int()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            w.write(
                '{"type": "integer", "value": "', val^.unsafe_take_value(), '"}'
            )
        elif k == Kind.Float:
            var val = self.as_float()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            w.write(
                '{"type": "float", "value": "', val^.unsafe_take_value(), '"}'
            )
        elif k == Kind.NaN:
            w.write('{"type": "float", "value": "nan"}')
        elif k == Kind.Inf:
            var b = self.raw_bytes()
            if len(b) > 0 and b[0] == Byte(ord("-")):
                w.write('{"type": "float", "value": "-inf"}')
            else:
                w.write('{"type": "float", "value": "inf"}')
        elif k == Kind.Boolean:
            var val = self.as_bool()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            w.write(
                '{"type": "bool", "value": "',
                "true" if val^.unsafe_take_value() else "false",
                '"}',
            )
        elif k == Kind.Date:
            var val = self.as_date()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            w.write(
                '{"type": "date-local", "value": "',
                val^.unsafe_take_value(),
                '"}',
            )
        elif k == Kind.Time:
            var val = self.as_time()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            w.write(
                '{"type": "time-local", "value": "',
                val^.unsafe_take_value(),
                '"}',
            )
        elif k == Kind.DateTime:
            var val = self.as_datetime()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            var dt = val^.unsafe_take_value()
            var nm = "datetime-local" if dt.is_local else "datetime"
            w.write('{"type": "', nm, '", "value": "', dt, '"}')
        elif k == Kind.Array:
            w.write("[")
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    w.write(", ")
                first = False
                var child_val = Self(
                    self.doc_bytes,
                    self.nodes_ptr,
                    self.nodes_len,
                    self.key_index_ptr,
                    curr,
                )
                child_val.to_json(w)
                curr = self.nodes_ptr.unsafe_offset(Int(curr))[].next_sibling
            w.write("]")
        elif k == Kind.Table:
            w.write("{")
            var curr = node.first_child
            var first = True
            while curr != NO_NODE:
                if not first:
                    w.write(", ")
                first = False
                ref child_node = self.nodes_ptr.unsafe_offset(Int(curr))[]
                w.write('"')
                if (child_node.key_flags & NodeFlags.HAS_ESCAPE) != 0:
                    var dec_res = decode_string(
                        self.doc_bytes[
                            Int(child_node.key_start) : Int(
                                child_node.key_start + child_node.key_len
                            )
                        ],
                        child_node.key_flags,
                    )
                    if case .Ok(var k_str) = dec_res:
                        var k_b = k_str.as_bytes()
                        var ki = 0
                        while ki < len(k_b):
                            var cs = ki
                            while ki < len(k_b):
                                var b = k_b[ki]
                                if (
                                    b == Byte(ord('"'))
                                    or b == Byte(ord("\\"))
                                    or b == Byte(ord("\n"))
                                    or b == Byte(ord("\r"))
                                    or b == Byte(ord("\t"))
                                    or b == Byte(ord("\b"))
                                    or b == Byte(ord("\x0c"))
                                ):
                                    break
                                ki += 1
                            if ki > cs:
                                w.write(
                                    StringSlice(unsafe_from_utf8=k_b[cs:ki])
                                )
                            if ki >= len(k_b):
                                break
                            var eb = k_b[ki]
                            if eb == Byte(ord('"')):
                                w.write('\\"')
                            elif eb == Byte(ord("\\")):
                                w.write("\\\\")
                            elif eb == Byte(ord("\n")):
                                w.write("\\n")
                            elif eb == Byte(ord("\r")):
                                w.write("\\r")
                            elif eb == Byte(ord("\t")):
                                w.write("\\t")
                            elif eb == Byte(ord("\b")):
                                w.write("\\b")
                            elif eb == Byte(ord("\x0c")):
                                w.write("\\f")
                            ki += 1
                        _ = dec_res^.unsafe_take_value()
                    else:
                        _ = dec_res^.unsafe_take_error()
                else:
                    var k_bytes = self.doc_bytes[
                        Int(child_node.key_start) : Int(
                            child_node.key_start + child_node.key_len
                        )
                    ]
                    var k_idx = 0
                    while k_idx < len(k_bytes):
                        var chunk_start = k_idx
                        while k_idx < len(k_bytes):
                            var b = k_bytes[k_idx]
                            if b == Byte(ord('"')) or b == Byte(ord("\\")):
                                break
                            k_idx += 1
                        if k_idx > chunk_start:
                            w.write(
                                StringSlice(
                                    unsafe_from_utf8=k_bytes[chunk_start:k_idx]
                                )
                            )
                        if k_idx >= len(k_bytes):
                            break
                        var esc_b = k_bytes[k_idx]
                        if esc_b == Byte(ord('"')):
                            w.write('\\"')
                        elif esc_b == Byte(ord("\\")):
                            w.write("\\\\")
                        k_idx += 1
                w.write('": ')
                var child_val = Self(
                    self.doc_bytes,
                    self.nodes_ptr,
                    self.nodes_len,
                    self.key_index_ptr,
                    curr,
                )
                child_val.to_json(w)
                curr = child_node.next_sibling
            w.write("}")

    def to_toml(self) raises -> Toml:
        ref node = self._node()
        var k = node.kind
        if k == Kind.String:
            var s = self.as_string()
            if case .Err = s:
                raise Error(s^.unsafe_take_error())
            return Toml.String(s^.unsafe_take_value())
        elif k == Kind.Integer:
            var val = self.as_int()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            return Toml.Integer(val^.unsafe_take_value())
        elif k == Kind.Float:
            var val = self.as_float()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            return Toml.Float(val^.unsafe_take_value())
        elif k == Kind.NaN:
            return materialize[Toml.NaN]()
        elif k == Kind.Boolean:
            var val = self.as_bool()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            return Toml.Boolean(val^.unsafe_take_value())
        elif k == Kind.Date:
            var val = self.as_date()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            return Toml.Date(val^.unsafe_take_value())
        elif k == Kind.Time:
            var val = self.as_time()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            return Toml.Time(val^.unsafe_take_value())
        elif k == Kind.DateTime:
            var val = self.as_datetime()
            if case .Err = val:
                raise Error(val^.unsafe_take_error())
            return Toml.DateTime(val^.unsafe_take_value())
        elif k == Kind.Array:
            var list = List[Toml]()
            var curr = node.first_child
            while curr != NO_NODE:
                var child_val = Self(
                    self.doc_bytes,
                    self.nodes_ptr,
                    self.nodes_len,
                    self.key_index_ptr,
                    curr,
                )
                list.append(child_val.to_toml())
                curr = self.nodes_ptr.unsafe_offset(Int(curr))[].next_sibling
            return Toml.Array(list^)
        elif k == Kind.Table:
            var dict = Dict[String, Toml]()
            var curr = node.first_child
            while curr != NO_NODE:
                ref child_node = self.nodes_ptr.unsafe_offset(Int(curr))[]
                var key_str = String(
                    StringSlice(
                        unsafe_from_utf8=self.doc_bytes[
                            Int(child_node.key_start) : Int(
                                child_node.key_start + child_node.key_len
                            )
                        ]
                    )
                )
                var child_val = Self(
                    self.doc_bytes,
                    self.nodes_ptr,
                    self.nodes_len,
                    self.key_index_ptr,
                    curr,
                )
                dict[key_str] = child_val.to_toml()
                curr = child_node.next_sibling
            return Toml.Table(dict^)
        return Toml.Table(Dict[String, Toml]())


struct Document[origin: ImmOrigin, validation: Validation = Validation.Strict](
    Movable, Sized
):
    var data: Span[Byte, Self.origin]
    var nodes: List[Node]
    var key_index: KeyIndex
    var root_idx: UInt32

    def __init__(
        out self,
        data: Span[Byte, Self.origin],
        var nodes: List[Node],
        var key_index: KeyIndex,
        root_idx: UInt32 = 0,
    ):
        self.data = data
        self.nodes = nodes^
        self.key_index = key_index^
        self.root_idx = root_idx

    @always_inline
    def root(ref self) -> Value[Self.origin, Self.validation]:
        return Value[Self.origin, Self.validation](
            self.data,
            Pointer(to=self.nodes[0])
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[Self.origin](),
            len(self.nodes),
            Pointer(to=self.key_index)
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[Self.origin](),
            self.root_idx,
        )

    @always_inline
    def __getitem__(
        ref self, key: StringSlice
    ) -> Optional[Value[Self.origin, Self.validation]]:
        return self.root()[key]

    @always_inline
    def __len__(self) -> Int:
        return len(self.root())

    def to_json[W: Writer](ref self, mut w: W) raises:
        self.root().to_json(w)

    def to_toml(ref self) raises -> Toml:
        return self.root().to_toml()
