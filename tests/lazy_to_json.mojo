from motoml import Mode, _Mode, try_parse_toml
from motoml.mmap_file import MappedFile
from std.sys import argv


def _run_mode[mode_id: Int, //, mode: _Mode[mode_id]](view: StringSpan):
    var out = String()
    comptime if mode_id == 0:
        var res = try_parse_toml[Mode.Eager](view)
        if case .Err(_) = res:
            print("PARSE_ERR:", res^.unsafe_take_error())
            return
        var doc = res^.unsafe_take_value()
        try:
            doc.to_json(out)
            print(out)
        except e:
            print("DECODE_ERR:", e)
    else:
        var res = try_parse_toml[mode](view)
        if case .Err(_) = res:
            print("PARSE_ERR:", res^.unsafe_take_error())
            return
        var doc = res^.unsafe_take_value()
        try:
            doc.to_json(out)
            print(out)
        except e:
            print("DECODE_ERR:", e)


def main() raises:
    var args = argv()
    if len(args) < 2:
        raise Error("Usage: lazy_to_json [--mode eager|strict|trusted] <file>")

    var mode = StringSpan("strict")
    var path_idx = 1
    if len(args) >= 4 and StringSpan(args[1]) == "--mode":
        mode = StringSpan(args[2])
        path_idx = 3

    var mf = MappedFile(String(args[path_idx]))
    var view = mf.unsafe_view()

    match mode:
        case "eager":
            _run_mode[Mode.Eager](view)
        case "trusted":
            _run_mode[Mode.Trusted](view)
        case _:
            _run_mode[Mode.Strict](view)
