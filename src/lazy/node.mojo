"""Tape Node representation for zero-allocation TOML parsing.
"""

comptime NO_NODE: UInt32 = 0xFFFFFFFF


struct Kind:
    comptime Empty: UInt8 = 0
    comptime String: UInt8 = 1
    comptime Integer: UInt8 = 2
    comptime Float: UInt8 = 3
    comptime Boolean: UInt8 = 4
    comptime Date: UInt8 = 5
    comptime Time: UInt8 = 6
    comptime DateTime: UInt8 = 7
    comptime Array: UInt8 = 8
    comptime Table: UInt8 = 9
    comptime NaN: UInt8 = 10
    comptime Inf: UInt8 = 11


struct NodeFlags:
    comptime HAS_ESCAPE: UInt8 = 1 << 0
    comptime LITERAL: UInt8 = 1 << 1
    comptime MULTILINE: UInt8 = 1 << 2
    comptime INLINE: UInt8 = 1 << 3
    comptime IMPLICIT: UInt8 = 1 << 4
    comptime DOTTED: UInt8 = 1 << 5
    comptime DEFINED: UInt8 = 1 << 6
    comptime ARRAY_OF_TABLES: UInt8 = 1 << 7


@fieldwise_init
struct Node(Copyable, Movable, TrivialRegisterPassable):
    var kind: UInt8
    var flags: UInt8
    var key_flags: UInt8
    var _pad: UInt8
    var start: UInt32
    var len: UInt32
    var key_start: UInt32
    var key_len: UInt32
    var first_child: UInt32
    var last_child: UInt32
    var next_sibling: UInt32

    @always_inline
    def __init__(
        out self,
        kind: UInt8 = Kind.Empty,
        flags: UInt8 = 0,
        key_flags: UInt8 = 0,
        start: UInt32 = 0,
        len: UInt32 = 0,
        key_start: UInt32 = 0,
        key_len: UInt32 = 0,
        first_child: UInt32 = NO_NODE,
        last_child: UInt32 = NO_NODE,
        next_sibling: UInt32 = NO_NODE,
    ):
        self.kind = kind
        self.flags = flags
        self.key_flags = key_flags
        self._pad = 0
        self.start = start
        self.len = len
        self.key_start = key_start
        self.key_len = key_len
        self.first_child = first_child
        self.last_child = last_child
        self.next_sibling = next_sibling

    @always_inline
    def is_table(self) -> Bool:
        return self.kind == Kind.Table

    @always_inline
    def is_array(self) -> Bool:
        return self.kind == Kind.Array

    @always_inline
    def has_flag(self, flag: UInt8) -> Bool:
        return (self.flags & flag) != 0

    @always_inline
    def set_flag(mut self, flag: UInt8):
        self.flags |= flag

    @always_inline
    def clear_flag(mut self, flag: UInt8):
        self.flags &= ~flag


struct KeySeg(Copyable, Movable, TrivialRegisterPassable):
    var start: UInt32
    var len: UInt32
    var has_escape: Bool

    @always_inline
    def __init__(
        out self, start: UInt32 = 0, len: UInt32 = 0, has_escape: Bool = False
    ):
        self.start = start
        self.len = len
        self.has_escape = has_escape
