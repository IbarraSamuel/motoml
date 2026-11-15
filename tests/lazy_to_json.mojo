from motoml import parse_toml, Mode
from motoml.mmap_file import MappedFile
from std.sys import argv


def main() raises:
    var args = argv()
    if len(args) < 2:
        raise Error(
            "Usage: lazy_to_json [--mode"
            " eager|strict|structure|lexical|trusted] <file>"
        )

    var mode = StringSpan("strict")
    var path_idx = 1
    if len(args) >= 4 and StringSpan(args[1]) == "--mode":
        mode = StringSpan(args[2])
        path_idx = 3

    var mf = MappedFile(String(args[path_idx]))
    var view = mf.unsafe_view()

    if mode == "eager":
        var res = parse_toml[Mode.Eager](view)
        if case .Err(var e) = res^:
            print("PARSE_ERR:", e)
            return
        var doc = res^.unsafe_take_value()
        var out = String()
        try:
            doc.to_json(out)
            print(out)
        except e:
            print("DECODE_ERR:", e)
    elif mode == "trusted":
        var res = parse_toml[Mode.Trusted](view)
        if case .Err(var e) = res^:
            print("PARSE_ERR:", e)
            return
        var doc = res^.unsafe_take_value()
        var out = String()
        try:
            doc.to_json(out)
            print(out)
        except e:
            print("DECODE_ERR:", e)
    elif mode == "structure":
        var res = parse_toml[Mode.Structure](view)
        if case .Err(var e) = res^:
            print("PARSE_ERR:", e)
            return
        var doc = res^.unsafe_take_value()
        var out = String()
        try:
            doc.to_json(out)
            print(out)
        except e:
            print("DECODE_ERR:", e)
    elif mode == "lexical":
        var res = parse_toml[Mode.Lexical](view)
        if case .Err(var e) = res^:
            print("PARSE_ERR:", e)
            return
        var doc = res^.unsafe_take_value()
        var out = String()
        try:
            doc.to_json(out)
            print(out)
        except e:
            print("DECODE_ERR:", e)
    else:
        var res = parse_toml[Mode.Strict](view)
        if case .Err(var e) = res^:
            print("PARSE_ERR:", e)
            return
        var doc = res^.unsafe_take_value()
        var out = String()
        try:
            doc.to_json(out)
            print(out)
        except e:
            print("DECODE_ERR:", e)
