"""Tape Node representation for zero-allocation TOML parsing.
"""

comptime NO_NODE: UInt32 = 0xFFFFFFFF


@fieldwise_init
struct Kind(Equatable, ImplicitlyCopyable, TrivialRegisterPassable):
    """Type tags identifying the AST node variant stored on the tape."""

    var _value: UInt8

    comptime Empty = Self(0)
    comptime String = Self(1)
    comptime Integer = Self(2)
    comptime Float = Self(3)
    comptime Boolean = Self(4)
    comptime Date = Self(5)
    comptime Time = Self(6)
    comptime DateTime = Self(7)
    comptime Array = Self(8)
    comptime Table = Self(9)
    comptime NaN = Self(10)
    comptime Inf = Self(11)

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value


struct NodeFlags:
    """Bitmask attributes describing node lexical or syntactic properties."""

    comptime HAS_ESCAPE: UInt8 = 1 << 0
    comptime CANONICAL: UInt8 = 1 << 7
    comptime LITERAL: UInt8 = 1 << 1
    comptime MULTILINE: UInt8 = 1 << 2
    comptime INLINE: UInt8 = 1 << 3
    comptime IMPLICIT: UInt8 = 1 << 4
    comptime DOTTED: UInt8 = 1 << 5
    comptime DEFINED: UInt8 = 1 << 6
    comptime ARRAY_OF_TABLES: UInt8 = 1 << 7


@fieldwise_init
struct Node(Copyable, Movable, TrivialRegisterPassable):
    """Contiguous 32-byte tape node representing a parsed TOML token or container.

    Nodes form an intrusive tree layout over the tape using `first_child`,
    `last_child`, and `next_sibling` indices, pointing directly into slices of
    the original document buffer without heap allocations.
    """

    var kind: Kind
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
        kind: Kind = Kind.Empty,
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
        """Initialize a tape node with type, flags, source byte offsets, and link indices.

        Args:
            kind: The token kind (`Kind.Table`, `Kind.Array`, `Kind.String`, etc.).
            flags: Value attribute bitmask (`NodeFlags`).
            key_flags: Key attribute bitmask (`NodeFlags.HAS_ESCAPE`, etc.).
            start: Start byte offset of the value in the document.
            len: Length in bytes of the value in the document.
            key_start: Start byte offset of the key in the document.
            key_len: Length in bytes of the key in the document.
            first_child: Tape index of the first child node (`NO_NODE` if none).
            last_child: Tape index of the last child node (`NO_NODE` if none).
            next_sibling: Tape index of the next sibling node (`NO_NODE` if none).
        """
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
        """Check whether this node represents a table."""
        return self.kind == Kind.Table

    @always_inline
    def is_array(self) -> Bool:
        """Check whether this node represents an array."""
        return self.kind == Kind.Array

    @always_inline
    def has_flag(self, flag: UInt8) -> Bool:
        """Check whether a specific `NodeFlags` bitmask is set on this node.

        Args:
            flag: Bitmask flag to check.

        Returns:
            `True` if the flag bit is set, `False` otherwise.
        """
        return (self.flags & flag) != 0

    @always_inline
    def set_flag(mut self, flag: UInt8):
        """Set a flag bitmask on this node.

        Args:
            flag: Bitmask flag to set.
        """
        self.flags |= flag

    @always_inline
    def clear_flag(mut self, flag: UInt8):
        """Clear a flag bitmask on this node.

        Args:
            flag: Bitmask flag to clear.
        """
        self.flags &= ~flag


struct KeySeg(Copyable, Movable, TrivialRegisterPassable):
    """A borrowed key segment describing start byte offset, length, precomputed hash, and escape status.
    """

    var start: UInt32
    var len: UInt32
    var hash: UInt32
    var has_escape: Bool

    @always_inline
    def __init__(
        out self,
        start: UInt32 = 0,
        len: UInt32 = 0,
        hash: UInt32 = 0,
        has_escape: Bool = False,
    ):
        """Initialize a key segment pointing to an offset in the document buffer.

        Args:
            start: Start byte offset in the document buffer.
            len: Length of the key segment in bytes.
            hash: Precomputed 32-bit FNV-1a hash of the logical key bytes.
            has_escape: Whether the segment contains escape sequences.
        """
        self.start = start
        self.len = len
        self.hash = hash
        self.has_escape = has_escape
