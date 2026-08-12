"""
Rules:
Dotted keys, can create a dictionary grouping the values.
"""

from .result import Result
from .types.toml import Toml
from .types.string_ref import StringRef

comptime SquareBracketOpen = Byte(ord("["))
comptime SquareBracketClose = Byte(ord("]"))
comptime CurlyBracketOpen = Byte(ord("{"))
comptime CurlyBracketClose = Byte(ord("}"))

comptime NewLine = Byte(ord("\n"))
comptime Enter = Byte(ord("\r"))
comptime Space = Byte(ord(" "))
comptime Tab = Byte(ord("\t"))

comptime Comment = Byte(ord("#"))
comptime Comma = Byte(ord(","))
comptime Equal = Byte(ord("="))
comptime Period = Byte(ord("."))

comptime DoubleQuote = Byte(ord('"'))
comptime SingleQuote = Byte(ord("'"))
comptime Escape = Byte(ord("\\"))

def _printif[log: Bool](msg: Some[Writable], *, sep: StringSlice = " ", end: StringSlice = "\n"):
    if log:
        print(msg,sep=sep,end=end)

def parse_multiline_string[
    quote_type: Byte, *, ignore_escape: Bool
](data: Span[Byte, _], mut idx: Int) -> Result[Span[Byte, data.origin]]:
    # Go inside the multiline
    idx += 3
    # put first value as the value_init
    var value_init = idx
    # Move +2 to be about to the end of closing in case it's empty
    idx += 2

    while idx < len(data) and (
        data[idx] != quote_type
        or data[idx - 1] != quote_type
        or data[idx - 2] != quote_type
        or (data[idx - 3] == Escape and not ignore_escape)
    ):
        idx += 1

    if idx >= len(data):
        return Error( "Multiline not closed.")

    # move two if there is a end like: """""
    # comptime if ignore_escape:
    #     return data[value_init : idx - 2]

    if len(data) > idx + 1 and data[idx + 1] == quote_type:
        idx += 1
    if len(data) > idx + 1 and data[idx + 1] == quote_type:
        idx += 1
    # When it stopped, the value already have two quotes, remove them from value
    return data[value_init : idx - 2]


def parse_quoted_string[
    quote_type: Byte, *, ignore_escape: Bool
](data: Span[Byte, _], mut idx: Int) -> Result[Span[Byte, data.origin]]:
    idx += 1
    var value_init = idx
    if idx >= len(data):
        return Error("String not closed.")

    while data[idx] != quote_type:
        idx += 1

        if idx >= len(data):
            return Error("String not closed.")

        comptime if not ignore_escape:
            if data[idx] == quote_type:
                var n_esc = 0
                while data[idx - n_esc - 1] == Escape:
                    n_esc += 1

                if n_esc % 2 != 0:
                    idx += 1

    return data[value_init:idx]


def parse_inline_array[log: Bool](
    data: Span[mut=False, Byte, _], mut idx: Int
) -> Result[Toml.Array]:
    """Assumes the first char is already within the collection, but could be a space.
    """
    skip_blanks_and_comments(data, idx)
    _printif[log]("Start array parsing")

    # var value = toml.TomlType.new_array()
    var arr = Toml.Array(capacity=16)
    # ref arr = value[toml.TomlTypes.Array]

    while idx < len(data) and data[idx] != SquareBracketClose:
        _printif[log](
            t"parsing array value at idx: {idx} and span `{StringSlice(unsafe_from_utf8=data[idx:idx + 30])}`"
        )
        var arr_item = parse_value[SquareBracketClose, log=log](data, idx)
        if not arr_item:
            return arr_item^.unsafe_take_error()
        # var s = String()
        # arr_item.write_tagged_json_to(s)
        # print("value parsed: `{}`".format(s))
        arr.append(arr_item^.unsafe_take_value())
        # We are at the end of the item parsed, let's move +1
        idx += 1
        # For both table and array, you need to split by comma
        skip_blanks_and_comments(data, idx)

        stop_at[Comma, SquareBracketClose](data, idx)
        if idx >= len(data) or data[idx] == SquareBracketClose:
            break

        # we are at a comma
        idx += 1

        skip_blanks_and_comments(data, idx)

    return arr^


def string_to_type[
    end_char: Byte
](data: Span[mut=False, Byte, _], mut idx: Int) -> Result[Toml]:
    """Returns end of value + 1."""
    # print("parsing value at idx: ", idx)
    # print(
    #     "value starts with: `{}...`".format(
    #         StringSlice(unsafe_from_utf8=data[idx : idx + 30])
    #     )
    # )
    # comptime INT_AGG, DEC_AGG = 10.0, 0.1
    # comptime neg, pos = Byte(ord("-")), Byte(ord("+"))
    # var all_is_digit = True
    # var has_period = False

    if data[idx : idx + 4] == "true".as_bytes():
        idx += 3
        return Toml(True)

    elif data[idx : idx + 5] == "false".as_bytes():
        idx += 4
        return Toml(value=False)

    elif data[idx : idx + 3] == "nan".as_bytes():
        idx += 2
        return Toml(Toml.NaN())
    elif data[idx : idx + 4] == "+nan".as_bytes():
        idx += 3
        return Toml(Toml.NaN())
    elif data[idx : idx + 4] == "-nan".as_bytes():
        idx += 3
        return Toml(Toml.NaN())
    elif data[idx : idx + 3] == "inf".as_bytes():
        idx += 2
        return Toml(Float64.MAX)
    elif data[idx : idx + 4] == "+inf".as_bytes():
        idx += 3
        return Toml(Float64.MAX)
    elif data[idx : idx + 4] == "-inf".as_bytes():
        idx += 3
        return Toml(Float64.MIN)

    var v_init = idx

    comptime lower = Byte(ord("0"))
    comptime upper = Byte(ord("9"))

    comptime neg = Byte(ord("-"))
    comptime pos = Byte(ord("+"))

    var datetime_split: Int = -1
    var dashes: Int = 0
    var colons: Int = 0
    var is_ascii_digit: Bool = True
    var is_neg = data[idx] == neg
    var is_pos = data[idx] == pos

    var is_hex = data[idx] == lower and (
        data[idx + 1] == Byte(ord("x")) or data[idx + 1] == Byte(ord("X"))
    )
    var is_bin = data[idx] == lower and (
        data[idx + 1] == Byte(ord("b")) or data[idx + 1] == Byte(ord("B"))
    )
    var is_oct = data[idx] == lower and (
        data[idx + 1] == Byte(ord("o")) or data[idx + 1] == Byte(ord("O"))
    )

    while (
        idx < len(data)
        and data[idx] != end_char
        and data[idx] != Comment
        and data[idx] != NewLine
        and data[idx] != Space
        and data[idx] != Comma
        and data[idx] != Tab
    ):
        dashes += Int(data[idx] == neg)
        colons += Int(data[idx] == Byte(ord(":")))

        is_ascii_digit &= (
            lower <= data[idx] <= upper
            or data[idx] == Byte(ord("_"))
            or (
                idx == v_init
                and (is_pos or is_neg))
            )
            or (idx == v_init + 1 and (is_hex or is_bin or is_oct))
        

        idx += 1
        if idx < len(data) and data[idx] == Space and lower <= data[idx + 1] <= upper:
            datetime_split = idx
            idx += 1

    var v_span = data[v_init:idx]
    var v_slice = StringSlice(unsafe_from_utf8=v_span)
    # Roll back one step because we finalized all time in the next item
    # print("Value is:", v_slice)

    idx -= 1
    if (
        datetime_split != -1
        or Byte(ord("T")) in v_span
        or Byte(ord("t")) in v_span
    ):
        # print("parsing datetime")
        return Toml.DateTime.from_string(v_slice).map(as_toml[Toml.DateTime])

    elif dashes == 2 and len(v_span) == 10:
        # print("parsing date")
        return Toml.Date.from_string(v_slice).map(as_toml[Toml.Date])

    elif colons > 0:
        # print("psrgin time")
        return Toml.Time.from_string(v_slice).map(as_toml[Toml.Time])

    elif is_ascii_digit or is_hex or is_bin or is_oct:
        # print("parsing int")
        var v = v_slice[byte=2 if is_hex or is_bin or is_oct else 0 :].replace("_", "")
        var base = 16 if is_hex else 8 if is_oct else 2 if is_bin else 10
        try:
            return Toml(atol(v,base=base))
        except e:
            return e^

    elif (
        (var dot := v_slice.find(".")) != -1
        and v_slice[byte=Int(is_neg or is_pos) : dot]
        .replace("_", "")
        .is_ascii_digit()
        and v_slice[byte=dot + 1 :].replace("_", "").is_ascii_digit()
    ) or "e" in v_slice or "E" in v_slice:
        try:
            return Toml(atof(v_slice.replace("_", "")))
        except e:
            return e^

    return Error(t"Could not find a type for value: `{v_slice}`")


def calc_value[o: Origin, lit:Bool, multi: Bool](var s: Span[Byte, o]) -> Result[String]:
    return StringRef(s, literal=lit, multiline=multi).calc_value()

def as_toml[T: Movable](var s: T) -> Toml where Toml.AllTypes.contains[T]():
    return Toml(s^)


def parse_value[
    end_char: Byte, *, log: Bool
](data: Span[mut=False, Byte, _], mut idx: Int) -> Result[Toml]:
    # Assumes the first char is the first value of the value to parse.
    if data[idx] == DoubleQuote:
        if data[idx + 1] == DoubleQuote and data[idx + 2] == DoubleQuote:
            # print("value is a triple double quote string")
            var s = parse_multiline_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            return s^.and_then(calc_value[data.origin, lit=False, multi=True]).map(as_toml[String])

        else:
            # print("value is double quote string")
            var s = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            return s^.and_then(calc_value[data.origin, lit=False,multi=False]).map(as_toml[String])

    elif data[idx] == SingleQuote:
        if data[idx + 1] == SingleQuote and data[idx + 2] == SingleQuote:
            # print("value is a triple single quote string")
            var s = parse_multiline_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return s^.and_then(calc_value[data.origin, lit=True, multi=True]).map(as_toml[String])
        else:
            # print("value is single quote string")
            var s = parse_quoted_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return s^.and_then(calc_value[data.origin, lit=True, multi=False]).map(as_toml[String])
    elif data[idx] == SquareBracketOpen:
        idx += 1
        _printif[log]("parsing inline array...")
        return parse_inline_array[log=log](data, idx).map(as_toml[Toml.Array])
    elif data[idx] == CurlyBracketOpen:
        idx += 1
        _printif[log]("parsing inline table...")
        skip_blanks_and_comments(data, idx)
        return parse_kv_pairs[
            separator=Comma, end_char=CurlyBracketClose
        ](data, idx).map(as_toml[Toml.Table])
        # print("last multiline table codepoint parsed is:", Codepoint(data[idx]))
    else:
        return string_to_type[end_char](data, idx)


def get_table_ref[
    log: Bool = False
](
    keys: Span[String, _],
    mut base: Toml.Table,
    *,
    var default: Toml,  # it's the leaf. The last container
) -> Result[Pointer[Toml, origin_of(base)]]:
    var cont = Pointer(to=base)
    for k in keys[: len(keys) - 1]:
        _printif[log](
                t"|> k -> '{k}' ",
                end="",
            )

        ref inner_v = cont[].setdefault(
            k,
            Toml(Toml.Table(capacity=32)),
        )
        if inner_v.isa[Toml.Array]():
            ref inner_arr = inner_v.unsafe_ref[Toml.Array]()
            if len(inner_arr) == 0:
                inner_arr.append(Toml(Toml.Table(capacity=16)))
            cont = Pointer(to=inner_arr[len(inner_arr) - 1].unsafe_ref[Toml.Table]()).unsafe_origin_cast[origin_of(base)]()
        elif inner_v.isa[Toml.Table]():
            cont = Pointer(to=inner_v.unsafe_ref[Toml.Table]()).unsafe_origin_cast[origin_of(base)]()
        else:
            return Error("Toml type is not a container.")

    ref k = keys[len(keys) - 1]
    var final_c: Pointer[Toml, origin_of(base)]
    if default.isa[Toml.Array]():
        final_c = Pointer(to=cont[].setdefault(k, Toml(Toml.Array(capacity=16)))).unsafe_origin_cast[origin_of(base)]()
        if not final_c[].isa[Toml.Array]():
            return Error("Container should be an array, but it's not.")
        ref arr = final_c[].unsafe_ref[Toml.Array]()
        arr.extend(default^.unsafe_take[Toml.Array]())
        if len(arr) > 0:
            final_c = Pointer(to=arr[len(arr) - 1]).unsafe_origin_cast[origin_of(base)]()
            
    else:
        final_c = Pointer(to=cont[].setdefault(k, default^)).unsafe_origin_cast[origin_of(base)]()

    return final_c
    
def set_key_value[
    log: Bool = False
](
    keys: Span[String, _],
    mut base: Toml.Table,
    *,
    var value: Toml,
) -> Optional[Error]:
    var cont = Pointer(to=base)
    for k in keys[: len(keys) - 1]:
        _printif[log](t"|> k -> '{k}' ",end="")
        var default = Toml(Toml.Table(capacity=8))
        ref inner_v = cont[].setdefault(k,default^)
        if not inner_v.isa[Toml.Table]():
            return Error("Toml type is not a table container.")
        cont = Pointer(to=inner_v.unsafe_ref[Toml.Table]()).unsafe_origin_cast[origin_of(base)]()

    ref k = keys[len(keys) - 1]
    if k in cont[]:
        return Error("ERROR: Table value already defined!")

    cont[][k] = value^

    return None

def parse_keys[
    o: ImmOrigin, //, close_char: Byte, *, log: Bool
](
    data: Span[Byte, o], mut idx: Int, var key_base: List[String]
) -> Result[List[String]]:
    """
    In a case we have a.b.c we expect to get back (a.b.c, c), no quotes included.
    This should be able to work on either inline key/values, multiline or nested. eg:
    some.key = "value"
    ['some'.key]
    [[some.'key']]
    v = {'some'.key = 1}
    Just give back total vs specific approach.
    """
    var key_init = idx
    var key: Optional[String] = {}

    _printif[log](t"Len data is: {len(data)} and curr idx is: {idx}")
    while idx < len(data) and data[idx] != close_char:
        var chr = data[idx]
        if chr != Space and chr != Tab and chr != Period and key:
            return Error("Invalid Key Definition: Key is not closed.")
        elif chr == SingleQuote:
            key = parse_quoted_string[SingleQuote, ignore_escape=True](data, idx).and_then(calc_value[o, lit=True, multi=False]).as_optional()
            idx += 1
            continue
        elif chr == DoubleQuote:
            key = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            ).and_then(calc_value[o, lit=False, multi=False]).as_optional()
            # var is_literal = Escape not in k
            idx += 1
            continue
        elif not key and (chr == Space or chr == Tab):
            var k = data[key_init:idx]
            key = StringRef(k, literal=False, multiline=False).calc_value().as_optional()
            skip[Space, Tab](data, idx)
            continue
        elif chr == Period:
            if not key:
                key = StringRef(
                    data[key_init:idx], literal=False, multiline=False
                ).calc_value().as_optional()

            # store the next level in the key_base list
            key_base.append(key.unsafe_take())
            # skip dot
            idx += 1
            if data[idx] == close_char:
                return Error("Error while creating nested table. No key defined after dot.")
            # Skip any space between parsed element and next key
            skip[Space, Tab](data, idx)
            # Return the inner element?
            return parse_keys[close_char, log=log](data, idx, key_base^)
        elif chr == Byte(ord("#")):
            return Error("Comment found in middle of key")
        # elif key and chr == Equal:
        #     return Error("Assignment in middle of key definition.")
        idx += 1

    # _printif[log](t"Len data is: {len(data)} and curr idx is: {idx}")
    if idx == len(data) or idx > len(data):
        return Error("Key not closed.")

    if not key:
        key = StringRef(data[key_init:idx], literal=False, multiline=False).calc_value().as_optional()

    var k = key.take()
    key_base.append(k)
    _printif[log](t"Parsed key base: {key_base}")
    return key_base^


def parse_kv_pairs[
    separator: Byte, end_char: Byte, log: Bool = False,
](data: Span[mut=False, Byte, _], mut idx: Int) -> Result[Toml.Table]:
    """This function expect to be on top of the value to start parsing. So item=1.
    End at the last value + 1.
    """

    _printif[log]("++ kcreate new empty table container")
    var table = Toml.Table(capacity=16)
    while idx < len(data) and data[idx] != end_char:
        # Base is always a new table because you are not parsing
        # something on multiline mode.
        var key_base = List[String]()

        _printif[log]("Parsing inline keys...")

        var keys_res = parse_keys[Equal ,log=log](data, idx, key_base^)
        if not keys_res:
            return keys_res^.unsafe_take_error()
        var keys = keys_res^.unsafe_take_value()



        _printif[log](t"inline keys -> '{",".join(keys)}'")
        idx += 1
        skip[Space, Tab](data, idx)

        if idx >= len(data):
            break

        var v_r = parse_value[end_char, log=log](data, idx)
        if not v_r:
            return v_r^.unsafe_take_error()
        var v = v_r^.unsafe_take_value()

        _printif[log](t"inline value -> '{v}'")
        _printif[log]("Getting container ref...")
        idx += 1

        var opt_error = set_key_value(keys, table, value=v^)
        if opt_error:
            return opt_error.unsafe_take()

        # var kk = StringSlice[mut=False](unsafe_from_utf8=keys[-1])
        _printif[log]("container found and data saved!")
        stop_at[separator, end_char](data, idx)
        _printif[log](t"Stopped at `{Codepoint(separator)}`, `{Codepoint(end_char)}` or EOF!")
        if idx >= len(data) or data[idx] == end_char:
            break
        _printif[log](t"Skipping `{Codepoint(separator)}` or stop at EOF...")
        # we are at separator
        skip[separator](data, idx)
        _printif[log]("Skip blanks and comments...")
        skip_blanks_and_comments(data, idx)
        _printif[log]("Parser keep going to next cycle...")
    # _ = get_container_ref[o = data.origin](keys, table, default=v^)

    _printif[log](t"Initial table finished! data is: {table}")
    return table^



@always_inline
def skip[*chars: Byte, log: Bool = False](data: Span[Byte, _], mut idx: Int):
    _printif[log](t"Starting skip of chars at: {idx}")
    while idx < len(data):
        comptime for c in chars:
            if data[idx] == c:
                idx += 1
                break
        else:
            return


def stop_at[*chars: Byte](data: Span[Byte, _], mut idx: Int):
    while idx < len(data):
        comptime for c in chars:
            if data[idx] == c:
                return

        idx += 1


@always_inline
def skip_blanks_and_comments[log: Bool = False](data: Span[Byte, _], mut idx: Int):
    _printif[log](t"Skip blanks and comments starting at: {idx}")
    while True:
        skip[NewLine, Enter, Space, Tab, log=log](data, idx)
        _printif[log](t"Done skipping space, enter, tab and newline... Checking if we are on a comment or we are out of idx. Curr idx: {idx}")
        if idx >= len(data) or data[idx] != Comment:
            return
        stop_at[NewLine](data, idx)


def parse_multiline_collections[log: Bool](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut base: Toml.Table,
) -> Optional[Error]:

    while idx < len(data):
        var is_array = data[idx + 1] == SquareBracketOpen
        idx += 1 + Int(is_array)

        skip[Space, Tab](data, idx)
        _printif[log](t"---------- multiline keys[{"array" if is_array else "table"}]------------:")
        var keys_res = parse_keys[SquareBracketClose, log=log](data, idx, {})
        _printif[log](t"Mutiline keys result: {keys_res}")
        if not keys_res:
            return keys_res^.unsafe_take_error()
        var keys = keys_res^.unsafe_take_value()

        _printif[log](("[[" if is_array else "[")+String(keys)+"]]" if is_array else "]",
                sep="",
            )
        _printif[log](t">> Remaining: '''{StringSlice(unsafe_from_utf8=data[idx:])}'''")
        _printif[log]("----------- multiline values -------------:")

        # In case you are on a list, just skip the second squarebracket close
        idx += 1 + Int(is_array)

        skip[Space](data,idx)
        if data[idx] != NewLine and data[idx] != Comment:
            return Error(t"Characters not commented after key. Found char: `{data[idx]}` as `{Codepoint(data[idx])}`. Remainging: {StringSlice(unsafe_from_utf8=data[idx:])}")

        stop_at[NewLine, SquareBracketOpen](data, idx)
        skip_blanks_and_comments(data, idx)
        _printif[log]("Key parsed sucessfully")

        var values_res = parse_kv_pairs[NewLine, SquareBracketOpen](
            data, idx
        )
        if not values_res:
            return values_res^.unsafe_take_error()
        var values = values_res^.unsafe_take_value()

        _printif[log](t"Multiline values: {values}")

        # comptime if log:
        #     print(
        #         {
        #             kv.key: String(toml.TomlType[
        #                 data.origin
        #             ]
        #             .from_addr(kv.value))
        #             for kv in values.items()
        #         }
        #     )
        # var def_cont: Toml
        var def_cont = Toml(Toml.Table(capacity=16))
        if is_array:
            # Store the default in na list
            def_cont = Toml(List([def_cont^]))

        _printif[log](t">> Getting container from ref: {keys}")
        var cont_res = get_table_ref(keys, base, default=def_cont^)
        if not cont_res:
            return cont_res^.unsafe_take_error()
        var cont = cont_res^.unsafe_take_value()

        if not cont[].isa[Toml.Table]():
            return Error("container should be a table, but inner value isn't")

        cont[].unsafe_ref[Toml.Table]().update(values^)
        _printif[log](t"Current base repr: {base}")

    return None


def parse_toml[
    *, log: Bool = False
](content: StringSlice) -> Result[Toml]:
    var data = content.as_bytes()
    _printif[log](t"\n\n~~~*** Starting new parse -- content: \n'''{content}'''" )

    var idx = 0
    skip_blanks_and_comments(data, idx)

    if idx >= len(data):
        _printif[log]("Empty table, just return an empty object.")
        return Toml(Toml.Table(capacity=0))

    _printif[log]("parsing initial kv pairs...")
    var base_res = parse_kv_pairs[NewLine, SquareBracketOpen, log=log](data, idx)
    if not base_res:
        return base_res^.unsafe_take_error()
    var base = base_res^.unsafe_take_value()

    _printif[log](t"end parsing initial kv pairs... Current idx: {idx}")

    var err_or_none = parse_multiline_collections[log](data, idx, base)
    if err_or_none:
        _printif[log](t"ERR IDENTIFIED {err_or_none}")
        return err_or_none.unsafe_take()

    _printif[log](t"done parsing toml!\nfinal data is: {base}")

    return Toml(base^)


def parse_toml_raises[
    *, log: Bool = False
](content: StringSlice) raises -> Toml:
    return parse_toml[log=log](content).take()


def toml_to_tagged_json[
    *, log: Bool = False
](content: StringSlice) raises -> String:
    var toml_values = parse_toml_raises[log=log](content)
    var out = String()
    toml_values.to_json(out)
    return out
