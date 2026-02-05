from motoml.read import toml_to_tagged_json, parse_toml
from io.io import _fdopen
from sys import stdin
from sys import argv


fn main() raises:
    var stdh = _fdopen["r"](stdin)

    var in_str = String()
    while True:
        try:
            var content = stdh.readline()    
            in_str.write(content, "\n")
        except:
            break

    var toml = parse_toml(in_str)
    var out_str = String()
    toml.write_tagged_json_to(out_str)
    print(out_str)
