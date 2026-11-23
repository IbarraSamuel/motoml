"""Shared CPython interoperability implementation for `motoml`."""

from std.collections import Array, List, Optional, Span
from std.ffi import _Global, c_char, c_int, c_long, c_long_long
from std.memory import Pointer, bitcast, unsafe_memcpy
from std.python import Python, PythonObject
from std.python._cpython import GILReleased, Py_ssize_t, PyObjectPtr
from std.python.bindings import PythonModuleBuilder
from motoml import (
    Date,
    DateTime,
    Mode,
    Offset,
    Time,
    Toml,
    TomlDocument,
    parse_toml,
    parse_toml_file,
    toml_to_tagged_json,
)
from motoml.mmap_file import MappedFile
from motoml.tape.decode import (
    decode_bool,
    decode_bool_unchecked,
    decode_date,
    decode_date_unchecked,
    decode_datetime,
    decode_datetime_unchecked,
    decode_float,
    decode_float_unchecked,
    decode_int,
    decode_int_unchecked,
    decode_string,
    decode_string_unchecked,
    decode_time,
    decode_time_unchecked,
)
from motoml.tape.node import NO_NODE, Node, NodeFlags, NodeKind
from motoml.tape.reader import _parse_tape
from motoml.types.document import _materialize
from motoml.types.json import _JsonBufWriter
from motoml.types.ser import (
    _put_section_header,
    _put_toml_float,
    _put_toml_key,
    _put_toml_quoted_bytes,
)
from motoml.types.store import _Store
from motoml.types.tempo import (
    _format_date_buf,
    _format_datetime_buf,
    _format_time_buf,
)

comptime _MAX_SER_DEPTH: Int = 128

comptime _PyObjectIsInstanceFn = def(PyObjectPtr, PyObjectPtr) thin abi(
    "C"
) -> c_int
comptime _PyBytesAsStringFn = def(PyObjectPtr) thin abi("C") -> Optional[
    ImmPointer[Byte, ImmUntrackedOrigin]
]
comptime _PyBytesSizeFn = def(PyObjectPtr) thin abi("C") -> Py_ssize_t
comptime _PyByteArrayAsStringFn = def(PyObjectPtr) thin abi("C") -> Optional[
    ImmPointer[Byte, ImmUntrackedOrigin]
]
comptime _PyByteArraySizeFn = def(PyObjectPtr) thin abi("C") -> Py_ssize_t
comptime _PyLongAsLongLongOverflowFn = def(
    PyObjectPtr, MutPointer[c_int, MutUntrackedOrigin]
) thin abi("C") -> c_long_long
comptime _PyObjectCallOneArgFn = def(PyObjectPtr, PyObjectPtr) thin abi(
    "C"
) -> PyObjectPtr


struct _PyCache(Movable):
    """Cached CPython C-API function pointers and frequently used Python types.
    """

    var is_instance: _PyObjectIsInstanceFn
    var bytes_as_string: _PyBytesAsStringFn
    var bytes_size: _PyBytesSizeFn
    var bytearray_as_string: _PyByteArrayAsStringFn
    var bytearray_size: _PyByteArraySizeFn
    var long_as_ll_overflow: _PyLongAsLongLongOverflowFn
    var has_call_one_arg: Bool
    var call_one_arg: _PyObjectCallOneArgFn

    var initialized_types: Bool
    var str_type: PythonObject
    var bytes_type: PythonObject
    var bytearray_type: PythonObject
    var dict_type: PythonObject
    var list_type: PythonObject
    var tuple_type: PythonObject
    var mapping_abc: PythonObject
    var date_cls: PythonObject
    var time_cls: PythonObject
    var datetime_cls: PythonObject
    var timezone_cls: PythonObject
    var timedelta_cls: PythonObject
    var utc_tz: PythonObject
    var none_obj: PythonObject
    var decode_error_cls: PythonObject

    def __init__(out self):
        ref cpython = Python().cpython()
        var lib = cpython.lib.borrow()
        self.is_instance = lib.get_function[_PyObjectIsInstanceFn](
            "PyObject_IsInstance"
        )
        self.bytes_as_string = lib.get_function[_PyBytesAsStringFn](
            "PyBytes_AsString"
        )
        self.bytes_size = lib.get_function[_PyBytesSizeFn]("PyBytes_Size")
        self.bytearray_as_string = lib.get_function[_PyByteArrayAsStringFn](
            "PyByteArray_AsString"
        )
        self.bytearray_size = lib.get_function[_PyByteArraySizeFn](
            "PyByteArray_Size"
        )
        self.long_as_ll_overflow = lib.get_function[
            _PyLongAsLongLongOverflowFn
        ]("PyLong_AsLongLongAndOverflow")
        if cpython.lib.check_symbol("PyObject_CallOneArg"):
            self.has_call_one_arg = True
            self.call_one_arg = lib.get_function[_PyObjectCallOneArgFn](
                "PyObject_CallOneArg"
            )
        else:
            self.has_call_one_arg = False
            self.call_one_arg = _dummy_call_one_arg

        self.initialized_types = False
        self.str_type = PythonObject(None)
        self.bytes_type = PythonObject(None)
        self.bytearray_type = PythonObject(None)
        self.dict_type = PythonObject(None)
        self.list_type = PythonObject(None)
        self.tuple_type = PythonObject(None)
        self.mapping_abc = PythonObject(None)
        self.date_cls = PythonObject(None)
        self.time_cls = PythonObject(None)
        self.datetime_cls = PythonObject(None)
        self.timezone_cls = PythonObject(None)
        self.timedelta_cls = PythonObject(None)
        self.utc_tz = PythonObject(None)
        self.none_obj = PythonObject(None)
        self.decode_error_cls = PythonObject(None)

    def ensure_types(mut self) raises:
        if self.initialized_types:
            return
        var builtins = Python.import_module("builtins")
        var abc_mod = Python.import_module("collections.abc")
        var dt_mod = Python.import_module("datetime")

        self.str_type = builtins.str
        self.bytes_type = builtins.bytes
        self.bytearray_type = builtins.bytearray
        self.dict_type = builtins.dict
        self.list_type = builtins.list
        self.tuple_type = builtins.tuple
        self.mapping_abc = abc_mod.Mapping
        self.date_cls = dt_mod.date
        self.time_cls = dt_mod.time
        self.datetime_cls = dt_mod.datetime
        self.timezone_cls = dt_mod.timezone
        self.timedelta_cls = dt_mod.timedelta
        self.utc_tz = dt_mod.timezone.utc
        self.none_obj = Python.none()
        if self.decode_error_cls._obj_ptr == self.none_obj._obj_ptr:
            self.decode_error_cls = builtins.ValueError
        self.initialized_types = True


def _dummy_call_one_arg(a: PyObjectPtr, b: PyObjectPtr) abi("C") -> PyObjectPtr:
    return PyObjectPtr()


def _init_py_cache() -> _PyCache:
    return _PyCache()


comptime _PY_CACHE = _Global[
    StorageType=_PyCache,
    "MOTOML_PY_CAPI_CACHE",
    _init_py_cache,
]


def _get_cache() raises -> Pointer[_PyCache, MutUntrackedOrigin]:
    var cache = _PY_CACHE.get_or_create_ptr()
    cache[].ensure_types()
    return Pointer[_PyCache, MutUntrackedOrigin](unsafe_from_address=Int(cache))


# --- Python error helpers ---


def _raise_py_exc(exc_global: StaticString, msg: String) -> PythonObject:
    ref cpython = Python().cpython()
    var exc_type = cpython.get_error_global(exc_global)
    var msg_copy = msg
    cpython.PyErr_SetString(exc_type, msg_copy.as_c_string_span().ptr())
    return PythonObject(from_owned=PyObjectPtr())


def _raise_type_error(msg: String) -> PythonObject:
    return _raise_py_exc("PyExc_TypeError", msg)


def _raise_value_error(msg: String) -> PythonObject:
    return _raise_py_exc("PyExc_ValueError", msg)


def _raise_key_error(msg: String) -> PythonObject:
    return _raise_py_exc("PyExc_KeyError", msg)


def _raise_index_error(msg: String) -> PythonObject:
    return _raise_py_exc("PyExc_IndexError", msg)


def _raise_overflow_error(msg: String) -> PythonObject:
    return _raise_py_exc("PyExc_OverflowError", msg)


def _raise_os_error(msg: String) -> PythonObject:
    return _raise_py_exc("PyExc_OSError", msg)


def _raise_decode_error(msg: String) -> PythonObject:
    ref cpython = Python().cpython()
    try:
        var cache = _get_cache()
        var msg_copy = msg
        cpython.PyErr_SetString(
            cache[].decode_error_cls._obj_ptr,
            msg_copy.as_c_string_span().ptr(),
        )
        return PythonObject(from_owned=PyObjectPtr())
    except:
        return _raise_value_error(msg)


def _set_decode_error_type(exc_cls: PythonObject) raises -> PythonObject:
    var cache = _get_cache()
    cache[].decode_error_cls = exc_cls
    return PythonObject(None)


# --- Input buffer extraction ---


struct _InputBytes(Movable):
    """Borrowed or owned UTF-8 input bytes extracted from a Python `str`/`bytes`/`bytearray`.
    """

    var ptr: Optional[ImmPointer[Byte, ImmUntrackedOrigin]]
    var length: Int
    var owned: List[Byte]
    var ok: Bool

    def __init__(out self):
        self.ptr = None
        self.length = 0
        self.owned = List[Byte]()
        self.ok = False

    def as_span(ref self) -> Span[Byte, ImmUntrackedOrigin]:
        if len(self.owned) > 0:
            return Span[Byte, ImmUntrackedOrigin](
                unsafe_ptr=self.owned.unsafe_ptr()
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[ImmUntrackedOrigin](),
                length=len(self.owned),
            )
        if case .Some(p) = self.ptr:
            return Span[Byte, ImmUntrackedOrigin](
                unsafe_ptr=p, length=self.length
            )
        return Span[Byte, ImmUntrackedOrigin]()

    def as_string_span(ref self) -> StringSpan[ImmUntrackedOrigin]:
        return StringSpan(unsafe_from_utf8=self.as_span())


def _extract_input_bytes(
    obj: PythonObject,
) raises -> _InputBytes:
    """Extract UTF-8 bytes from a Python `str`, `bytes`, or `bytearray`."""
    ref cpython = Python().cpython()
    var cache = _get_cache()
    var out = _InputBytes()

    if cache[].is_instance(obj._obj_ptr, cache[].str_type._obj_ptr) > 0:
        var opt_span = cpython.PyUnicode_AsUTF8AndSize(obj._obj_ptr)
        if case .Some(span) = opt_span:
            var bytes = span.as_bytes()
            out.ptr = bytes.unsafe_ptr().unsafe_origin_cast[
                ImmUntrackedOrigin
            ]()
            out.length = len(bytes)
            out.ok = True
            return out^
        return out^

    if cache[].is_instance(obj._obj_ptr, cache[].bytes_type._obj_ptr) > 0:
        var sz = Int(cache[].bytes_size(obj._obj_ptr))
        if sz < 0:
            return out^
        var opt_ptr = cache[].bytes_as_string(obj._obj_ptr)
        if case .Some(p) = opt_ptr:
            out.ptr = p
            out.length = sz
            out.ok = True
            return out^
        if sz == 0:
            out.ok = True
            return out^
        return out^

    if cache[].is_instance(obj._obj_ptr, cache[].bytearray_type._obj_ptr) > 0:
        var sz = Int(cache[].bytearray_size(obj._obj_ptr))
        if sz < 0:
            return out^
        if sz > 0:
            var opt_ptr = cache[].bytearray_as_string(obj._obj_ptr)
            if case .Some(p) = opt_ptr:
                out.owned.reserve(sz)
                out.owned.resize(unsafe_uninit_length=sz)
                unsafe_memcpy(dest=out.owned.unsafe_ptr(), src=p, count=sz)
            else:
                return out^
        out.length = sz
        out.ok = True
        return out^

    _ = _raise_type_error("Expected str, bytes, or bytearray for TOML input")
    return out^


def _is_none(
    obj: PythonObject, cache: Pointer[_PyCache, MutUntrackedOrigin]
) -> Bool:
    return obj._obj_ptr == cache[].none_obj._obj_ptr


def _parse_mode_arg(mode_obj: PythonObject) raises -> Int:
    """Parse mode string: 0 = strict, 1 = trusted, -1 = invalid."""
    var cache = _get_cache()
    if _is_none(mode_obj, cache):
        return 0
    var s = String(py=mode_obj)
    if s == "strict":
        return 0
    if s == "trusted":
        return 1
    return -1


# --- Fast tape -> Python object conversion ---


def _py_str_from_span(span: Span[Byte, _]) raises -> PythonObject:
    ref cpython = Python().cpython()
    var ptr = cpython.PyUnicode_DecodeUTF8(StringSpan(unsafe_from_utf8=span))
    if not ptr:
        raise cpython.get_error()
    return PythonObject(from_owned=ptr)


def _date_to_py(
    d: Date, cache: Pointer[_PyCache, MutUntrackedOrigin]
) raises -> PythonObject:
    return cache[].date_cls(d.year, d.month, d.day)


def _time_to_py(
    t: Time, cache: Pointer[_PyCache, MutUntrackedOrigin]
) raises -> PythonObject:
    return cache[].time_cls(t.hour, t.minute, t.second, t.nanosecond // 1000)


def _datetime_to_py(
    dt: DateTime, cache: Pointer[_PyCache, MutUntrackedOrigin]
) raises -> PythonObject:
    var micro = dt.time.nanosecond // 1000
    if dt.is_local:
        return cache[].datetime_cls(
            dt.date.year,
            dt.date.month,
            dt.date.day,
            dt.time.hour,
            dt.time.minute,
            dt.time.second,
            micro,
        )
    var tz: PythonObject
    if dt.offset.hour == 0 and dt.offset.minute == 0:
        tz = cache[].utc_tz
    else:
        var total_min = dt.offset.hour * 60 + dt.offset.minute
        if not dt.offset.positive:
            total_min = -total_min
        var td = cache[].timedelta_cls(0, total_min * 60)
        tz = cache[].timezone_cls(td)
    return cache[].datetime_cls(
        dt.date.year,
        dt.date.month,
        dt.date.day,
        dt.time.hour,
        dt.time.minute,
        dt.time.second,
        micro,
        tz,
    )


def _key_to_py[
    mode: Mode
](ref node: Node, doc_ptr: ImmPointer[Byte, _],) raises -> PythonObject:
    var key_span = Span[Byte, ImmUntrackedOrigin](
        unsafe_ptr=doc_ptr.unsafe_offset(
            Int(node.key_start)
        ).unsafe_origin_cast[ImmUntrackedOrigin](),
        length=Int(node.key_len),
    )
    comptime if mode == Mode.Eager:
        return _py_str_from_span(key_span)
    else:
        if (node.key_flags & NodeFlags.HAS_ESCAPE) == 0:
            return _py_str_from_span(key_span)
        comptime if mode == Mode.Strict:
            var decoded = decode_string_unchecked(key_span, node.key_flags)
            return _py_str_from_span(decoded.as_bytes())
        else:
            var res = decode_string(key_span, node.key_flags)
            if case .Err(_) = res:
                raise Error(res^.unsafe_take_error())
            var decoded = res^.unsafe_take_value()
            return _py_str_from_span(decoded.as_bytes())


def _node_to_py[
    mode: Mode, has_parse_float: Bool
](
    node_idx: UInt32,
    doc_ptr: ImmPointer[Byte, _],
    nodes_ptr: ImmPointer[Node, _],
    store_ptr: ImmPointer[_Store, _],
    cache: Pointer[_PyCache, MutUntrackedOrigin],
    parse_float: PythonObject,
) raises -> PythonObject:
    ref cpython = Python().cpython()
    ref node = nodes_ptr[unsafe_offset=Int(node_idx)]

    match node.kind:
        case .Table:
            var d_ptr = cpython.PyDict_New()
            if not d_ptr:
                raise cpython.get_error()
            var d_obj = PythonObject(from_owned=d_ptr)
            var curr = node.first_child
            while curr != NO_NODE:
                ref child = nodes_ptr[unsafe_offset=Int(curr)]
                var k_obj = _key_to_py[mode](child, doc_ptr)
                var v_obj = _node_to_py[mode, has_parse_float](
                    curr, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
                )
                if (
                    cpython.PyDict_SetItem(
                        d_obj._obj_ptr, k_obj._obj_ptr, v_obj._obj_ptr
                    )
                    != 0
                ):
                    raise cpython.get_error()
                curr = child.next_sibling
            return d_obj^

        case .Array:
            var n = Int(node.len)
            var l_ptr = cpython.PyList_New(Py_ssize_t(n))
            if not l_ptr:
                raise cpython.get_error()
            var l_obj = PythonObject(from_owned=l_ptr)
            var curr = node.first_child
            var idx = 0
            while curr != NO_NODE:
                var v_obj = _node_to_py[mode, has_parse_float](
                    curr, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
                )
                if (
                    cpython.PyList_SetItem(
                        l_obj._obj_ptr, Py_ssize_t(idx), v_obj^.steal_data()
                    )
                    != 0
                ):
                    raise cpython.get_error()
                idx += 1
                curr = nodes_ptr[unsafe_offset=Int(curr)].next_sibling
            return l_obj^

        case .String:
            var raw = Span[Byte, ImmUntrackedOrigin](
                unsafe_ptr=doc_ptr.unsafe_offset(
                    Int(node.start)
                ).unsafe_origin_cast[ImmUntrackedOrigin](),
                length=Int(node.len),
            )
            comptime if mode == Mode.Eager:
                return _py_str_from_span(raw)
            else:
                if (node.flags & NodeFlags.HAS_ESCAPE) == 0 or (
                    node.flags & NodeFlags.LITERAL
                ) != 0:
                    return _py_str_from_span(raw)
                comptime if mode == Mode.Strict:
                    var s = decode_string_unchecked(raw, node.flags)
                    return _py_str_from_span(s.as_bytes())
                else:
                    var res = decode_string(raw, node.flags)
                    if case .Err(_) = res:
                        raise Error(res^.unsafe_take_error())
                    var s = res^.unsafe_take_value()
                    return _py_str_from_span(s.as_bytes())

        case .Integer:
            var iv: Int
            comptime if mode == Mode.Eager:
                var u = (UInt64(node.len) << 32) | UInt64(node.start)
                iv = Int(bitcast[DType.int64, 1](u))
            else:
                var raw = Span[Byte, ImmUntrackedOrigin](
                    unsafe_ptr=doc_ptr.unsafe_offset(
                        Int(node.start)
                    ).unsafe_origin_cast[ImmUntrackedOrigin](),
                    length=Int(node.len),
                )
                comptime if mode == Mode.Strict:
                    iv = decode_int_unchecked(raw, node.flags)
                else:
                    var res = decode_int(raw)
                    if not res._ok:
                        raise Error("Invalid integer value")
                    iv = res._val
            var p = cpython.PyLong_FromSsize_t(Py_ssize_t(iv))
            if not p:
                raise cpython.get_error()
            return PythonObject(from_owned=p)

        case .Float | .NaN | .Inf:
            comptime if has_parse_float and mode != Mode.Eager:
                var raw = Span[Byte, ImmUntrackedOrigin](
                    unsafe_ptr=doc_ptr.unsafe_offset(
                        Int(node.start)
                    ).unsafe_origin_cast[ImmUntrackedOrigin](),
                    length=Int(node.len),
                )
                comptime if mode == Mode.Trusted:
                    var check = decode_float(raw)
                    if not check._ok:
                        raise Error("Invalid float value")
                var raw_py = _py_str_from_span(raw)
                if cache[].has_call_one_arg:
                    var res_ptr = cache[].call_one_arg(
                        parse_float._obj_ptr, raw_py._obj_ptr
                    )
                    if not res_ptr:
                        raise cpython.get_error()
                    return PythonObject(from_owned=res_ptr)
                return parse_float(raw_py)
            else:
                var fv: Float64
                comptime if mode == Mode.Eager:
                    var u = (UInt64(node.len) << 32) | UInt64(node.start)
                    fv = bitcast[DType.float64, 1](u)
                else:
                    var raw = Span[Byte, ImmUntrackedOrigin](
                        unsafe_ptr=doc_ptr.unsafe_offset(
                            Int(node.start)
                        ).unsafe_origin_cast[ImmUntrackedOrigin](),
                        length=Int(node.len),
                    )
                    comptime if mode == Mode.Strict:
                        fv = decode_float_unchecked(raw, node.flags)
                    else:
                        var res = decode_float(raw)
                        if not res._ok:
                            raise Error("Invalid float value")
                        fv = res._val
                var p = cpython.PyFloat_FromDouble(fv)
                if not p:
                    raise cpython.get_error()
                return PythonObject(from_owned=p)

        case .Boolean:
            var bv: Bool
            comptime if mode == Mode.Eager:
                bv = node.start != 0
            else:
                var raw = Span[Byte, ImmUntrackedOrigin](
                    unsafe_ptr=doc_ptr.unsafe_offset(
                        Int(node.start)
                    ).unsafe_origin_cast[ImmUntrackedOrigin](),
                    length=Int(node.len),
                )
                comptime if mode == Mode.Strict:
                    bv = decode_bool_unchecked(raw)
                else:
                    var res = decode_bool(raw)
                    if not res._ok:
                        raise Error("Invalid boolean value")
                    bv = res._val
            var p = cpython.PyBool_FromLong(c_long(1) if bv else c_long(0))
            if not p:
                raise cpython.get_error()
            return PythonObject(from_owned=p)

        case .Date:
            var d: Date
            comptime if mode == Mode.Eager:
                d = Date(
                    year=Int(node.start >> 16),
                    month=Int((node.start >> 8) & 0xFF),
                    day=Int(node.start & 0xFF),
                )
            else:
                var raw = Span[Byte, ImmUntrackedOrigin](
                    unsafe_ptr=doc_ptr.unsafe_offset(
                        Int(node.start)
                    ).unsafe_origin_cast[ImmUntrackedOrigin](),
                    length=Int(node.len),
                )
                comptime if mode == Mode.Strict:
                    d = decode_date_unchecked(raw)
                else:
                    var res = decode_date(raw)
                    if not res._ok:
                        raise Error("Invalid date value")
                    d = res._val
            return _date_to_py(d, cache)

        case .Time:
            var t: Time
            comptime if mode == Mode.Eager:
                t = store_ptr[].temporals[Int(node.start)].time
            else:
                var raw = Span[Byte, ImmUntrackedOrigin](
                    unsafe_ptr=doc_ptr.unsafe_offset(
                        Int(node.start)
                    ).unsafe_origin_cast[ImmUntrackedOrigin](),
                    length=Int(node.len),
                )
                comptime if mode == Mode.Strict:
                    t = decode_time_unchecked(raw)
                else:
                    var res = decode_time(raw)
                    if not res._ok:
                        raise Error("Invalid time value")
                    t = res._val
            return _time_to_py(t, cache)

        case .DateTime:
            var dt: DateTime
            comptime if mode == Mode.Eager:
                dt = store_ptr[].temporals[Int(node.start)]
            else:
                var raw = Span[Byte, ImmUntrackedOrigin](
                    unsafe_ptr=doc_ptr.unsafe_offset(
                        Int(node.start)
                    ).unsafe_origin_cast[ImmUntrackedOrigin](),
                    length=Int(node.len),
                )
                comptime if mode == Mode.Strict:
                    dt = decode_datetime_unchecked(raw)
                else:
                    var res = decode_datetime(raw)
                    if not res._ok:
                        raise Error("Invalid datetime value")
                    dt = res._val
            return _datetime_to_py(dt, cache)

        case .Empty:
            return PythonObject(None)


def _eager_doc_to_py(
    ref doc: TomlDocument[Mode.Eager, ImmUntrackedOrigin],
    node_idx: UInt32,
) raises -> PythonObject:
    var cache = _get_cache()
    var r = doc.root()
    return _node_to_py[Mode.Eager, False](
        node_idx,
        r.doc_ptr,
        r.nodes_ptr,
        r.store_ptr,
        cache,
        PythonObject(None),
    )


def _node_kind_name(kind: NodeKind) -> StaticString:
    match kind:
        case .String:
            return "string"
        case .Integer:
            return "integer"
        case .Float | .NaN | .Inf:
            return "float"
        case .Boolean:
            return "boolean"
        case .Date:
            return "date"
        case .Time:
            return "time"
        case .DateTime:
            return "datetime"
        case .Array:
            return "array"
        case .Table:
            return "table"
        case .Empty:
            return "missing"


# --- Lazy NativeDocument type exposed to Python ---


struct NativeDocument(Movable, Writable):
    """Owning native `TomlDocument[Mode.Eager]` exposed to Python for lazy O(1) queries.
    """

    var doc: TomlDocument[Mode.Eager, ImmUntrackedOrigin]

    def __init__(
        out self, var doc: TomlDocument[Mode.Eager, ImmUntrackedOrigin]
    ):
        self.doc = doc^

    def write_to(self, mut w: Some[Writer]):
        w.write("NativeDocument(keys=", len(self.doc), ")")

    def write_repr_to(self, mut w: Some[Writer]):
        self.write_to(w)

    @staticmethod
    def node_kind(
        py_self: PythonObject, node_idx_obj: PythonObject
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var idx = Int(py=node_idx_obj)
        if idx < 0 or idx >= len(self_ptr[].doc.nodes):
            return _raise_index_error("Node index out of range")
        var k = _node_kind_name(self_ptr[].doc.nodes[idx].kind)
        return PythonObject(String(k))

    @staticmethod
    def node_len(
        py_self: PythonObject, node_idx_obj: PythonObject
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var idx = Int(py=node_idx_obj)
        if idx < 0 or idx >= len(self_ptr[].doc.nodes):
            return _raise_index_error("Node index out of range")
        ref node = self_ptr[].doc.nodes[idx]
        if node.kind != NodeKind.Table and node.kind != NodeKind.Array:
            return _raise_type_error("TOML scalar value has no len()")
        return PythonObject(Int(node.len))

    @staticmethod
    def table_get_idx(
        py_self: PythonObject, node_idx_obj: PythonObject, key_obj: PythonObject
    ) raises -> PythonObject:
        ref cpython = Python().cpython()
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var idx = Int(py=node_idx_obj)
        if idx < 0 or idx >= len(self_ptr[].doc.nodes):
            return _raise_index_error("Node index out of range")
        ref node = self_ptr[].doc.nodes[idx]
        if node.kind != NodeKind.Table:
            return _raise_type_error("TOML value is not a table")
        var opt_span = cpython.PyUnicode_AsUTF8AndSize(key_obj._obj_ptr)
        if not opt_span:
            return PythonObject(from_owned=PyObjectPtr())
        var key_bytes = opt_span.value().as_bytes()
        var arena_ptr = (
            self_ptr[].doc.store.arena.unsafe_ptr().unsafe_mut_cast[False]()
        )
        var nodes_ptr = (
            self_ptr[].doc.nodes.unsafe_ptr().unsafe_mut_cast[False]()
        )
        var child = self_ptr[].doc.store.key_index.find_by_bytes(
            UInt32(idx), key_bytes, nodes_ptr, arena_ptr
        )
        if child == NO_NODE:
            return PythonObject(-1)
        return PythonObject(Int(child))

    @staticmethod
    def array_get_idx(
        py_self: PythonObject,
        node_idx_obj: PythonObject,
        index_obj: PythonObject,
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var idx = Int(py=node_idx_obj)
        if idx < 0 or idx >= len(self_ptr[].doc.nodes):
            return _raise_index_error("Node index out of range")
        ref node = self_ptr[].doc.nodes[idx]
        if node.kind != NodeKind.Array:
            return _raise_type_error("TOML value is not an array")
        var n = Int(node.len)
        var elem_idx = Int(py=index_obj)
        if elem_idx < 0:
            elem_idx += n
        if elem_idx < 0 or elem_idx >= n:
            return _raise_index_error("TOML array index out of range")
        var child_idx: UInt32
        if (node.flags & NodeFlags.CONTIGUOUS) != 0:
            child_idx = node.first_child + UInt32(elem_idx)
        elif (node.flags & NodeFlags.SLOTTED) != 0:
            child_idx = self_ptr[].doc.store.array_slots[
                Int(node.start) + elem_idx
            ]
        else:
            var curr = node.first_child
            var step = 0
            while step < elem_idx and curr != NO_NODE:
                curr = self_ptr[].doc.nodes[Int(curr)].next_sibling
                step += 1
            child_idx = curr
        if child_idx == NO_NODE:
            return _raise_index_error("TOML array index out of range")
        return PythonObject(Int(child_idx))

    @staticmethod
    def table_keys(
        py_self: PythonObject, node_idx_obj: PythonObject
    ) raises -> PythonObject:
        ref cpython = Python().cpython()
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var idx = Int(py=node_idx_obj)
        if idx < 0 or idx >= len(self_ptr[].doc.nodes):
            return _raise_index_error("Node index out of range")
        ref node = self_ptr[].doc.nodes[idx]
        if node.kind != NodeKind.Table:
            return _raise_type_error("TOML value is not a table")
        var n = Int(node.len)
        var l_ptr = cpython.PyList_New(Py_ssize_t(n))
        if not l_ptr:
            raise cpython.get_error()
        var l_obj = PythonObject(from_owned=l_ptr)
        var arena_ptr = (
            self_ptr[].doc.store.arena.unsafe_ptr().unsafe_mut_cast[False]()
        )
        var nodes_ptr = (
            self_ptr[].doc.nodes.unsafe_ptr().unsafe_mut_cast[False]()
        )
        var curr = node.first_child
        var i = 0
        while curr != NO_NODE:
            ref child = nodes_ptr[unsafe_offset=Int(curr)]
            var k_obj = _key_to_py[Mode.Eager](child, arena_ptr)
            if (
                cpython.PyList_SetItem(
                    l_obj._obj_ptr, Py_ssize_t(i), k_obj^.steal_data()
                )
                != 0
            ):
                raise cpython.get_error()
            i += 1
            curr = child.next_sibling
        return l_obj^

    @staticmethod
    def node_to_py(
        py_self: PythonObject, node_idx_obj: PythonObject
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var idx = Int(py=node_idx_obj)
        if idx < 0 or idx >= len(self_ptr[].doc.nodes):
            return _raise_index_error("Node index out of range")
        return _eager_doc_to_py(self_ptr[].doc, UInt32(idx))

    @staticmethod
    def node_to_json(
        py_self: PythonObject, node_idx_obj: PythonObject
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var idx = Int(py=node_idx_obj)
        if idx < 0 or idx >= len(self_ptr[].doc.nodes):
            return _raise_index_error("Node index out of range")
        var json_out = String()
        var err_msg = String()
        var failed = False
        var py = Python()
        with GILReleased(py):
            try:
                var r = self_ptr[].doc.root()
                var view = Toml[origin_of(self_ptr[].doc), Mode.Eager](
                    r.doc_ptr.unsafe_origin_cast[origin_of(self_ptr[].doc)](),
                    r.nodes_ptr.unsafe_origin_cast[origin_of(self_ptr[].doc)](),
                    r.store_ptr.unsafe_origin_cast[origin_of(self_ptr[].doc)](),
                    UInt32(idx),
                )
                view.to_json(json_out)
            except e:
                err_msg = String(e)
                failed = True
        if failed:
            return _raise_decode_error(err_msg)
        return _py_str_from_span(json_out.as_bytes())


# --- Top-level parsing, validation, and JSON functions ---


def _loads_impl[
    mode: Mode
](
    bytes: Span[Byte, ImmUntrackedOrigin],
    parse_float: PythonObject,
    has_parse_float: Bool,
) raises -> PythonObject:
    comptime strict = mode != Mode.Trusted
    var nodes = List[Node]()
    var store_opt = Optional[_Store](None)
    var err_msg = String()
    var failed = False

    var py = Python()
    with GILReleased(py):
        var res = _parse_tape[strict](bytes)
        if case .Err(_) = res:
            err_msg = String(res^.unsafe_take_error())
            failed = True
        else:
            var n, ki, slots = res^.unsafe_take_value().into_parts()
            nodes = n^
            store_opt = Optional(_Store(ki^, slots^))

    if failed:
        return _raise_decode_error(err_msg)

    __guard case .Some(ref store) = store_opt else:
        return _raise_decode_error("Internal error: missing tape store")

    var cache = _get_cache()
    var doc_ptr = bytes.unsafe_ptr()
    var nodes_ptr = nodes.unsafe_ptr().unsafe_mut_cast[False]()
    var store_ptr = Pointer(to=store).unsafe_mut_cast[False]()
    try:
        if has_parse_float:
            return _node_to_py[mode, True](
                0, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
            )
        return _node_to_py[mode, False](
            0, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
        )
    except e:
        ref cpython = Python().cpython()
        if cpython.PyErr_Occurred():
            return PythonObject(from_owned=PyObjectPtr())
        return _raise_decode_error(String(e))


def py_loads(
    data_obj: PythonObject,
    parse_float: PythonObject,
    mode_obj: PythonObject,
) raises -> PythonObject:
    var mode_id = _parse_mode_arg(mode_obj)
    if mode_id < 0:
        return _raise_value_error("mode must be 'strict' or 'trusted'")
    var inp = _extract_input_bytes(data_obj)
    if not inp.ok:
        return PythonObject(from_owned=PyObjectPtr())
    var cache = _get_cache()
    var has_pf = not _is_none(parse_float, cache)
    var bytes = inp.as_span()
    var res: PythonObject
    if mode_id == 0:
        res = _loads_impl[Mode.Strict](bytes, parse_float, has_pf)
    else:
        res = _loads_impl[Mode.Trusted](bytes, parse_float, has_pf)
    _ = inp^
    return res^


def py_load_file(
    path_obj: PythonObject,
    parse_float: PythonObject,
    mode_obj: PythonObject,
) raises -> PythonObject:
    var mode_id = _parse_mode_arg(mode_obj)
    if mode_id < 0:
        return _raise_value_error("mode must be 'strict' or 'trusted'")
    var path = String(py=path_obj)
    var cache = _get_cache()
    var has_pf = not _is_none(parse_float, cache)

    var mapped_opt = Optional[MappedFile](None)
    var nodes = List[Node]()
    var store_opt = Optional[_Store](None)
    var err_msg = String()
    var is_os_err = False
    var failed = False

    var py = Python()
    with GILReleased(py):
        try:
            var mf = MappedFile(path)
            var raw = mf.bytes()
            if mode_id == 0:
                var res = _parse_tape[True](raw)
                if case .Err(_) = res:
                    err_msg = String(res^.unsafe_take_error())
                    failed = True
                else:
                    var n, ki, slots = res^.unsafe_take_value().into_parts()
                    nodes = n^
                    store_opt = Optional(_Store(ki^, slots^))
                    mapped_opt = Optional(mf^)
            else:
                var res = _parse_tape[False](raw)
                if case .Err(_) = res:
                    err_msg = String(res^.unsafe_take_error())
                    failed = True
                else:
                    var n, ki, slots = res^.unsafe_take_value().into_parts()
                    nodes = n^
                    store_opt = Optional(_Store(ki^, slots^))
                    mapped_opt = Optional(mf^)
        except e:
            err_msg = String(e)
            is_os_err = True
            failed = True

    if failed:
        if is_os_err:
            return _raise_os_error(err_msg)
        return _raise_decode_error(err_msg)

    __guard case .Some(ref mf) = mapped_opt else:
        return _raise_os_error("Failed to map TOML file")
    __guard case .Some(ref store) = store_opt else:
        return _raise_decode_error("Internal error: missing tape store")

    var raw = mf.bytes()
    var doc_ptr = raw.unsafe_ptr()
    var nodes_ptr = nodes.unsafe_ptr().unsafe_mut_cast[False]()
    var store_ptr = Pointer(to=store).unsafe_mut_cast[False]()
    var out: PythonObject
    try:
        if mode_id == 0:
            if has_pf:
                out = _node_to_py[Mode.Strict, True](
                    0, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
                )
            else:
                out = _node_to_py[Mode.Strict, False](
                    0, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
                )
        else:
            if has_pf:
                out = _node_to_py[Mode.Trusted, True](
                    0, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
                )
            else:
                out = _node_to_py[Mode.Trusted, False](
                    0, doc_ptr, nodes_ptr, store_ptr, cache, parse_float
                )
    except e:
        ref cpython = Python().cpython()
        if cpython.PyErr_Occurred():
            return PythonObject(from_owned=PyObjectPtr())
        return _raise_decode_error(String(e))
    _ = mapped_opt^
    return out^


def py_parse(data_obj: PythonObject) raises -> PythonObject:
    """Parse TOML into an owned `NativeDocument` with the GIL released."""
    var inp = _extract_input_bytes(data_obj)
    if not inp.ok:
        return PythonObject(from_owned=PyObjectPtr())
    var bytes = inp.as_span()

    var doc_opt = Optional[TomlDocument[Mode.Eager, ImmUntrackedOrigin]](None)
    var err_msg = String()
    var failed = False
    var py = Python()
    with GILReleased(py):
        var res = _parse_tape[True](bytes)
        if case .Err(_) = res:
            err_msg = String(res^.unsafe_take_error())
            failed = True
        else:
            doc_opt = Optional(_materialize(bytes, res^.unsafe_take_value()))
    _ = inp^
    if failed:
        return _raise_decode_error(err_msg)
    return PythonObject(alloc=NativeDocument(doc_opt.take()))


def py_parse_file(path_obj: PythonObject) raises -> PythonObject:
    """Parse a TOML file via mmap into an owned `NativeDocument` with the GIL released.
    """
    var path = String(py=path_obj)
    var doc_opt = Optional[TomlDocument[Mode.Eager, ImmUntrackedOrigin]](None)
    var err_msg = String()
    var is_os_err = False
    var failed = False

    var py = Python()
    with GILReleased(py):
        try:
            var mf = MappedFile(path)
            var raw = mf.bytes()
            var res = _parse_tape[True](raw)
            if case .Err(_) = res:
                err_msg = String(res^.unsafe_take_error())
                failed = True
            else:
                doc_opt = Optional(_materialize(raw, res^.unsafe_take_value()))
            _ = mf^
        except e:
            err_msg = String(e)
            is_os_err = True
            failed = True

    if failed:
        if is_os_err:
            return _raise_os_error(err_msg)
        return _raise_decode_error(err_msg)
    return PythonObject(alloc=NativeDocument(doc_opt.take()))


def py_validate(
    data_obj: PythonObject, mode_obj: PythonObject
) raises -> PythonObject:
    """Validate TOML 1.1 input completely in Mojo with the GIL released."""
    var mode_id = _parse_mode_arg(mode_obj)
    if mode_id < 0:
        return _raise_value_error("mode must be 'strict' or 'trusted'")
    var inp = _extract_input_bytes(data_obj)
    if not inp.ok:
        return PythonObject(from_owned=PyObjectPtr())
    var bytes = inp.as_span()
    var err_msg = String()
    var failed = False
    var py = Python()
    with GILReleased(py):
        if mode_id == 0:
            var res = _parse_tape[True](bytes)
            if case .Err(_) = res:
                err_msg = String(res^.unsafe_take_error())
                failed = True
            else:
                _ = res^.unsafe_take_value()
        else:
            var res = _parse_tape[False](bytes)
            if case .Err(_) = res:
                err_msg = String(res^.unsafe_take_error())
                failed = True
            else:
                _ = res^.unsafe_take_value()
    _ = inp^
    if failed:
        return _raise_decode_error(err_msg)
    return PythonObject(None)


def py_to_tagged_json(
    data_obj: PythonObject, mode_obj: PythonObject
) raises -> PythonObject:
    """Convert TOML 1.1 input directly to `toml-test` tagged JSON with the GIL released.
    """
    var mode_id = _parse_mode_arg(mode_obj)
    if mode_id < 0:
        return _raise_value_error("mode must be 'strict' or 'trusted'")
    var inp = _extract_input_bytes(data_obj)
    if not inp.ok:
        return PythonObject(from_owned=PyObjectPtr())
    var sspan = inp.as_string_span()
    var json_out = String()
    var err_msg = String()
    var failed = False
    var py = Python()
    with GILReleased(py):
        try:
            if mode_id == 0:
                json_out = toml_to_tagged_json[Mode.Strict](sspan)
            else:
                json_out = toml_to_tagged_json[Mode.Trusted](sspan)
        except e:
            err_msg = String(e)
            failed = True
    _ = inp^
    if failed:
        return _raise_decode_error(err_msg)
    return _py_str_from_span(json_out.as_bytes())


# --- TOML 1.1 Serializer (`dumps`) ---


def _is_mapping(
    obj: PythonObject, cache: Pointer[_PyCache, MutUntrackedOrigin]
) -> Bool:
    if cache[].is_instance(obj._obj_ptr, cache[].dict_type._obj_ptr) > 0:
        return True
    return cache[].is_instance(obj._obj_ptr, cache[].mapping_abc._obj_ptr) > 0


def _is_sequence_list(
    obj: PythonObject, cache: Pointer[_PyCache, MutUntrackedOrigin]
) -> Bool:
    if cache[].is_instance(obj._obj_ptr, cache[].list_type._obj_ptr) > 0:
        return True
    return cache[].is_instance(obj._obj_ptr, cache[].tuple_type._obj_ptr) > 0


def _is_aot(
    obj: PythonObject, cache: Pointer[_PyCache, MutUntrackedOrigin]
) raises -> Bool:
    """Return True if `obj` is a non-empty list/tuple whose elements are all Mappings.
    """
    if not _is_sequence_list(obj, cache):
        return False
    var n = len(obj)
    if n == 0:
        return False
    for i in range(n):
        var elem = obj[i]
        if not _is_mapping(elem, cache):
            return False
    return True


def _collect_mapping_entries(
    obj: PythonObject, cache: Pointer[_PyCache, MutUntrackedOrigin]
) raises -> Tuple[List[String], List[PythonObject]]:
    ref cpython = Python().cpython()
    var keys = List[String]()
    var vals = List[PythonObject]()
    var items_iter_obj = obj.items()
    var iter_ptr = cpython.PyObject_GetIter(items_iter_obj._obj_ptr)
    if not iter_ptr:
        raise cpython.get_error()
    var iter_obj = PythonObject(from_owned=iter_ptr)
    while True:
        var pair_ptr = cpython.PyIter_Next(iter_obj._obj_ptr)
        if not pair_ptr:
            if cpython.PyErr_Occurred():
                raise cpython.get_error()
            break
        var pair = PythonObject(from_owned=pair_ptr)
        var k_obj = pair[0]
        var v_obj = pair[1]
        if cache[].is_instance(k_obj._obj_ptr, cache[].str_type._obj_ptr) <= 0:
            raise Error("TYPE:TOML table keys must be strings")
        var opt_span = cpython.PyUnicode_AsUTF8AndSize(k_obj._obj_ptr)
        if not opt_span:
            raise cpython.get_error()
        keys.append(String(opt_span.value()))
        vals.append(v_obj^)
    return (keys^, vals^)


def _write_py_inline_value[
    W: Writer
](
    val: PythonObject,
    cache: Pointer[_PyCache, MutUntrackedOrigin],
    mut bw: _JsonBufWriter[W, _],
    depth: Int,
) raises:
    if depth > _MAX_SER_DEPTH:
        raise Error("VALUE:TOML nesting depth exceeded")
    ref cpython = Python().cpython()
    var ptr = val._obj_ptr

    # Bool must be checked before Int (in Python, isinstance(True, int) is True)
    if cpython.PyBool_Check(ptr) != 0:
        if Bool(val):
            bw.put_lit["true"]()
        else:
            bw.put_lit["false"]()
        return

    if cpython.PyLong_Check(ptr) != 0:
        var overflow = c_int(0)
        var iv = cache[].long_as_ll_overflow(
            ptr, Pointer(to=overflow).unsafe_origin_cast[MutUntrackedOrigin]()
        )
        if overflow != 0:
            raise Error("OVERFLOW:TOML integer out of 64-bit signed range")
        if cpython.PyErr_Occurred():
            raise cpython.get_error()
        var s = String(Int64(iv))
        bw.write_string(StringSpan(s))
        return

    if cpython.PyFloat_Check(ptr) != 0:
        var fv = Float64(cpython.PyFloat_AsDouble(ptr))
        if cpython.PyErr_Occurred():
            raise cpython.get_error()
        _put_toml_float(fv, bw)
        return

    if cache[].is_instance(ptr, cache[].str_type._obj_ptr) > 0:
        var opt_span = cpython.PyUnicode_AsUTF8AndSize(ptr)
        if not opt_span:
            raise cpython.get_error()
        _put_toml_quoted_bytes(opt_span.value().as_bytes(), bw)
        return

    # datetime must be checked before date (datetime subclasses date)
    if cache[].is_instance(ptr, cache[].datetime_cls._obj_ptr) > 0:
        var d = Date(
            year=Int(py=val.year),
            month=Int(py=val.month),
            day=Int(py=val.day),
        )
        var t = Time(
            hour=Int(py=val.hour),
            minute=Int(py=val.minute),
            second=Int(py=val.second),
            nanosecond=Int(py=val.microsecond) * 1000,
        )
        var tzinfo = val.tzinfo
        var is_local = True
        var off = Offset.utc
        if not _is_none(tzinfo, cache):
            var utcoff = val.utcoffset()
            if not _is_none(utcoff, cache):
                is_local = False
                var total_secs = Int(py=utcoff.days) * 86400 + Int(
                    py=utcoff.seconds
                )
                if total_secs % 60 != 0 or Int(py=utcoff.microseconds) != 0:
                    raise Error(
                        "VALUE:TOML datetime timezone offset must be whole"
                        " minutes"
                    )
                var total_mins = total_secs // 60
                if total_mins == 0:
                    off = Offset.utc
                else:
                    var pos = total_mins > 0
                    var abs_mins = total_mins if pos else -total_mins
                    var oh = abs_mins // 60
                    var om = abs_mins % 60
                    if oh > 23:
                        raise Error(
                            "VALUE:TOML datetime timezone offset out of range"
                        )
                    off = Offset(hour=oh, minute=om, positive=pos)
        var dt = DateTime(d, t, off, is_local)
        var buf = Array[Byte, 40](uninitialized=True)
        var n = _format_datetime_buf(dt, buf.unsafe_ptr(), 0)
        bw.put_bytes(buf.unsafe_ptr(), n)
        return

    if cache[].is_instance(ptr, cache[].date_cls._obj_ptr) > 0:
        var d = Date(
            year=Int(py=val.year),
            month=Int(py=val.month),
            day=Int(py=val.day),
        )
        var buf = Array[Byte, 16](uninitialized=True)
        var n = _format_date_buf(d, buf.unsafe_ptr(), 0)
        bw.put_bytes(buf.unsafe_ptr(), n)
        return

    if cache[].is_instance(ptr, cache[].time_cls._obj_ptr) > 0:
        if not _is_none(val.tzinfo, cache):
            raise Error("VALUE:TOML local time cannot have timezone info")
        var t = Time(
            hour=Int(py=val.hour),
            minute=Int(py=val.minute),
            second=Int(py=val.second),
            nanosecond=Int(py=val.microsecond) * 1000,
        )
        var buf = Array[Byte, 24](uninitialized=True)
        var n = _format_time_buf(t, buf.unsafe_ptr(), 0)
        bw.put_bytes(buf.unsafe_ptr(), n)
        return

    if _is_sequence_list(val, cache):
        bw.put_byte(Byte(ord("[")))
        var n = len(val)
        for i in range(n):
            if i > 0:
                bw.put_lit[", "]()
            _write_py_inline_value(val[i], cache, bw, depth + 1)
        bw.put_byte(Byte(ord("]")))
        return

    if _is_mapping(val, cache):
        var keys, vals = _collect_mapping_entries(val, cache)
        if len(keys) == 0:
            bw.put_lit["{}"]()
            return
        bw.put_lit["{ "]()
        for i in range(len(keys)):
            if i > 0:
                bw.put_lit[", "]()
            _put_toml_key(StringSpan(keys[i]), bw)
            bw.put_lit[" = "]()
            _write_py_inline_value(vals[i], cache, bw, depth + 1)
        bw.put_lit[" }"]()
        return

    if _is_none(val, cache):
        raise Error("TYPE:TOML does not support None values")

    raise Error("TYPE:Unsupported Python type for TOML serialization")


def _write_py_table_body[
    W: Writer
](
    obj: PythonObject,
    mut path: List[String],
    cache: Pointer[_PyCache, MutUntrackedOrigin],
    mut bw: _JsonBufWriter[W, _],
    mut need_blank_line: Bool,
    depth: Int,
) raises:
    if depth > _MAX_SER_DEPTH:
        raise Error("VALUE:TOML nesting depth exceeded")
    var keys, vals = _collect_mapping_entries(obj, cache)
    var n = len(keys)
    var is_section = List[Bool](capacity=n)

    # Pass 1: emit scalar and inline-array key/value pairs first
    for i in range(n):
        var v = vals[i]
        var sec = _is_mapping(v, cache) or _is_aot(v, cache)
        is_section.append(sec)
        if not sec:
            _put_toml_key(StringSpan(keys[i]), bw)
            bw.put_lit[" = "]()
            _write_py_inline_value(v, cache, bw, depth + 1)
            bw.put_byte(Byte(ord("\n")))
            need_blank_line = True

    # Pass 2: emit sub-tables and arrays of tables
    for i in range(n):
        if not is_section[i]:
            continue
        var k = keys[i]
        var v = vals[i]
        if _is_mapping(v, cache):
            var sub_keys, sub_vals = _collect_mapping_entries(v, cache)
            var has_direct_entries = len(sub_keys) == 0
            for j in range(len(sub_vals)):
                if not (
                    _is_mapping(sub_vals[j], cache)
                    or _is_aot(sub_vals[j], cache)
                ):
                    has_direct_entries = True
                    break
            if has_direct_entries:
                _put_section_header(
                    path, StringSpan(k), False, bw, need_blank_line
                )
            path.append(k)
            _write_py_table_body(v, path, cache, bw, need_blank_line, depth + 1)
            _ = path.pop()
        else:
            # Array of tables (`[[path.key]]`)
            var m = len(v)
            for j in range(m):
                var elem = v[j]
                _put_section_header(
                    path, StringSpan(k), True, bw, need_blank_line
                )
                path.append(k)
                _write_py_table_body(
                    elem, path, cache, bw, need_blank_line, depth + 1
                )
                _ = path.pop()


def py_dumps(obj: PythonObject) raises -> PythonObject:
    """Serialize a Python `Mapping` to a TOML 1.1 string."""
    var cache = _get_cache()
    if not _is_mapping(obj, cache):
        return _raise_type_error(
            "dumps() expects a mapping (dict) at top level"
        )

    var out = String()
    try:
        var bw = _JsonBufWriter(out)
        var path = List[String]()
        var need_blank_line = False
        _write_py_table_body(obj, path, cache, bw, need_blank_line, 0)
        bw.flush()
    except e:
        ref cpython = Python().cpython()
        if cpython.PyErr_Occurred():
            return PythonObject(from_owned=PyObjectPtr())
        var msg = String(e)
        if msg.startswith("TYPE:"):
            return _raise_type_error(String(msg[byte=5:]))
        if msg.startswith("OVERFLOW:"):
            return _raise_overflow_error(String(msg[byte=9:]))
        if msg.startswith("VALUE:"):
            return _raise_value_error(String(msg[byte=6:]))
        return _raise_value_error(msg)
    return _py_str_from_span(out.as_bytes())


# --- Module builder registration ---


def _register_cpu_bindings(mut mb: PythonModuleBuilder) raises:
    """Register all CPU TOML functions and `NativeDocument` on `mb`."""
    _ = _PY_CACHE.get_or_create_ptr()

    _ = (
        mb.add_type[NativeDocument]("_motoml.NativeDocument")
        .def_method[NativeDocument.node_kind](
            "node_kind", "Return the TOML kind string for the node at index."
        )
        .def_method[NativeDocument.node_len](
            "node_len", "Return child count of a table or array node."
        )
        .def_method[NativeDocument.table_get_idx](
            "table_get_idx",
            "Look up a table child index by key in O(1) (-1 if missing).",
        )
        .def_method[NativeDocument.array_get_idx](
            "array_get_idx",
            "Look up an array child index by integer offset in O(1).",
        )
        .def_method[NativeDocument.table_keys](
            "table_keys",
            "Return table keys in document order.",
        )
        .def_method[NativeDocument.node_to_py](
            "node_to_py",
            (
                "Materialize a node (scalar or subtree) into native Python"
                " objects."
            ),
        )
        .def_method[NativeDocument.node_to_json](
            "node_to_json",
            "Serialize a node subtree to toml-test tagged JSON.",
        )
    )

    mb.def_function[_set_decode_error_type](
        "_set_decode_error_type",
        "Register the Python TOMLDecodeError exception class.",
    )
    mb.def_function[py_loads](
        "loads",
        "Parse a TOML string or UTF-8 bytes into a Python dict.",
    )
    mb.def_function[py_load_file](
        "load_file",
        "Memory-map and parse a TOML file directly into a Python dict.",
    )
    mb.def_function[py_parse](
        "parse",
        "Parse a TOML string or UTF-8 bytes into a lazy NativeDocument.",
    )
    mb.def_function[py_parse_file](
        "parse_file",
        "Memory-map and parse a TOML file into a lazy NativeDocument.",
    )
    mb.def_function[py_validate](
        "validate",
        "Validate a TOML 1.1 document in Mojo with the GIL released.",
    )
    mb.def_function[py_to_tagged_json](
        "to_tagged_json",
        (
            "Convert TOML 1.1 input to toml-test tagged JSON with the GIL"
            " released."
        ),
    )
    mb.def_function[py_dumps](
        "dumps",
        "Serialize a Python mapping to a TOML 1.1 string.",
    )


def _export_qualified_type(
    mod: PythonObject, qualified_name: String, short_name: String
) raises:
    """Re-bind a `mod.Type` qualified type name cleanly onto `mod.<short_name>`.
    """
    var builtins = Python.import_module("builtins")
    var ty = builtins.getattr(mod, qualified_name)
    _ = builtins.setattr(mod, short_name, ty)
    _ = builtins.delattr(mod, qualified_name)
