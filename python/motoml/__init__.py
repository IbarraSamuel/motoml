"""Fast, spec-compliant TOML 1.1 parser, lazy view, and serializer backed by Mojo."""

from __future__ import annotations

import os
import re
from collections.abc import (
    Callable,
    Iterable,
    Iterator,
    Mapping,
    Sequence,
)
from typing import IO, Any, Literal, overload

from . import _motoml

type ParseMode = Literal["strict", "trusted"]

_LINE_COL_RE = re.compile(r"\b(\d+):(\d+)\b")


class TOMLDecodeError(ValueError):
    """Exception raised when a TOML 1.1 document fails to parse or validate.

    Subclasses `ValueError` for drop-in compatibility with stdlib `tomllib.TOMLDecodeError`.
    """

    msg: str
    doc: str | None
    pos: int | None
    lineno: int | None
    colno: int | None

    def __init__(
        self,
        msg: str = "",
        doc: str | None = None,
        pos: int | None = None,
    ) -> None:
        self.msg = msg
        self.doc = doc
        self.pos = pos
        lineno: int | None = None
        colno: int | None = None
        if doc is not None and pos is not None:
            lineno = doc.count("\n", 0, pos) + 1
            last_nl = doc.rfind("\n", 0, pos)
            colno = pos - last_nl if last_nl >= 0 else pos + 1
        else:
            match = _LINE_COL_RE.search(msg)
            if match is not None:
                lineno = int(match.group(1))
                colno = int(match.group(2))
        self.lineno = lineno
        self.colno = colno
        super().__init__(msg)


_motoml._set_decode_error_type(TOMLDecodeError)


# --- Lazy native view & document wrappers ---


class TomlView:
    """Lazy view over a node inside a native Mojo `TomlDocument`.

    Table nodes behave like read-only `Mapping`s (`doc["k"]`, `"k" in doc`, `len(doc)`,
    `.keys()`, `.items()`, `.values()`, `.get()`). Array nodes behave like read-only
    `Sequence`s (`arr[i]`, `arr[-1]`, `arr[1:3]`, `len(arr)`, iteration).

    Indexing into a container returns a nested `TomlView` for tables/arrays and a native
    Python value (`str`, `int`, `float`, `bool`, `date`, `time`, `datetime`) for scalars.
    """

    __slots__ = ("_doc", "_node_idx")

    _doc: _motoml.NativeDocument
    _node_idx: int

    def __init__(self, doc: _motoml.NativeDocument, node_idx: int) -> None:
        self._doc = doc
        self._node_idx = node_idx

    @property
    def kind(self) -> str:
        """TOML value kind (`table`, `array`, `string`, `integer`, `float`, `boolean`, `date`, `time`, `datetime`)."""
        return self._doc.node_kind(self._node_idx)

    @property
    def value(self) -> Any:
        """Materialize this node (scalar or container subtree) into native Python objects."""
        return self._doc.node_to_py(self._node_idx)

    def to_py(self) -> Any:
        """Materialize this node (scalar or container subtree) into native Python objects."""
        return self._doc.node_to_py(self._node_idx)

    def to_dict(self) -> dict[str, Any]:
        """Materialize a table view into a plain Python `dict`."""
        if self.kind != "table":
            msg = f"Expected TOML table, got {self.kind!r}"
            raise TypeError(msg)
        return self._doc.node_to_py(self._node_idx)

    def to_list(self) -> list[Any]:
        """Materialize an array view into a plain Python `list`."""
        if self.kind != "array":
            msg = f"Expected TOML array, got {self.kind!r}"
            raise TypeError(msg)
        return self._doc.node_to_py(self._node_idx)

    def to_json(self) -> str:
        """Serialize this node subtree directly to `toml-test` tagged JSON in Mojo."""
        return self._doc.node_to_json(self._node_idx)

    def _wrap_child(self, child_idx: int) -> Any:
        child_kind = self._doc.node_kind(child_idx)
        if child_kind in ("table", "array"):
            return TomlView(self._doc, child_idx)
        return self._doc.node_to_py(child_idx)

    def view(self, key_or_index: str | int) -> TomlView:
        """Return a `TomlView` for a child node even if it is a scalar."""
        if isinstance(key_or_index, str):
            child_idx = self._doc.table_get_idx(self._node_idx, key_or_index)
            if child_idx < 0:
                raise KeyError(key_or_index)
            return TomlView(self._doc, child_idx)
        if isinstance(key_or_index, int) and not isinstance(key_or_index, bool):
            child_idx = self._doc.array_get_idx(self._node_idx, key_or_index)
            return TomlView(self._doc, child_idx)
        msg = f"Invalid TOML index type: {type(key_or_index).__name__}"
        raise TypeError(msg)

    @overload
    def __getitem__(self, key: str) -> Any: ...
    @overload
    def __getitem__(self, key: int) -> Any: ...
    @overload
    def __getitem__(self, key: slice) -> list[Any]: ...

    def __getitem__(self, key: str | int | slice) -> Any:
        if isinstance(key, str):
            child_idx = self._doc.table_get_idx(self._node_idx, key)
            if child_idx < 0:
                raise KeyError(key)
            return self._wrap_child(child_idx)
        if isinstance(key, slice):
            n = len(self)
            return [
                self._wrap_child(self._doc.array_get_idx(self._node_idx, i))
                for i in range(*key.indices(n))
            ]
        if isinstance(key, int) and not isinstance(key, bool):
            child_idx = self._doc.array_get_idx(self._node_idx, key)
            return self._wrap_child(child_idx)
        msg = f"Invalid TOML index type: {type(key).__name__}"
        raise TypeError(msg)

    def get(self, key: str, default: Any = None) -> Any:
        """Look up `key` in a table view, returning `default` if absent."""
        child_idx = self._doc.table_get_idx(self._node_idx, key)
        if child_idx < 0:
            return default
        return self._wrap_child(child_idx)

    def __contains__(self, item: object) -> bool:
        k = self.kind
        if k == "table":
            if not isinstance(item, str):
                return False
            return self._doc.table_get_idx(self._node_idx, item) >= 0
        if k == "array":
            return any(elem == item for elem in self)
        msg = f"argument of type 'TomlView({k})' is not iterable"
        raise TypeError(msg)

    def __len__(self) -> int:
        return self._doc.node_len(self._node_idx)

    def __iter__(self) -> Iterator[Any]:
        k = self.kind
        if k == "table":
            return iter(self._doc.table_keys(self._node_idx))
        if k == "array":
            n = self._doc.node_len(self._node_idx)
            return (
                self._wrap_child(self._doc.array_get_idx(self._node_idx, i))
                for i in range(n)
            )
        msg = f"'TomlView({k})' object is not iterable"
        raise TypeError(msg)

    def keys(self) -> list[str]:
        """Return table keys in document order."""
        return self._doc.table_keys(self._node_idx)

    def values(self) -> list[Any]:
        """Return table values in document order (nested containers stay lazy `TomlView`s)."""
        return [
            self._wrap_child(self._doc.table_get_idx(self._node_idx, k))
            for k in self._doc.table_keys(self._node_idx)
        ]

    def items(self) -> list[tuple[str, Any]]:
        """Return `(key, value)` pairs in document order (nested containers stay lazy `TomlView`s)."""
        return [
            (k, self._wrap_child(self._doc.table_get_idx(self._node_idx, k)))
            for k in self._doc.table_keys(self._node_idx)
        ]

    def __eq__(self, other: object) -> bool:
        if isinstance(other, TomlView):
            return self.to_py() == other.to_py()
        if isinstance(other, (Mapping, Sequence)) and not isinstance(
            other, (str, bytes, bytearray)
        ):
            return self.to_py() == other
        return self.to_py() == other

    def __repr__(self) -> str:
        k = self.kind
        if k in ("table", "array"):
            return f"TomlView(kind={k!r}, len={len(self)})"
        return f"TomlView(kind={k!r}, value={self.to_py()!r})"


class TomlDocument(TomlView):
    """Owning lazy TOML 1.1 document backed by Mojo's materialized `Mode.Eager` arena."""

    __slots__ = ()

    def __init__(self, doc: _motoml.NativeDocument) -> None:
        super().__init__(doc, 0)

    def __repr__(self) -> str:
        return f"TomlDocument(keys={len(self)})"


# --- PEP 680 `tomllib`-compatible & fast file/validation/JSON APIs ---


def loads(
    s: str | bytes | bytearray,
    /,
    *,
    parse_float: Callable[[str], Any] = float,
    mode: ParseMode = "strict",
) -> dict[str, Any]:
    """Parse a TOML 1.1 string or UTF-8 bytes into a Python `dict`.

    Drop-in compatible with `tomllib.loads` while also accepting UTF-8 `bytes`/`bytearray`
    and an optional `mode="trusted"` fast path for trusted inputs.
    """
    pf = None if parse_float is float else parse_float
    return _motoml.loads(s, pf, mode)


def load(
    fp: IO[bytes] | IO[str],
    /,
    *,
    parse_float: Callable[[str], Any] = float,
    mode: ParseMode = "strict",
) -> dict[str, Any]:
    """Parse a TOML 1.1 document from a readable binary or text file object."""
    raw = fp.read()
    if not isinstance(raw, (str, bytes, bytearray)):
        msg = "File object .read() must return bytes or str"
        raise TypeError(msg)
    return loads(raw, parse_float=parse_float, mode=mode)


def load_file(
    path: str | os.PathLike[str],
    /,
    *,
    parse_float: Callable[[str], Any] = float,
    mode: ParseMode = "strict",
) -> dict[str, Any]:
    """Memory-map and parse a TOML 1.1 file directly in Mojo into a Python `dict`."""
    pf = None if parse_float is float else parse_float
    return _motoml.load_file(os.fspath(path), pf, mode)


def parse(s: str | bytes | bytearray, /) -> TomlDocument:
    """Parse TOML 1.1 input into a lazy native `TomlDocument` with O(1) lookups."""
    return TomlDocument(_motoml.parse(s))


def parse_file(path: str | os.PathLike[str], /) -> TomlDocument:
    """Memory-map and parse a TOML 1.1 file into a lazy native `TomlDocument`."""
    return TomlDocument(_motoml.parse_file(os.fspath(path)))


def validate(
    s: str | bytes | bytearray, /, *, mode: ParseMode = "strict"
) -> None:
    """Validate TOML 1.1 input in Mojo with the GIL released; raises `TOMLDecodeError` on error."""
    _motoml.validate(s, mode)


def to_tagged_json(
    s: str | bytes | bytearray, /, *, mode: ParseMode = "strict"
) -> str:
    """Parse TOML 1.1 input and stream `toml-test` tagged JSON directly from Mojo."""
    return _motoml.to_tagged_json(s, mode)


def dumps(obj: Mapping[str, Any], /) -> str:
    """Serialize a Python `Mapping` into a spec-compliant TOML 1.1 string."""
    return _motoml.dumps(obj)


def dump(obj: Mapping[str, Any], fp: IO[bytes] | IO[str], /) -> None:
    """Serialize a Python `Mapping` as TOML 1.1 and write it to `fp`."""
    text = dumps(obj)
    try:
        fp.write(text)  # type: ignore[arg-type]
    except TypeError:
        fp.write(text.encode("utf-8"))  # type: ignore[arg-type]


# --- Optional MAX GPU acceleration ---


def has_gpu() -> bool:
    """Return `True` if `motoml` was built with MAX GPU support and an accelerator is available."""
    return bool(_motoml.has_gpu())


class GpuTomlParser:
    """Reusable GPU-accelerated TOML 1.1 parser backed by MAX (`motoml[max]`)."""

    __slots__ = ("_native",)

    _native: Any

    def __init__(
        self,
        initial_capacity_bytes: int = 2 * 1024 * 1024,
        min_gpu_bytes: int = 512 * 1024,
    ) -> None:
        native_cls = getattr(_motoml, "NativeGpuParser", None)
        if native_cls is None:
            msg = (
                "motoml was built without MAX GPU support; "
                "reinstall with the 'max' extra (e.g. `pip install 'motoml[max]'`)."
            )
            raise RuntimeError(msg)
        self._native = native_cls(initial_capacity_bytes, min_gpu_bytes)

    @property
    def has_unified_memory(self) -> bool:
        """Return `True` when running on a unified-memory GPU (e.g. Apple Silicon Metal)."""
        return bool(self._native.has_unified_memory())

    def warmup(self, *, strict: bool = True) -> None:
        """Compile and warm up GPU Stage-1 kernels."""
        self._native.warmup(strict)

    def parse(
        self,
        s: str | bytes | bytearray,
        /,
        *,
        force_gpu: bool = False,
        gpu_materialize: bool = False,
    ) -> TomlDocument:
        """Parse TOML input on GPU into a lazy `TomlDocument`."""
        return TomlDocument(self._native.parse(s, force_gpu, gpu_materialize))

    def parse_file(
        self,
        path: str | os.PathLike[str],
        /,
        *,
        force_gpu: bool = False,
    ) -> TomlDocument:
        """Memory-map and parse a TOML file on GPU into a lazy `TomlDocument`."""
        return TomlDocument(
            self._native.parse_file(os.fspath(path), force_gpu)
        )

    def loads(
        self,
        s: str | bytes | bytearray,
        /,
        *,
        force_gpu: bool = False,
    ) -> dict[str, Any]:
        """Parse TOML input on GPU directly into a Python `dict`."""
        return self._native.loads(s, force_gpu)

    def load_file(
        self,
        path: str | os.PathLike[str],
        /,
        *,
        force_gpu: bool = False,
    ) -> dict[str, Any]:
        """Memory-map and parse a TOML file on GPU directly into a Python `dict`."""
        return self._native.load_file(os.fspath(path), force_gpu)

    def parse_batch(
        self,
        docs: Iterable[str | bytes | bytearray],
        /,
        *,
        force_gpu: bool = True,
    ) -> list[TomlDocument]:
        """Parse a batch of independent TOML documents in a single GPU Stage-1 launch."""
        native_docs = self._native.parse_batch(docs, force_gpu)
        return [TomlDocument(d) for d in native_docs]

    def to_tagged_json(
        self,
        s: str | bytes | bytearray,
        /,
        *,
        force_gpu: bool = True,
    ) -> str:
        """Parse TOML input on GPU and stream `toml-test` tagged JSON."""
        return self._native.to_tagged_json(s, force_gpu)


__all__ = [
    "GpuTomlParser",
    "ParseMode",
    "TOMLDecodeError",
    "TomlDocument",
    "TomlView",
    "dump",
    "dumps",
    "has_gpu",
    "load",
    "load_file",
    "loads",
    "parse",
    "parse_file",
    "to_tagged_json",
    "validate",
]
