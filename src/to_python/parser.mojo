from std.os import abort
from std.python import PythonObject, Python
from std.python.bindings import PythonModuleBuilder

from ..parser import parse_toml_raises


@export
fn PyInit_motoml() -> PythonObject:
    try:
        var module = PythonModuleBuilder("motoml")
        module.def_function[loads]("loads", "Parse a toml file from a string.")
        return module.finalize()
    except e:
        abort(String("failed to create Python module: ", e))


fn loads(v: PythonObject) raises -> PythonObject:
    return parse_toml_raises(String(py=v)).to_python_object()
