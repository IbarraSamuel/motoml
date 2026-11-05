from motoml.lazy import parse_lazy, Validation
from motoml.mmap_file import MappedFile
from std.sys import argv


def main() raises:
    var args = argv()
    if len(args) < 2:
        raise Error(
            "Usage: lazy_to_json [--mode strict|structure|lexical|trusted]"
            " <file>"
        )

    var mode = StringSlice("strict")
    var path_idx = 1
    if len(args) >= 4 and StringSlice(args[1]) == "--mode":
        mode = StringSlice(args[2])
        path_idx = 3

    var mf = MappedFile(String(args[path_idx]))
    var bytes = mf.unsafe_view().as_bytes()

    if mode == "trusted":
        var res = parse_lazy[Validation.Trusted](bytes)
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
        var res = parse_lazy[Validation.Structure](bytes)
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
        var res = parse_lazy[Validation.Lexical](bytes)
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
        var res = parse_lazy[Validation.Strict](bytes)
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
