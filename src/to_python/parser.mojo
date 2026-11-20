from std.os import abort
from std.python import PythonObject
from std.python.bindings import PythonModuleBuilder

from ..parser import parse_toml


@export
def PyInit_motoml() abi("C") -> PythonObject:
    try:
        var m = PythonModuleBuilder("motoml")
        m.def_function[loads]("loads", docstring="Parse TOML string")
        return m.finalize()
    except e:
        abort(String("failed to create Python extension module: ", e))


def loads(v: PythonObject) raises -> PythonObject:
    var s = String(py=v)
    var w = String()
    var doc = parse_toml(s).take()
    doc.to_json(w)
    return w
