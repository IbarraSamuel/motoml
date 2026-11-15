from motoml import toml_to_tagged_json, Mode
from std.io.io import _fdopen
from std.sys import stdin


def main() raises:
    var stdh = _fdopen["r"](stdin)

    var in_str = String()
    while True:
        try:
            var content = stdh.readline()
            in_str.write(content, "\n")
        except:
            break

    var json = toml_to_tagged_json[Mode.Strict](in_str)
    print(json)
