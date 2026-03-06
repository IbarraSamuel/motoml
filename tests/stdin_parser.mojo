from motoml.new_parser import toml_to_tagged_json, parse_toml
from std.io.io import _fdopen
from std.sys import stdin
from std.sys.defines import get_defined_bool
from std.sys import argv


fn main() raises:
    comptime log = get_defined_bool["LOG", False]()
    var stdh = _fdopen["r"](stdin)

    var in_str = String()
    while True:
        try:
            var content = stdh.readline()
            in_str.write(content, "\n")
        except:
            break

    var json = toml_to_tagged_json[log=log](in_str)
    print(json)
