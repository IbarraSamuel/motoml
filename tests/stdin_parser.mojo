from motoml.new_parser import toml_to_tagged_json, parse_toml
from io.io import _fdopen
from sys import stdin, param_env
from sys import argv


fn main() raises:
    comptime log = param_env.env_get_bool["LOG", False]()
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
