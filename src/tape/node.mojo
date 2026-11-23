"""32-byte tape node representation for flat-tape TOML parsing."""

from std.builtin.enum_like import EnumLike
from std.builtin.variadics import ParameterList, TypeList

comptime NO_NODE: UInt32 = 0xFFFFFFFF


@fieldwise_init
struct NodeKind(
    EnumLike, Equatable, ImplicitlyCopyable, TrivialRegisterPassable
):
    """Type tag identifying the TOML value stored on the tape."""

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

    comptime _enum_case_names = ParameterList.of[
        "Empty".value,
        "String".value,
        "Integer".value,
        "Float".value,
        "Boolean".value,
        "Date".value,
        "Time".value,
        "DateTime".value,
        "Array".value,
        "Table".value,
        "NaN".value,
        "Inf".value,
    ].values
    comptime _enum_case_types = TypeList.splat[12, Tuple[]].values

    @always_inline
    def _get_enum_discriminant(self) -> Int:
        return Int(self._value)

    @always_inline
    def _unsafe_get_enum_payload[
        id: Int
    ](ref self) -> ref[self] TypeList[Trait=AnyType, Self._enum_case_types]()[
        id
    ]:
        comptime assert False, "NodeKind has no payload"

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value


struct NodeFlags:
    """Bitmask attributes describing lexical or structural node properties.

    Disjoint `NodeKind`s reuse upper flag bits:
    - Bit 5: `DOTTED` (`Table`) / `SLOTTED` (`Array`)
    - Bit 6: `DEFINED` (`Table`) / `CONTIGUOUS` (`Array`)
    - Bit 7: `CANONICAL` (`Integer`, `Float`) / `ARRAY_OF_TABLES` (`Array`) / `INDEXED` (`Table`)
    """

    comptime HAS_ESCAPE: UInt8 = 1 << 0
    comptime LITERAL: UInt8 = 1 << 1
    comptime MULTILINE: UInt8 = 1 << 2
    comptime INLINE: UInt8 = 1 << 3
    comptime IMPLICIT: UInt8 = 1 << 4
    comptime DOTTED: UInt8 = 1 << 5
    comptime SLOTTED: UInt8 = 1 << 5
    comptime DEFINED: UInt8 = 1 << 6
    comptime CONTIGUOUS: UInt8 = 1 << 6
    comptime CANONICAL: UInt8 = 1 << 7
    comptime ARRAY_OF_TABLES: UInt8 = 1 << 7
    comptime INDEXED: UInt8 = 1 << 7


struct Node(Copyable, Movable, TrivialRegisterPassable):
    """Contiguous 32-byte tape node representing a parsed TOML value or container.

    Nodes form an intrusive tree over the tape via `first_child`, `last_child`,
    and `next_sibling` indices. `key_tag` caches the first unescaped key byte
    for fast inline small-table filtering.
    """

    var kind: NodeKind
    var flags: UInt8
    var key_flags: UInt8
    var key_tag: UInt8
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
        kind: NodeKind = NodeKind.Empty,
        flags: UInt8 = 0,
        key_flags: UInt8 = 0,
        key_tag: UInt8 = 0,
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
        self.key_tag = key_tag
        self.start = start
        self.len = len
        self.key_start = key_start
        self.key_len = key_len
        self.first_child = first_child
        self.last_child = last_child
        self.next_sibling = next_sibling

    @always_inline
    def is_table(self) -> Bool:
        return self.kind == NodeKind.Table

    @always_inline
    def is_array(self) -> Bool:
        return self.kind == NodeKind.Array

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
    """Borrowed key segment with byte offset, length, first byte tag, and escape flag.
    """

    var start: UInt32
    var len: UInt32
    var first_byte: UInt8
    var has_escape: Bool

    @always_inline
    def __init__(
        out self,
        start: UInt32 = 0,
        len: UInt32 = 0,
        first_byte: UInt8 = 0,
        has_escape: Bool = False,
    ):
        self.start = start
        self.len = len
        self.first_byte = first_byte
        self.has_escape = has_escape
