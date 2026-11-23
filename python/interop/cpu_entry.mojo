"""CPU-only CPython extension entrypoint for `motoml._motoml`."""

from std.os import abort
from std.python import PythonObject
from std.python.bindings import PythonModuleBuilder
from interop.core import _export_qualified_type, _register_cpu_bindings


def _has_gpu_false() -> PythonObject:
    return PythonObject(False)


@export
def PyInit__motoml() abi("C") -> PythonObject:
    """Initialize the CPU-only CPython extension module `_motoml`."""
    try:
        var mb = PythonModuleBuilder("_motoml")
        _register_cpu_bindings(mb)
        mb.def_function[_has_gpu_false](
            "has_gpu",
            (
                "Return True if motoml was built with MAX GPU support and an"
                " accelerator is available."
            ),
        )
        var mod = mb.finalize()
        _export_qualified_type(mod, "_motoml.NativeDocument", "NativeDocument")
        return mod
    except e:
        abort(String("failed to create _motoml module: ", e))
