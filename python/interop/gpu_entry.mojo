"""MAX GPU-accelerated CPython extension entrypoint for `motoml._motoml`."""

from std.collections import List, Optional
from std.os import abort
from std.python import Python, PythonObject
from std.python._cpython import GILReleased, Py_ssize_t, PyObjectPtr
from std.python.bindings import PythonModuleBuilder
from std.sys import has_accelerator
from motoml import Mode, TomlDocument
from motoml.mmap_file import MappedFile
from motoml_gpu import (
    DEFAULT_MIN_GPU_BYTES,
    GpuTomlParser,
    toml_to_tagged_json_gpu,
)
from interop.core import (
    NativeDocument,
    _eager_doc_to_py,
    _export_qualified_type,
    _extract_input_bytes,
    _py_str_from_span,
    _raise_decode_error,
    _raise_os_error,
    _raise_py_exc,
    _register_cpu_bindings,
)


def _has_gpu_runtime() -> PythonObject:
    return PythonObject(has_accelerator())


struct NativeGpuParser(Movable, Writable):
    """Reusable GPU-accelerated TOML 1.1 parser exposed to Python."""

    var parser: Optional[GpuTomlParser]

    def __init__(
        out self,
        initial_capacity_bytes: Int = 2 * 1024 * 1024,
        min_gpu_bytes: Int = DEFAULT_MIN_GPU_BYTES,
    ) raises:
        comptime if has_accelerator():
            self.parser = Optional(
                GpuTomlParser(
                    initial_capacity_bytes=initial_capacity_bytes,
                    min_gpu_bytes=min_gpu_bytes,
                )
            )
        else:
            raise Error("No GPU accelerator available on this host")

    def write_to(self, mut w: Some[Writer]):
        w.write("NativeGpuParser(has_gpu=", has_accelerator(), ")")

    def write_repr_to(self, mut w: Some[Writer]):
        self.write_to(w)

    @staticmethod
    def py_init(
        out self: Self, args: PythonObject, kwargs: PythonObject
    ) raises:
        var cap = 2 * 1024 * 1024
        var min_bytes = DEFAULT_MIN_GPU_BYTES
        var n_args = len(args)
        if n_args >= 1:
            cap = Int(py=args[0])
        if n_args >= 2:
            min_bytes = Int(py=args[1])
        if kwargs._obj_ptr:
            if PythonObject("initial_capacity_bytes") in kwargs:
                cap = Int(py=kwargs[PythonObject("initial_capacity_bytes")])
            if PythonObject("min_gpu_bytes") in kwargs:
                min_bytes = Int(py=kwargs[PythonObject("min_gpu_bytes")])
        self = Self(initial_capacity_bytes=cap, min_gpu_bytes=min_bytes)

    @staticmethod
    def has_unified_memory(py_self: PythonObject) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        __guard case .Some(ref p) = self_ptr[].parser else:
            return PythonObject(False)
        return PythonObject(p.has_unified_memory)

    @staticmethod
    def warmup(
        py_self: PythonObject, strict_obj: PythonObject
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var strict = Bool(strict_obj)
        var err_msg = String()
        var failed = False
        var py = Python()
        with GILReleased(py):
            try:
                __guard case .Some(ref p) = self_ptr[].parser else:
                    raise Error("GPU parser not initialized")
                if strict:
                    p.warmup[True]()
                else:
                    p.warmup[False]()
            except e:
                err_msg = String(e)
                failed = True
        if failed:
            return _raise_py_exc("PyExc_RuntimeError", err_msg)
        return PythonObject(None)

    @staticmethod
    def parse(
        py_self: PythonObject,
        data_obj: PythonObject,
        force_gpu_obj: PythonObject,
        gpu_materialize_obj: PythonObject,
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var inp = _extract_input_bytes(data_obj)
        if not inp.ok:
            return PythonObject(from_owned=PyObjectPtr())
        var force_gpu = Bool(force_gpu_obj)
        var gpu_mat = Bool(gpu_materialize_obj)
        var sspan = inp.as_string_span()
        var doc_opt = Optional[TomlDocument[Mode.Eager, ImmUntrackedOrigin]](
            None
        )
        var err_msg = String()
        var failed = False

        var py = Python()
        with GILReleased(py):
            try:
                __guard case .Some(ref p) = self_ptr[].parser else:
                    raise Error("GPU parser not initialized")
                doc_opt = Optional(
                    p.parse[Mode.Eager](
                        sspan,
                        force_gpu=force_gpu,
                        gpu_materialize=gpu_mat,
                    )
                )
            except e:
                err_msg = String(e)
                failed = True
        _ = inp^
        if failed:
            return _raise_decode_error(err_msg)
        return PythonObject(alloc=NativeDocument(doc_opt.take()))

    @staticmethod
    def parse_file(
        py_self: PythonObject,
        path_obj: PythonObject,
        force_gpu_obj: PythonObject,
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var path = String(py=path_obj)
        var force_gpu = Bool(force_gpu_obj)
        var doc_opt = Optional[TomlDocument[Mode.Eager, ImmUntrackedOrigin]](
            None
        )
        var err_msg = String()
        var is_os_err = False
        var failed = False

        var py = Python()
        with GILReleased(py):
            try:
                __guard case .Some(ref p) = self_ptr[].parser else:
                    raise Error("GPU parser not initialized")
                var mf = MappedFile(path)
                var raw = StringSpan(unsafe_from_utf8=mf.bytes())
                doc_opt = Optional(
                    p.parse[Mode.Eager](raw, force_gpu=force_gpu)
                )
                _ = mf^
            except e:
                err_msg = String(e)
                if err_msg.startswith("Failed to open") or err_msg.startswith(
                    "Failed to stat"
                ):
                    is_os_err = True
                failed = True
        if failed:
            if is_os_err:
                return _raise_os_error(err_msg)
            return _raise_decode_error(err_msg)
        return PythonObject(alloc=NativeDocument(doc_opt.take()))

    @staticmethod
    def loads(
        py_self: PythonObject,
        data_obj: PythonObject,
        force_gpu_obj: PythonObject,
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var inp = _extract_input_bytes(data_obj)
        if not inp.ok:
            return PythonObject(from_owned=PyObjectPtr())
        var force_gpu = Bool(force_gpu_obj)
        var sspan = inp.as_string_span()
        var doc_opt = Optional[TomlDocument[Mode.Eager, ImmUntrackedOrigin]](
            None
        )
        var err_msg = String()
        var failed = False

        var py = Python()
        with GILReleased(py):
            try:
                __guard case .Some(ref p) = self_ptr[].parser else:
                    raise Error("GPU parser not initialized")
                doc_opt = Optional(
                    p.parse[Mode.Eager](sspan, force_gpu=force_gpu)
                )
            except e:
                err_msg = String(e)
                failed = True
        _ = inp^
        if failed:
            return _raise_decode_error(err_msg)
        var doc = doc_opt.take()
        return _eager_doc_to_py(doc, 0)

    @staticmethod
    def load_file(
        py_self: PythonObject,
        path_obj: PythonObject,
        force_gpu_obj: PythonObject,
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var path = String(py=path_obj)
        var force_gpu = Bool(force_gpu_obj)
        var doc_opt = Optional[TomlDocument[Mode.Eager, ImmUntrackedOrigin]](
            None
        )
        var err_msg = String()
        var is_os_err = False
        var failed = False

        var py = Python()
        with GILReleased(py):
            try:
                __guard case .Some(ref p) = self_ptr[].parser else:
                    raise Error("GPU parser not initialized")
                var mf = MappedFile(path)
                var raw = StringSpan(unsafe_from_utf8=mf.bytes())
                doc_opt = Optional(
                    p.parse[Mode.Eager](raw, force_gpu=force_gpu)
                )
                _ = mf^
            except e:
                err_msg = String(e)
                if err_msg.startswith("Failed to open") or err_msg.startswith(
                    "Failed to stat"
                ):
                    is_os_err = True
                failed = True
        if failed:
            if is_os_err:
                return _raise_os_error(err_msg)
            return _raise_decode_error(err_msg)
        var doc = doc_opt.take()
        return _eager_doc_to_py(doc, 0)

    @staticmethod
    def parse_batch(
        py_self: PythonObject,
        docs_obj: PythonObject,
        force_gpu_obj: PythonObject,
    ) raises -> PythonObject:
        ref cpython = Python().cpython()
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var force_gpu = Bool(force_gpu_obj)

        var iter_ptr = cpython.PyObject_GetIter(docs_obj._obj_ptr)
        if not iter_ptr:
            return PythonObject(from_owned=PyObjectPtr())
        var iter_obj = PythonObject(from_owned=iter_ptr)
        var mojo_docs = List[String]()
        while True:
            var item_ptr = cpython.PyIter_Next(iter_obj._obj_ptr)
            if not item_ptr:
                if cpython.PyErr_Occurred():
                    return PythonObject(from_owned=PyObjectPtr())
                break
            var item = PythonObject(from_owned=item_ptr)
            var inp = _extract_input_bytes(item)
            if not inp.ok:
                return PythonObject(from_owned=PyObjectPtr())
            mojo_docs.append(String(inp.as_string_span()))

        var parsed = List[TomlDocument[Mode.Eager, ImmUntrackedOrigin]]()
        var err_msg = String()
        var failed = False
        var py = Python()
        with GILReleased(py):
            try:
                __guard case .Some(ref p) = self_ptr[].parser else:
                    raise Error("GPU parser not initialized")
                parsed = p.parse_batch_eager(
                    Span(mojo_docs), force_gpu=force_gpu
                )
            except e:
                err_msg = String(e)
                failed = True
        if failed:
            return _raise_decode_error(err_msg)

        var n = len(parsed)
        var l_ptr = cpython.PyList_New(Py_ssize_t(n))
        if not l_ptr:
            raise cpython.get_error()
        var l_obj = PythonObject(from_owned=l_ptr)
        # Drain from back to front using pop() so each TomlDocument moves without copying
        for rev_i in range(n):
            var dst_idx = n - 1 - rev_i
            var doc = parsed.pop()
            var py_doc = PythonObject(alloc=NativeDocument(doc^))
            if (
                cpython.PyList_SetItem(
                    l_obj._obj_ptr, Py_ssize_t(dst_idx), py_doc^.steal_data()
                )
                != 0
            ):
                raise cpython.get_error()
        return l_obj^

    @staticmethod
    def to_tagged_json(
        py_self: PythonObject,
        data_obj: PythonObject,
        force_gpu_obj: PythonObject,
    ) raises -> PythonObject:
        var self_ptr = py_self.downcast_value_ptr[Self]()
        var inp = _extract_input_bytes(data_obj)
        if not inp.ok:
            return PythonObject(from_owned=PyObjectPtr())
        var force_gpu = Bool(force_gpu_obj)
        var sspan = inp.as_string_span()
        var json_out = String()
        var err_msg = String()
        var failed = False

        var py = Python()
        with GILReleased(py):
            try:
                __guard case .Some(ref p) = self_ptr[].parser else:
                    raise Error("GPU parser not initialized")
                json_out = toml_to_tagged_json_gpu[Mode.Strict](
                    p, sspan, force_gpu=force_gpu
                )
            except e:
                err_msg = String(e)
                failed = True
        _ = inp^
        if failed:
            return _raise_decode_error(err_msg)
        return _py_str_from_span(json_out.as_bytes())


@export
def PyInit__motoml() abi("C") -> PythonObject:
    """Initialize the MAX GPU-enabled CPython extension module `_motoml`."""
    try:
        var mb = PythonModuleBuilder("_motoml")
        _register_cpu_bindings(mb)
        mb.def_function[_has_gpu_runtime](
            "has_gpu",
            (
                "Return True if motoml was built with MAX GPU support and an"
                " accelerator is available."
            ),
        )
        _ = (
            mb.add_type[NativeGpuParser]("_motoml.NativeGpuParser")
            .def_py_init[NativeGpuParser.py_init]()
            .def_method[NativeGpuParser.has_unified_memory](
                "has_unified_memory",
                (
                    "Return True if the active GPU supports unified host/device"
                    " memory."
                ),
            )
            .def_method[NativeGpuParser.warmup](
                "warmup",
                "Compile and warm up GPU Stage-1 kernels.",
            )
            .def_method[NativeGpuParser.parse](
                "parse",
                "Parse TOML text on GPU into a lazy NativeDocument.",
            )
            .def_method[NativeGpuParser.parse_file](
                "parse_file",
                (
                    "Memory-map and parse a TOML file on GPU into a lazy"
                    " NativeDocument."
                ),
            )
            .def_method[NativeGpuParser.loads](
                "loads",
                "Parse TOML text on GPU directly into a Python dict.",
            )
            .def_method[NativeGpuParser.load_file](
                "load_file",
                (
                    "Memory-map and parse a TOML file on GPU directly into a"
                    " Python dict."
                ),
            )
            .def_method[NativeGpuParser.parse_batch](
                "parse_batch",
                (
                    "Parse a batch of TOML documents in a single GPU Stage-1"
                    " launch."
                ),
            )
            .def_method[NativeGpuParser.to_tagged_json](
                "to_tagged_json",
                "Parse TOML text on GPU and stream toml-test tagged JSON.",
            )
        )
        var mod = mb.finalize()
        _export_qualified_type(mod, "_motoml.NativeDocument", "NativeDocument")
        _export_qualified_type(
            mod, "_motoml.NativeGpuParser", "NativeGpuParser"
        )
        return mod
    except e:
        abort(String("failed to create _motoml GPU module: ", e))
