"""Backing store for `TomlDocument` and non-allocating arena writer."""

from std.collections import List
from std.memory import Pointer, unsafe_memcpy
from ..tape.key_index import KeyIndex
from .tempo import DateTime


struct _Store(Movable):
    """Shared backing store for `TomlDocument`.

    Lazy modes (`Mode.Strict`, `Mode.Trusted`) use `key_index` only.
    `Mode.Eager` also populates `arena` (decoded strings/keys), `array_slots`
    (O(1) array indexing), and `temporals` (decoded `Time`/`DateTime` values).
    """

    var key_index: KeyIndex
    var arena: List[Byte]
    var array_slots: List[UInt32]
    var temporals: List[DateTime]

    @always_inline
    def __init__(
        out self,
        var key_index: KeyIndex,
        var array_slots: List[UInt32] = List[UInt32](),
    ):
        self.key_index = key_index^
        self.arena = List[Byte]()
        self.array_slots = array_slots^
        self.temporals = List[DateTime]()

    @always_inline
    def __init__(
        out self,
        var key_index: KeyIndex,
        var arena: List[Byte],
        var array_slots: List[UInt32],
        var temporals: List[DateTime],
    ):
        self.key_index = key_index^
        self.arena = arena^
        self.array_slots = array_slots^
        self.temporals = temporals^


struct _ArenaWriter[origin: MutOrigin](Writer):
    """Non-allocating writer that copies decoded UTF-8 bytes into an arena."""

    var ptr: Pointer[Byte, Self.origin]
    var pos: Int

    @always_inline
    def __init__(out self, ptr: Pointer[Byte, Self.origin]):
        self.ptr = ptr
        self.pos = 0

    @always_inline
    def write_string(mut self, string: StringSpan):
        var sb = string.as_bytes()
        var n = len(sb)
        if n > 0:
            unsafe_memcpy(
                dest=self.ptr.unsafe_offset(self.pos),
                src=sb.unsafe_ptr(),
                count=n,
            )
            self.pos += n
