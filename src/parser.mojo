"""Public TOML 1.1 parsing entry points.

Single flat-tape parser (`_parse_tape`) backing all three `Mode`s:
- `Mode.Strict` (default): zero-copy lazy view with full TOML 1.1 validation.
- `Mode.Eager`: strict validation + owned materialized `TomlDocument[Mode.Eager]`.
- `Mode.Trusted`: zero-copy lazy view skipping validation for maximum speed.

`parse_toml` / `parse_toml_file` raise on invalid TOML; `try_parse_toml`
returns a `Result` (useful for compile-time parsing or branch-based handling).
"""

from std.builtin.variadics import TypeList, _MLIR
from std.collections import Optional, Span
from std.utils import Variant
from .mmap_file import MappedFile
from .mode import Mode
from .result import Result
from .tape.reader import _parse_tape
from .types.document import TomlDocument, _materialize
from .types.store import _Store
from .types.view import Toml, TomlItemIter, TomlIter, TomlKeyIter


struct TomlFile[mode: Mode = Mode.Strict](Movable, Sized, Writable):
    """Owning handle for a memory-mapped TOML file and its parsed document.

    `doc` is declared before `_file` so the document tape always drops before
    the memory mapping is unmapped.
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
        var r = self.doc.root()
        return Toml[ImmOrigin(origin_of(self)), Self.mode](
            r.doc_ptr.unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            r.nodes_ptr.unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            r.store_ptr.unsafe_origin_cast[ImmOrigin(origin_of(self))](),
            r.node_idx,
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


def try_parse_toml[
    mode: Mode = Mode.Strict,
](
    data: StringSpan,
) -> Result[TomlDocument[mode, data.origin]] where (
    mode != Mode.Eager
):
    """Parse TOML text into a lazy `TomlDocument` borrowing `data`, returning `Result`.
    """
    comptime strict = mode != Mode.Trusted
    var bytes = data.as_bytes()
    var tape_res = _parse_tape[strict](bytes)
    if case .Err(_) = tape_res:
        return .Err(tape_res^.unsafe_take_error())
    var nodes, key_index = tape_res^.unsafe_take_value().into_parts()
    return .Ok(
        TomlDocument[mode, data.origin](bytes, nodes^, _Store(key_index^), 0)
    )


def try_parse_toml[
    mode: Mode,
](
    data: StringSpan,
) -> Result[TomlDocument[Mode.Eager, ImmUntrackedOrigin]] where (
    mode == Mode.Eager
):
    """Parse TOML text with `Strict` validation and materialize an owned `Mode.Eager` document.
    """
    var bytes = data.as_bytes()
    var tape_res = _parse_tape[True](bytes)
    if case .Err(_) = tape_res:
        return .Err(tape_res^.unsafe_take_error())
    return .Ok(_materialize(bytes, tape_res^.unsafe_take_value()))


# --- Raising API (`parse_toml`, `parse_toml_file`, `toml_to_tagged_json`) ---


@always_inline
def parse_toml[
    mode: Mode = Mode.Strict,
](
    data: StringSpan,
) raises -> TomlDocument[mode, data.origin] where (
    mode != Mode.Eager
):
    """Parse TOML text into a lazy `TomlDocument` borrowing `data`, raising on error.
    """
    return try_parse_toml[mode](data).take()


@always_inline
def parse_toml[
    mode: Mode,
](
    data: StringSpan,
) raises -> TomlDocument[Mode.Eager, ImmUntrackedOrigin] where (
    mode == Mode.Eager
):
    """Parse TOML text strictly and materialize an owned `Mode.Eager` document, raising on error.
    """
    return try_parse_toml[Mode.Eager](data).take()


def parse_toml_file[
    mode: Mode = Mode.Strict,
](path: StringSpan) raises -> TomlFile[mode]:
    """Parse a TOML file through a read-only memory mapping."""
    var mapped_file = MappedFile(path)
    var raw_bytes = mapped_file.bytes()
    comptime if case .Eager = mode:
        var res = _parse_tape[True](raw_bytes)
        if case .Err(_) = res:
            raise res^.unsafe_take_error()
        var doc = _materialize(raw_bytes, res^.unsafe_take_value())
        _ = mapped_file^
        return TomlFile[mode](
            rebind_var[TomlDocument[mode, ImmUntrackedOrigin]](doc^),
            Optional[MappedFile](None),
        )
    else:
        comptime strict = mode != Mode.Trusted
        var res = _parse_tape[strict](raw_bytes)
        if case .Err(_) = res:
            raise res^.unsafe_take_error()
        var nodes, key_index = res^.unsafe_take_value().into_parts()
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


def toml_to_tagged_json[
    mode: Mode = Mode.Strict,
](content: StringSpan) raises -> String:
    """Parse TOML text and serialize it as `toml-test` tagged JSON."""
    var out = String()
    comptime if mode == Mode.Eager:
        var doc = parse_toml[Mode.Eager](content)
        doc.to_json(out)
    else:
        var doc = parse_toml[mode](content)
        doc.to_json(out)
    return out^
