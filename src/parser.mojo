"""Public TOML parsing entry points.

Single parser pipeline (`_parse_tape`) backing all five `Mode`s:
- `Mode.Strict` (default), `Mode.Lexical`, `Mode.Structure`, `Mode.Trusted`:
  zero-copy lazy views borrowing the source `StringSpan` or mapped file.
- `Mode.Eager`: parses with `Strict` validation, then materializes decoded
  strings, keys, scalars, arrays, and temporals into an owned
  `TomlDocument[Mode.Eager]` with no lifetime dependency on the source buffer.
"""

from std.builtin.variadics import TypeList, _MLIR
from std.collections import Optional, Span
from std.utils import Variant
from .lazy.key_index import KeyIndex
from .lazy.node import Node
from .lazy.reader import _parse_tape
from .lazy.validation import Validation
from .mmap_file import MappedFile
from .mode import Mode, _Mode, _validation_of
from .result import Result
from .types.toml import (
    Toml,
    TomlDocument,
    TomlIter,
    TomlItemIter,
    TomlKeyIter,
    _Store,
    _materialize,
)


struct TomlFile[mode_id: Int, //, mode: _Mode[mode_id] = Mode.Strict](
    Movable, Sized, Writable
):
    """Owning handle for a memory-mapped TOML file and its parsed document.

    `doc` is declared before `_file` so the document view/tape always drops
    before the memory mapping is unmapped.
    """

    var doc: TomlDocument[Self.mode, ImmUntrackedOrigin]
    var _file: Optional[MappedFile]

    def __init__(
        out self,
        var doc: TomlDocument[Self.mode, ImmUntrackedOrigin],
        var file: Optional[MappedFile],
    ):
        self.doc = doc^
        self._file = file^

    @always_inline
    def root(ref self) -> Toml[ImmOrigin(origin_of(self)), Self.mode]:
        """Return the root `Toml` table view bound to this `TomlFile`."""
        var doc_p: Pointer[Byte, ImmOrigin(origin_of(self))]
        comptime if Self.mode_id == 0:
            doc_p = (
                self.doc.store.arena.unsafe_ptr()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmOrigin(origin_of(self))]()
            )
        else:
            doc_p = self.doc.data.unsafe_ptr().unsafe_origin_cast[
                ImmOrigin(origin_of(self))
            ]()
        return Toml[ImmOrigin(origin_of(self)), Self.mode](
            doc_p,
            Pointer(to=self.doc.nodes[0])
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            Pointer(to=self.doc.store)
            .unsafe_mut_cast[False]()
            .unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            self.doc.root_idx,
        )

    @always_inline
    def __getitem__(
        ref self, key: StringSpan
    ) -> Toml[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root()[key]

    @always_inline
    def get(
        ref self, key: StringSpan
    ) -> Optional[Toml[ImmOrigin(origin_of(self)), Self.mode]]:
        return self.root().get(key)

    @always_inline
    def __contains__(ref self, key: StringSpan) -> Bool:
        return key in self.root()

    @always_inline
    def __len__(self) -> Int:
        return len(self.doc)

    @always_inline
    def __iter__(ref self) -> TomlIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().__iter__()

    @always_inline
    def items(ref self) -> TomlItemIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().items()

    @always_inline
    def keys(ref self) -> TomlKeyIter[ImmOrigin(origin_of(self)), Self.mode]:
        return self.root().keys()

    @always_inline
    def take[T: Movable & Deinitable](ref self) raises -> T:
        return self.root().take[T]()

    @always_inline
    def take[
        *Ts: Movable & Deinitable
    ](ref self) raises -> Variant[*Ts] where Ts.length > 1:
        return self.root().take[*Ts]()

    @always_inline
    def take[
        Trait: type_of(AnyType),
        values: _MLIR.KGENParamListType[Trait],
        //,
        ts: TypeList[Trait=Trait, values],
    ](ref self) raises -> Variant[*ts] where ts.length > 0:
        return self.root().take[ts]()

    def to_json[W: Writer](ref self, mut w: W) raises:
        self.root().to_json(w)

    def write_to(ref self, mut w: Some[Writer]):
        self.root().write_to(w)


def parse_toml[
    mode_id: Int,
    //,
    mode: _Mode[mode_id] = Mode.Strict,
](
    data: StringSpan,
) -> Result[TomlDocument[mode, data.origin]] where (
    mode_id != 0
):
    """Parse TOML text into a lazy `TomlDocument` borrowing `data`.

    Defaults to `Mode.Strict` for full TOML 1.1 specification conformance.
    """
    comptime V = _validation_of[mode_id]()
    var bytes = data.as_bytes()
    var tape_res = _parse_tape[V](bytes)
    if case .Err = tape_res:
        return .Err(tape_res^.unsafe_take_error())
    var tape = tape_res^.unsafe_take_value()
    var nodes = List[Node]()
    var key_index = KeyIndex()
    tape^.take_into(nodes, key_index)
    return .Ok(
        TomlDocument[mode, data.origin](bytes, nodes^, _Store(key_index^), 0)
    )


def parse_toml[
    mode_id: Int,
    //,
    mode: _Mode[mode_id],
](
    data: StringSpan,
) -> Result[
    TomlDocument[Mode.Eager, ImmUntrackedOrigin]
] where (mode_id == 0):
    """Parse TOML text with `Mode.Strict` and materialize an owned `Mode.Eager` document.

    The returned document owns all decoded keys, strings, scalars, arrays,
    and temporals and has no lifetime dependency on `data`.
    """
    var bytes = data.as_bytes()
    var tape_res = _parse_tape[Validation.Strict](bytes)
    if case .Err = tape_res:
        return .Err(tape_res^.unsafe_take_error())
    var tape = tape_res^.unsafe_take_value()
    return .Ok(_materialize(bytes, tape^))


def parse_toml_file[
    mode_id: Int,
    //,
    mode: _Mode[mode_id] = Mode.Strict,
](path: StringSpan) raises -> TomlFile[mode] where mode_id != 0:
    """Parse a TOML file through a read-only memory mapping (lazy mode)."""
    var mapped_file = MappedFile(path)
    var raw_bytes = mapped_file.bytes()
    comptime V = _validation_of[mode_id]()
    var res = _parse_tape[V](raw_bytes)
    if case .Err = res:
        raise res^.unsafe_take_error()
    var tape = res^.unsafe_take_value()
    var nodes = List[Node]()
    var key_index = KeyIndex()
    tape^.take_into(nodes, key_index)
    var untracked_bytes = Span[Byte, ImmUntrackedOrigin](
        unsafe_ptr=raw_bytes.unsafe_ptr()
        .unsafe_mut_cast[False]()
        .unsafe_origin_cast[ImmUntrackedOrigin](),
        length=len(raw_bytes),
    )
    var doc = TomlDocument[mode, ImmUntrackedOrigin](
        untracked_bytes, nodes^, _Store(key_index^), 0
    )
    return TomlFile[mode](doc^, Optional(mapped_file^))


def parse_toml_file[
    mode_id: Int,
    //,
    mode: _Mode[mode_id],
](path: StringSpan) raises -> TomlFile[Mode.Eager] where mode_id == 0:
    """Parse a TOML file with `Mode.Strict` and materialize into an owned `Mode.Eager` document.
    """
    var mapped_file = MappedFile(path)
    var raw_bytes = mapped_file.bytes()
    var res = _parse_tape[Validation.Strict](raw_bytes)
    if case .Err = res:
        raise res^.unsafe_take_error()
    var doc = _materialize(raw_bytes, res^.unsafe_take_value())
    # Materialized eagerly; release the file mapping immediately.
    _ = mapped_file^
    return TomlFile[Mode.Eager](doc^, Optional[MappedFile](None))


def toml_to_tagged_json[
    mode_id: Int,
    //,
    mode: _Mode[mode_id] = Mode.Strict,
](content: StringSpan) raises -> String:
    """Parse TOML text and serialize it as toml-test tagged JSON."""
    var out = String()
    comptime if mode_id == 0:
        var doc = parse_toml[Mode.Eager](content).take()
        doc.to_json(out)
    else:
        var doc = parse_toml[mode](content).take()
        doc.to_json(out)
    return out
