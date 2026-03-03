from os import abort
from python import PythonObject
from python import Python

# from python._cpython import GILReleased
# from runtime.asyncrt import TaskGroup as TG
from python.bindings import PythonModuleBuilder

from ..new_parser import parse_toml_raises


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
