"""Internal struct, tuple, array, union, variant, and cold-path error helpers."""

from std.builtin._enum import __Enum, __Union, __UnionStorage
from std.builtin.enum_like import EnumLike
from std.builtin.rebind import downcast
from std.builtin.tuple import __TupleLike
from std.builtin.variadics import TypeList, _MLIR
from std.memory import ImmPointer, MaybeUninit, MutPointer, Pointer
from std.utils import Variant
from ..mode import Mode
from ..tape.node import NO_NODE, Node, NodeKind
from .attr import (
    _effective_field_name,
    _field_alias_at,
    _field_alias_count,
    _field_is_flattened,
    _field_is_skipped,
)

comptime _TOML_ERR_PREFIX: StaticString = "TOML take error at "


comptime _IsMovableDeinitable[T: AnyType]: Bool = conforms_to(
    T, Movable & Deinitable
)


comptime _IsValidUnionCaseTuple[CaseTuple: AnyType]: Bool = (
    TypeList[
        Trait=AnyType,
        downcast[CaseTuple, __TupleLike].__element_types,
    ].all[_IsMovableDeinitable]() if conforms_to(
        CaseTuple, __TupleLike
    ) else False
)


comptime _IsValidTomlUnion[E: __Union]: Bool = (
    TypeList[Trait=AnyType, E._enum_case_types].length > 0
    and TypeList[Trait=AnyType, E._enum_case_types].all[
        _IsValidUnionCaseTuple
    ]()
)


comptime _IsFieldlessEnum[T: AnyType]: Bool = (
    downcast[T, __Enum]._enum_has_no_payloads if conforms_to(
        T, __Enum
    ) else False
)


comptime _DictEntryType[DictT: Iterable] = downcast[
    reflect[DictT.IteratorType[origin_of()]].field_at[0].T, Iterator
].Element


comptime _DictKeyType[DictT: Iterable] = reflect[
    _DictEntryType[DictT]
].field_at[1].T


comptime _DictValType[DictT: Iterable] = reflect[
    _DictEntryType[DictT]
].field_at[2].T


trait _VariantConstructible(Movable & Deinitable):
    """Internal trait enabling `Toml.take[T]()` for `OneOf` wrappers."""

    comptime _variant_types: _MLIR.KGENParamListType[AnyType]

    @staticmethod
    def _from_variant(
        var v: Variant[*TypeList[Trait=AnyType, Self._variant_types]()]
    ) -> Self:
        ...


def _static_len[A: Movable & Deinitable]() -> Int:
    """Return the fixed length of a `Sized` array/tuple type `A` at compile time.
    """
    comptime assert conforms_to(A, Sized)
    var tmp = MaybeUninit[A]()
    var n = len(tmp.unsafe_ptr()[])
    tmp^.unsafe_forget()
    return n


def _init_union_from_case_tuple[
    E: __Union & Movable & Deinitable,
    case_idx: Int,
](var case_tuple: TypeList[Trait=AnyType, E._enum_case_types]()[case_idx]) -> E:
    """Construct case `case_idx` of union `E` directly from its `CaseTuple` payload.
    """
    comptime Storage = __UnionStorage[E._enum_case_types]
    comptime CaseT = TypeList[Trait=AnyType, E._enum_case_types]()[case_idx]
    comptime assert conforms_to(CaseT, Movable)
    var out_uninit = MaybeUninit[E]()
    var storage_ptr = out_uninit.unsafe_ptr().unsafe_bitcast[Storage]()
    __get_address_as_uninit_lvalue(storage_ptr._mlir_value) = Storage(
        unsafe_uninitialized=()
    )
    storage_ptr[]._discriminant() = Storage._Discriminant(from_int=case_idx)
    storage_ptr[].payload_ptr[case_idx]().unsafe_write(case_tuple^)
    return out_uninit^.unsafe_assume_init()


def _destroy_partial_struct[
    T: Movable
](mut storage: MaybeUninit[T], initialized_fields: Int):
    """Destroy the first `initialized_fields` fields of a partially built struct.
    """
    comptime Tr = reflect[T]
    comptime field_types = Tr.field_types()
    comptime field_count = Tr.field_count()
    var struct_ptr = storage.unsafe_ptr()

    comptime for fi in reversed(range(field_count)):
        comptime TYPE = field_types[fi]
        comptime assert conforms_to(TYPE, Deinitable)
        if initialized_fields > fi:
            ref field = Tr.field_ref[fi](struct_ptr[])
            Pointer(to=field).unsafe_deinit_pointee()


def _destroy_partial_tuple[
    T: __TupleLike & Movable
](mut storage: MaybeUninit[T], initialized_elems: Int):
    """Destroy the first `initialized_elems` elements of a partially built `Tuple`.
    """
    comptime elts = TypeList[Trait=AnyType, T.__element_types]()
    var tup_ptr = storage.unsafe_ptr()

    comptime for i in reversed(range(elts.length)):
        comptime Elem = elts[i]
        comptime assert conforms_to(Elem, Deinitable)
        if initialized_elems > i:
            Pointer(to=tup_ptr[][i]).unsafe_deinit_pointee()


def _destroy_partial_array[
    Elem: Deinitable
](elem_ptr: MutPointer[Elem, _], initialized_elems: Int):
    """Destroy the first `initialized_elems` elements of a partially built `Array`.
    """
    for i in reversed(range(initialized_elems)):
        elem_ptr.unsafe_offset(i).unsafe_deinit_pointee()


def _struct_has_flattened_dict[T: AnyType]() -> Bool:
    comptime r = reflect[T]
    comptime types = r.field_types()
    var found = False
    comptime for fi in range(r.field_count()):
        comptime if not _field_is_skipped[T, fi]() and _field_is_flattened[
            T, fi
        ]():
            comptime if reflect[types[fi]].base_name() == "Dict":
                found = True
    return found


def _struct_claims_key_bytes[T: AnyType](k_bytes: Span[Byte, _]) -> Bool:
    """Return True if `k_bytes` matches any non-skipped direct or flattened-struct field/alias of `T`.
    """
    comptime r = reflect[T]
    comptime types = r.field_types()
    comptime count = r.field_count()

    comptime for fi in range(count):
        comptime if not _field_is_skipped[T, fi]():
            comptime FT = types[fi]
            comptime if _field_is_flattened[T, fi]():
                comptime if reflect[FT].base_name() != "Dict" and reflect[
                    FT
                ].is_struct():
                    if _struct_claims_key_bytes[FT](k_bytes):
                        return True
            else:
                comptime PRIMARY = _effective_field_name[T, fi]()
                var primary_s: StaticString = materialize[PRIMARY]()
                if k_bytes == primary_s.as_bytes():
                    return True
                comptime ALIAS_N = _field_alias_count[T, fi]()
                comptime for ai in range(ALIAS_N):
                    comptime ALIAS = _field_alias_at[T, fi, ai]()
                    var alias_s: StaticString = materialize[ALIAS]()
                    if k_bytes == alias_s.as_bytes():
                        return True
    return False


# --- Cold-path error formatting & hierarchical path composition ---


@inline(.never)
def _compute_node_line_col(
    doc_ptr: ImmPointer[Byte, _],
    nodes_ptr: ImmPointer[Node, _],
    node_idx: UInt32,
) -> Tuple[Int, Int]:
    """Compute 1-based `(line, col)` in `Mode.Strict` / `Mode.Trusted` from source bytes.
    """
    if node_idx == NO_NODE:
        return (0, 0)

    var curr = node_idx
    var byte_offset = -1
    var depth = 0
    while curr != NO_NODE and depth < 64:
        ref n = nodes_ptr[unsafe_offset=Int(curr)]
        if (
            n.kind != NodeKind.Table
            and n.kind != NodeKind.Array
            and n.kind != NodeKind.Empty
        ):
            byte_offset = Int(n.start)
            if n.kind == NodeKind.String and byte_offset > 0:
                var prev = doc_ptr[unsafe_offset=byte_offset - 1]
                if prev == Byte(ord('"')) or prev == Byte(ord("'")):
                    var q_steps = 0
                    while (
                        byte_offset > 0
                        and q_steps < 3
                        and doc_ptr[unsafe_offset=byte_offset - 1] == prev
                    ):
                        byte_offset -= 1
                        q_steps += 1
            break
        if n.key_start > 0 or n.key_len > 0:
            byte_offset = Int(n.key_start)
            break
        curr = n.first_child
        depth += 1

    if byte_offset < 0:
        return (1, 1)

    var line = 1
    var line_start = 0
    for i in range(byte_offset):
        if doc_ptr[unsafe_offset=i] == Byte(ord("\n")):
            line += 1
            line_start = i + 1
    return (line, (byte_offset - line_start) + 1)


@inline(.never)
def _format_leaf_error[
    mode: Mode
](
    doc_ptr: ImmPointer[Byte, _],
    nodes_ptr: ImmPointer[Node, _],
    node_idx: UInt32,
    msg: StringSpan,
) -> Error:
    """Format a cold-path reflection error with optional `line:col` location."""
    comptime if mode != Mode.Eager:
        var line, col = _compute_node_line_col(doc_ptr, nodes_ptr, node_idx)
        if line > 0:
            return Error(
                String(_TOML_ERR_PREFIX, "<root> (", line, ":", col, "): ", msg)
            )
    return Error(String(_TOML_ERR_PREFIX, "<root>: ", msg))


@inline(.never)
def _wrap_segment_error[
    mode: Mode
](
    seg: StringSpan,
    is_bracket: Bool,
    err: Error,
    doc_ptr: ImmPointer[Byte, _],
    nodes_ptr: ImmPointer[Node, _],
    node_idx: UInt32,
) -> Error:
    """Prepend a field/key or `[index]` segment onto an unwinding `take` error.
    """
    var raw = String(err)
    var pfx = StringSpan(_TOML_ERR_PREFIX)
    if raw.startswith(pfx):
        var rest = StringSpan(raw)[byte = pfx.byte_length() :]
        if rest.startswith("<root>"):
            var tail = rest[byte=6:]
            return Error(String(_TOML_ERR_PREFIX, seg, tail))
        if rest.startswith("["):
            return Error(String(_TOML_ERR_PREFIX, seg, rest))
        return Error(String(_TOML_ERR_PREFIX, seg, ".", rest))

    comptime if mode != Mode.Eager:
        var line, col = _compute_node_line_col(doc_ptr, nodes_ptr, node_idx)
        if line > 0:
            return Error(
                String(_TOML_ERR_PREFIX, seg, " (", line, ":", col, "): ", raw)
            )
    return Error(String(_TOML_ERR_PREFIX, seg, ": ", raw))


@inline(.never)
def _wrap_field_error[
    mode: Mode
](
    field_name: StaticString,
    err: Error,
    doc_ptr: ImmPointer[Byte, _],
    nodes_ptr: ImmPointer[Node, _],
    node_idx: UInt32,
) -> Error:
    return _wrap_segment_error[mode](
        StringSpan(field_name), False, err, doc_ptr, nodes_ptr, node_idx
    )


@inline(.never)
def _wrap_key_error[
    mode: Mode
](
    key: StringSpan,
    err: Error,
    doc_ptr: ImmPointer[Byte, _],
    nodes_ptr: ImmPointer[Node, _],
    node_idx: UInt32,
) -> Error:
    return _wrap_segment_error[mode](
        key, False, err, doc_ptr, nodes_ptr, node_idx
    )


@inline(.never)
def _wrap_index_error[
    mode: Mode
](
    index: Int,
    err: Error,
    doc_ptr: ImmPointer[Byte, _],
    nodes_ptr: ImmPointer[Node, _],
    node_idx: UInt32,
) -> Error:
    var bracket_seg = String("[", index, "]")
    return _wrap_segment_error[mode](
        StringSpan(bracket_seg), True, err, doc_ptr, nodes_ptr, node_idx
    )
