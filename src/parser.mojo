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


def _printif[
    log: Bool
](msg: Some[Writable], *, sep: StringSlice = " ", end: StringSlice = "\n"):
    if log:
        print(msg, sep=sep, end=end)


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
        return Error("Multiline not closed.")

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
        if data[idx] == NewLine or data[idx] == Enter:
            return Error("Newlines are not allowed in single-line strings.")
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


def parse_inline_array[
    log: Bool
](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut inline_table_paths: List[String],
    mut dotted_table_paths: List[String],
    prefix: String,
) -> Result[Toml.Array]:
    """Assumes the first char is already within the collection, but could be a space.
    """
    skip_blanks_and_comments(data, idx)

    # var value = toml.TomlType.new_array()
    var arr = Toml.Array(capacity=16)
    # ref arr = value[toml.TomlTypes.Array]

    while idx < len(data) and data[idx] != SquareBracketClose:
        _printif[log](
            t"parsing array value at idx: {idx} and span"
            t" `{StringSlice(unsafe_from_utf8=data[idx:min(idx + 30, len(data))])}`"
        )
        var arr_item = parse_value[Comma, log=log](
            data, idx, inline_table_paths, dotted_table_paths, prefix
        )
        _printif[log]("parse completed")
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

        if idx >= len(data) or data[idx] == SquareBracketClose:
            break
        if data[idx] != Comma:
            return Error("Expected a comma between array elements.")

        # we are at a comma
        idx += 1

        skip_blanks_and_comments(data, idx)

    if idx >= len(data):
        return Error("Array not closed.")

    return arr^


@always_inline
def is_value_terminator[end_char: Byte](data: Span[Byte, _], idx: Int) -> Bool:
    return (
        idx >= len(data)
        or data[idx] == end_char
        or data[idx] == SquareBracketClose
        or data[idx] == Comma
        or data[idx] == Comment
        or data[idx] == NewLine
        or data[idx] == Enter
        or data[idx] == Space
        or data[idx] == Tab
    )


def is_digit_for_base(char: Byte, base: Int) -> Bool:
    if Byte(ord("0")) <= char <= Byte(ord("9")):
        return Int(char) - Int(Byte(ord("0"))) < base
    if base == 16:
        return Byte(ord("a")) <= char <= Byte(ord("f")) or Byte(
            ord("A")
        ) <= char <= Byte(ord("F"))
    return False


def is_valid_digit_sequence(
    data: Span[Byte, _], start: Int, end: Int, base: Int
) -> Bool:
    if start >= end:
        return False
    var digit_count = 0
    var previous_was_digit = False
    for i in range(start, end):
        if data[i] == Byte(ord("_")):
            if (
                not previous_was_digit
                or i + 1 >= end
                or not is_digit_for_base(data[i + 1], base)
            ):
                return False
            previous_was_digit = False
        elif is_digit_for_base(data[i], base):
            digit_count += 1
            previous_was_digit = True
        else:
            return False
    return digit_count > 0 and previous_was_digit


def has_leading_zero(data: Span[Byte, _], start: Int, end: Int) -> Bool:
    var digit_count = 0
    var first_digit = Byte()
    for i in range(start, end):
        if data[i] != Byte(ord("_")):
            if digit_count == 0:
                first_digit = data[i]
            digit_count += 1
    return digit_count > 1 and first_digit == Byte(ord("0"))


def is_valid_integer(value: StringSlice) -> Bool:
    var data = value.as_bytes()
    if len(data) == 0:
        return False
    var start = 0
    if data[0] == Byte(ord("+")) or data[0] == Byte(ord("-")):
        start += 1
    if start >= len(data):
        return False

    if start == 0 and len(data) > 2 and data[0] == Byte(ord("0")):
        if data[1] == Byte(ord("x")):
            return is_valid_digit_sequence(data, 2, len(data), 16)
        if data[1] == Byte(ord("o")):
            return is_valid_digit_sequence(data, 2, len(data), 8)
        if data[1] == Byte(ord("b")):
            return is_valid_digit_sequence(data, 2, len(data), 2)

    return is_valid_digit_sequence(
        data, start, len(data), 10
    ) and not has_leading_zero(data, start, len(data))


def is_valid_float(value: StringSlice) -> Bool:
    var data = value.as_bytes()
    if len(data) == 0:
        return False
    var start = 0
    if data[0] == Byte(ord("+")) or data[0] == Byte(ord("-")):
        start += 1
    if start >= len(data):
        return False

    var exponent = -1
    for i in range(start, len(data)):
        if data[i] == Byte(ord("e")) or data[i] == Byte(ord("E")):
            if exponent != -1:
                return False
            exponent = i

    var mantissa_end = len(data) if exponent == -1 else exponent
    var dot = -1
    for i in range(start, mantissa_end):
        if data[i] == Byte(ord(".")):
            if dot != -1:
                return False
            dot = i

    if dot == -1:
        if exponent == -1:
            return False
        if not is_valid_digit_sequence(
            data, start, mantissa_end, 10
        ) or has_leading_zero(data, start, mantissa_end):
            return False
    elif (
        not is_valid_digit_sequence(data, start, dot, 10)
        or has_leading_zero(data, start, dot)
        or not is_valid_digit_sequence(data, dot + 1, mantissa_end, 10)
    ):
        return False

    if exponent != -1:
        var exponent_start = exponent + 1
        if exponent_start < len(data) and (
            data[exponent_start] == Byte(ord("+"))
            or data[exponent_start] == Byte(ord("-"))
        ):
            exponent_start += 1
        if not is_valid_digit_sequence(data, exponent_start, len(data), 10):
            return False

    return True


def string_to_type[
    end_char: Byte, *, log: Bool
](data: Span[mut=False, Byte, _], mut idx: Int) -> Result[Toml]:
    """Returns end of value + 1."""
    _printif[log](t"start parse at idx: {idx}")
    # comptime INT_AGG, DEC_AGG = 10.0, 0.1
    # comptime neg, pos = Byte(ord("-")), Byte(ord("+"))
    # var all_is_digit = True
    # var has_period = False
    var max_idx = len(data)
    if data[
        idx : min(idx + 4, max_idx)
    ] == "true".as_bytes() and is_value_terminator[end_char](data, idx + 4):
        idx += 3
        return Toml(True)

    elif data[
        idx : min(idx + 5, max_idx)
    ] == "false".as_bytes() and is_value_terminator[end_char](data, idx + 5):
        idx += 4
        return Toml(value=False)

    elif data[idx : min(idx + 3, max_idx)] == "nan".as_bytes():
        idx += 2
        return Toml(Toml.NaN())
    elif data[idx : min(idx + 4, max_idx)] == "+nan".as_bytes():
        idx += 3
        return Toml(Toml.NaN())
    elif data[idx : min(idx + 4, max_idx)] == "-nan".as_bytes():
        idx += 3
        return Toml(Toml.NaN())
    elif data[idx : min(idx + 3, max_idx)] == "inf".as_bytes():
        idx += 2
        return Toml(Float64.MAX)
    elif data[idx : min(idx + 4, max_idx)] == "+inf".as_bytes():
        idx += 3
        return Toml(Float64.MAX)
    elif data[idx : min(idx + 4, max_idx)] == "-inf".as_bytes():
        idx += 3
        return Toml(Float64.MIN)

    var v_init = idx

    comptime lower = Byte(ord("0"))
    comptime upper = Byte(ord("9"))

    comptime neg = Byte(ord("-"))

    var datetime_split: Int = -1
    var dashes: Int = 0
    var colons: Int = 0

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
        and data[idx] != SquareBracketClose
        and data[idx] != Comment
        and data[idx] != NewLine
        and data[idx] != Space
        and data[idx] != Comma
        and data[idx] != Tab
    ):
        dashes += Int(data[idx] == neg)
        colons += Int(data[idx] == Byte(ord(":")))

        idx += 1
        if (
            dashes > 0
            and idx < len(data)
            and data[idx] == Space
            and lower <= data[idx + 1] <= upper
        ):
            _printif[log]("the value is a date... dash exists")
            datetime_split = idx
            idx += 1

    var v_span = data[v_init:idx]
    var v_slice = StringSlice(unsafe_from_utf8=v_span)
    # Roll back one step because we finalized all time in the next item
    _printif[log=log](t"Value is: {v_slice}")

    idx -= 1
    if (
        dashes > 1
        and colons > 0
        and (
            datetime_split != -1
            or Byte(ord("T")) in v_span
            or Byte(ord("t")) in v_span
        )
    ):
        _printif[log]("parsing datetime")
        return Toml.DateTime.from_string(v_slice).map(as_toml[Toml.DateTime])

    elif dashes == 2 and len(v_span) == 10:
        _printif[log]("parsing date")
        return Toml.Date.from_string(v_slice).map(as_toml[Toml.Date])

    elif colons > 0:
        _printif[log]("psrgin time")
        return Toml.Time.from_string(v_slice).map(as_toml[Toml.Time])

    elif is_valid_integer(v_slice):
        _printif[log]("parsing int")
        var v = v_slice[
            byte = 2 if is_hex or is_bin or is_oct else 0 :
        ].replace("_", "")
        var base = 16 if is_hex else 8 if is_oct else 2 if is_bin else 10
        try:
            return Toml(atol(v, base=base))
        except e:
            return e^

    elif is_valid_float(v_slice):
        _printif[log]("try parse float")
        try:
            return Toml(atof(v_slice.replace("_", "")))
        except e:
            return e^

    return Error(t"Could not find a type for value: `{v_slice}`")


def calc_value[
    o: Origin, lit: Bool, multi: Bool, log: Bool
](var s: Span[Byte, o]) -> Result[String]:
    _printif[log](
        t"Codepoint to calc value is: `{StringSlice(unsafe_from_utf8=s)}`"
    )
    var sr = StringRef(s, literal=lit, multiline=multi).calc_value()
    # print(t"Value is: `{sr}`")
    return sr^


def as_toml[T: Movable](var s: T) -> Toml where Toml.AllTypes.contains[T]():
    return Toml(s^)


def parse_value[
    end_char: Byte, *, log: Bool
](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut inline_table_paths: List[String],
    mut dotted_table_paths: List[String],
    prefix: String,
) -> Result[Toml]:
    # Assumes the first char is the first value of the value to parse.
    if data[idx] == DoubleQuote:
        if data[idx + 1] == DoubleQuote and data[idx + 2] == DoubleQuote:
            _printif[log]("value is a triple double quote string")
            var s = parse_multiline_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            return s^.and_then(
                calc_value[data.origin, lit=False, multi=True, log=log]
            ).map(as_toml[String])

        else:
            _printif[log]("value is double quote string")
            var s = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            return s^.and_then(
                calc_value[data.origin, lit=False, multi=False, log=log]
            ).map(as_toml[String])

    elif data[idx] == SingleQuote:
        if data[idx + 1] == SingleQuote and data[idx + 2] == SingleQuote:
            _printif[log]("value is a triple single quote string")
            var s = parse_multiline_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return s^.and_then(
                calc_value[data.origin, lit=True, multi=True, log=log]
            ).map(as_toml[String])
        else:
            _printif[log]("value is single quote string")
            var s = parse_quoted_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return s^.and_then(
                calc_value[data.origin, lit=True, multi=False, log=log]
            ).map(as_toml[String])
    elif data[idx] == SquareBracketOpen:
        idx += 1
        _printif[log]("parsing inline array...")
        return parse_inline_array[log=log](
            data, idx, inline_table_paths, dotted_table_paths, prefix
        ).map(as_toml[Toml.Array])
    elif data[idx] == CurlyBracketOpen:
        idx += 1
        _printif[log]("parsing inline table...")
        skip_blanks_and_comments(data, idx)
        return parse_kv_pairs[separator=Comma, end_char=CurlyBracketClose](
            data, idx, inline_table_paths, dotted_table_paths, prefix
        ).map(as_toml[Toml.Table])
        # print("last multiline table codepoint parsed is:", Codepoint(data[idx]))
    else:
        return string_to_type[end_char, log=log](data, idx)


def get_table_ref[
    log: Bool = False
](
    keys: Span[String, _],
    mut base: Toml.Table,
    *,
    var default: Toml,  # it's the leaf. The last container
    array_table_paths: List[String],
    inline_table_paths: List[String],
) -> Result[Pointer[Toml, origin_of(base)]]:
    var cont = Pointer(to=base)
    for i, k in enumerate(keys[: len(keys) - 1]):
        var path = toml_key_path("", keys[: i + 1])
        if path in inline_table_paths:
            return Error("Inline tables cannot be extended.")
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
            var path = toml_key_path("", keys[: i + 1])
            if path not in array_table_paths:
                return Error("Cannot extend a table inside a static array.")
            cont = Pointer(
                to=inner_arr[len(inner_arr) - 1].unsafe_ref[Toml.Table]()
            ).unsafe_origin_cast[origin_of(base)]()
        elif inner_v.isa[Toml.Table]():
            cont = Pointer(
                to=inner_v.unsafe_ref[Toml.Table]()
            ).unsafe_origin_cast[origin_of(base)]()
        else:
            return Error("Toml type is not a container.")

    ref k = keys[len(keys) - 1]
    if toml_key_path("", keys) in inline_table_paths:
        return Error("Inline tables cannot be redefined.")
    var final_c: Pointer[Toml, origin_of(base)]
    if default.isa[Toml.Array]():
        var already_defined = k in cont[]
        final_c = Pointer(
            to=cont[].setdefault(k, Toml(Toml.Array(capacity=16)))
        ).unsafe_origin_cast[origin_of(base)]()
        if not final_c[].isa[Toml.Array]():
            return Error("Container should be an array, but it's not.")
        var path = toml_key_path("", keys)
        if path not in array_table_paths and already_defined:
            return Error(
                "Cannot define an array-of-tables over an existing array."
            )
        ref arr = final_c[].unsafe_ref[Toml.Array]()
        arr.extend(default^.unsafe_take[Toml.Array]())
        if len(arr) > 0:
            final_c = Pointer(to=arr[len(arr) - 1]).unsafe_origin_cast[
                origin_of(base)
            ]()

    else:
        final_c = Pointer(to=cont[].setdefault(k, default^)).unsafe_origin_cast[
            origin_of(base)
        ]()

    return final_c


def set_key_value[
    log: Bool = False
](
    keys: Span[String, _],
    mut base: Toml.Table,
    *,
    var value: Toml,
    inline_table_paths: List[String],
    prefix: String,
) -> Optional[Error]:
    var cont = Pointer(to=base)
    for i, k in enumerate(keys[: len(keys) - 1]):
        var path = toml_key_path(prefix, keys[: i + 1])
        if path in inline_table_paths:
            return Error("Inline tables cannot be extended.")
        _printif[log](t"|> k -> '{k}' ", end="")
        var default = Toml(Toml.Table(capacity=8))
        ref inner_v = cont[].setdefault(k, default^)
        if not inner_v.isa[Toml.Table]():
            return Error("Toml type is not a table container.")
        cont = Pointer(to=inner_v.unsafe_ref[Toml.Table]()).unsafe_origin_cast[
            origin_of(base)
        ]()

    ref k = keys[len(keys) - 1]
    if k in cont[]:
        return Error("ERROR: Table value already defined!")

    cont[][k] = value^

    return None


@always_inline
def is_bare_key_char(char: Byte) -> Bool:
    return (
        Byte(ord("a")) <= char <= Byte(ord("z"))
        or Byte(ord("A")) <= char <= Byte(ord("Z"))
        or Byte(ord("0")) <= char <= Byte(ord("9"))
        or char == Byte(ord("_"))
        or char == Byte(ord("-"))
    )


def toml_key_path(prefix: String, keys: Span[String, _]) -> String:
    var path = String(prefix)
    for key in keys:
        path += String(t"{key.byte_length()}:{key};")
    return path


def table_scope_prefix(
    keys: Span[String, _],
    array_table_paths: List[String],
    array_table_occurrences: List[String],
    include_full_path: Bool = False,
) -> String:
    var scope = String()
    for i in range(1, len(keys) + Int(include_full_path)):
        var array_path = toml_key_path("", keys[:i])
        if array_path not in array_table_paths and not (
            include_full_path and i == len(keys)
        ):
            continue
        var occurrence = 0
        for seen_path in array_table_occurrences:
            occurrence += Int(seen_path == array_path)
        scope += String(t"@{array_path}={occurrence};")
    return scope + toml_key_path("", keys)


def parse_keys[
    o: ImmOrigin, //, close_char: Byte, *, log: Bool
](data: Span[Byte, o], mut idx: Int, var key_base: List[String]) -> Result[
    List[String]
]:
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
    var bare_key_started = False

    _printif[log](t"Len data is: {len(data)} and curr idx is: {idx}")
    while idx < len(data) and data[idx] != close_char:
        var chr = data[idx]
        _printif[log](Codepoint(chr))
        if chr == SquareBracketOpen:
            return Error("Invalid key Definition: key opened twice.")
        elif chr != Space and chr != Tab and chr != Period and key:
            return Error("Invalid Key Definition: Key is not closed.")
        elif chr == SingleQuote:
            if bare_key_started:
                return Error("Bare and quoted key segments cannot be combined.")
            var quoted = parse_quoted_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            if not quoted:
                return quoted^.unsafe_take_error()
            var quoted_span = quoted^.unsafe_take_value()
            if NewLine in quoted_span or Enter in quoted_span:
                return Error("Newlines are not allowed in quoted keys.")
            key = calc_value[o, lit=True, multi=False, log=log](
                quoted_span
            ).as_optional()
            idx += 1
            continue
        elif chr == DoubleQuote:
            if bare_key_started:
                return Error("Bare and quoted key segments cannot be combined.")
            var quoted = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            if not quoted:
                return quoted^.unsafe_take_error()
            var quoted_span = quoted^.unsafe_take_value()
            if NewLine in quoted_span or Enter in quoted_span:
                return Error("Newlines are not allowed in quoted keys.")
            key = calc_value[o, lit=False, multi=False, log=log](
                quoted_span
            ).as_optional()
            # var is_literal = Escape not in k
            idx += 1
            continue
        elif not key and (chr == Space or chr == Tab):
            if idx == key_init:
                return Error("A bare key cannot be empty.")
            var k = data[key_init:idx]
            key = (
                StringRef(k, literal=False, multiline=False)
                .calc_value()
                .as_optional()
            )
            skip[Space, Tab](data, idx)
            continue
        elif chr == Period:
            if not key:
                if idx == key_init:
                    return Error("A dotted key segment cannot be empty.")
                key = (
                    StringRef(
                        data[key_init:idx], literal=False, multiline=False
                    )
                    .calc_value()
                    .as_optional()
                )

            # store the next level in the key_base list
            key_base.append(key.take())
            # skip dot
            idx += 1
            if (
                idx >= len(data)
                or data[idx] == close_char
                or data[idx] == Period
            ):
                return Error(
                    "Error while creating nested table. No key defined after"
                    " dot."
                )
            # Skip any space between parsed element and next key
            skip[Space, Tab](data, idx)
            # Return the inner element?
            return parse_keys[close_char, log=log](data, idx, key_base^)
        elif chr == Byte(ord("#")):
            return Error("Comment found in middle of key")
        # elif key and chr == Equal:
        #     return Error("Assignment in middle of key definition.")
        elif not key and not is_bare_key_char(chr):
            return Error("Invalid character in bare key.")
        elif not key:
            bare_key_started = True
        idx += 1

    # _printif[log](t"Len data is: {len(data)} and curr idx is: {idx}")
    if idx == len(data) or idx > len(data):
        return Error("Key not closed.")

    if not key:
        if idx == key_init:
            return Error("A bare key cannot be empty.")
        key = (
            StringRef(data[key_init:idx], literal=False, multiline=False)
            .calc_value()
            .as_optional()
        )

    var k = key.take()
    key_base.append(k)
    _printif[log](t"!- Parsed key base: {key_base}")
    return key_base^


def parse_kv_pairs[
    separator: Byte,
    end_char: Byte,
    log: Bool = False,
](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut inline_table_paths: List[String],
    mut dotted_table_paths: List[String],
    prefix: String,
) -> Result[Toml.Table]:
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

        var keys_res = parse_keys[Equal, log=log](data, idx, key_base^)
        if not keys_res:
            return keys_res^.unsafe_take_error()
        var keys = keys_res^.unsafe_take_value()

        _printif[log](t"inline keys -> '{",".join(keys)}'")
        idx += 1
        skip[Space, Tab](data, idx)

        if idx >= len(data):
            break

        var value_path = toml_key_path(prefix, keys)
        for i in range(1, len(keys)):
            var implicit_path = toml_key_path(prefix, keys[:i])
            if implicit_path not in dotted_table_paths:
                dotted_table_paths.append(implicit_path)
        var v_r = parse_value[end_char, log=log](
            data, idx, inline_table_paths, dotted_table_paths, value_path
        )
        if not v_r:
            return v_r^.unsafe_take_error()
        var v = v_r^.unsafe_take_value()

        _printif[log](t"inline value -> '{v}'")
        _printif[log]("Getting container ref...")
        idx += 1

        if v.isa[Toml.Table]() and value_path not in inline_table_paths:
            inline_table_paths.append(value_path)

        var opt_error = set_key_value(
            keys,
            table,
            value=v^,
            inline_table_paths=inline_table_paths,
            prefix=prefix,
        )
        if opt_error:
            return opt_error.unsafe_take()

        # var kk = StringSlice[mut=False](unsafe_from_utf8=keys[-1])
        _printif[log]("container found and data saved!")
        comptime if separator == NewLine:
            skip[Space, Tab](data, idx)
            if idx < len(data) and data[idx] == Comment:
                stop_at[NewLine](data, idx)
            if idx >= len(data):
                break
            if data[idx] == Enter:
                idx += 1
            if data[idx] != NewLine:
                return Error("Unexpected characters after TOML value.")
            idx += 1
            skip_blanks_and_comments(data, idx)
        elif separator == Comma:
            skip_blanks_and_comments(data, idx)
            if idx >= len(data) or data[idx] == end_char:
                break
            if data[idx] != separator:
                return Error("Expected a comma between inline table entries.")
            idx += 1
            skip_blanks_and_comments(data, idx)
        else:
            stop_at[separator, end_char](data, idx)
            _printif[log](
                t"Stopped at `{Codepoint(separator)}`, `{Codepoint(end_char)}`"
                t" or EOF!"
            )
            if idx >= len(data) or data[idx] == end_char:
                break
            _printif[log](
                t"Skipping `{Codepoint(separator)}` or stop at EOF..."
            )
            # we are at separator
            skip[separator](data, idx)
            _printif[log]("Skip blanks and comments...")
            skip_blanks_and_comments(data, idx)
        _printif[log]("Parser keep going to next cycle...")
    # _ = get_container_ref[o = data.origin](keys, table, default=v^)

    if idx >= len(data) and end_char == CurlyBracketClose:
        return Error("Inline table not closed.")

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
def skip_blanks_and_comments[
    log: Bool = False
](data: Span[Byte, _], mut idx: Int):
    _printif[log](t"Skip blanks and comments starting at: {idx}")
    while True:
        skip[NewLine, Enter, Space, Tab, log=log](data, idx)
        _printif[log](
            t"Done skipping space, enter, tab and newline... Checking if we are"
            t" on a comment or we are out of idx. Curr idx: {idx}"
        )
        if idx >= len(data) or data[idx] != Comment:
            return
        stop_at[NewLine](data, idx)


def parse_multiline_collections[
    log: Bool
](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut base: Toml.Table,
    mut inline_table_paths: List[String],
    mut dotted_table_paths: List[String],
    mut declared_table_paths: List[String],
) -> Optional[Error]:
    var array_table_paths = List[String]()
    var array_table_occurrences = List[String]()
    while idx < len(data):
        var is_array = data[idx + 1] == SquareBracketOpen
        idx += 1 + Int(is_array)

        skip[Space, Tab](data, idx)
        _printif[log](
            t"---------- multiline"
            t' keys[{"array" if is_array else "table"}]------------:'
        )
        var keys_res = parse_keys[SquareBracketClose, log=log](data, idx, {})
        _printif[log](t"Mutiline keys result: {keys_res}")
        if not keys_res:
            return keys_res^.unsafe_take_error()
        var keys = keys_res^.unsafe_take_value()
        var table_path = toml_key_path("", keys)
        if is_array:
            array_table_occurrences.append(table_path)
        var scoped_table_path = table_scope_prefix(
            keys, array_table_paths, array_table_occurrences, is_array
        )

        _printif[log](
            ("[[" if is_array else "[")
            + String(keys)
            + "]]" if is_array else "]",
            sep="",
        )
        _printif[log](
            t">> Remaining: '''{StringSlice(unsafe_from_utf8=data[idx:])}'''"
        )
        _printif[log]("----------- multiline values -------------:")

        # In case you are on a list, just skip the second squarebracket close
        idx += 1 + Int(is_array)

        skip[Space, Tab](data, idx)
        if idx < len(data) and data[idx] == Comment:
            stop_at[NewLine](data, idx)
        if idx < len(data) and data[idx] == Enter:
            idx += 1
            if idx >= len(data) or data[idx] != NewLine:
                return Error("Carriage return must be followed by line feed.")
        if idx < len(data) and data[idx] == NewLine:
            idx += 1
        elif idx < len(data):
            return Error(
                t"Characters not commented after key. Found char: `{data[idx]}`"
                t" as `{Codepoint(data[idx])}`. Remainging:"
                t" {StringSlice(unsafe_from_utf8=data[idx:])}"
            )

        skip_blanks_and_comments(data, idx)
        _printif[log]("Key parsed sucessfully")

        var values_res = parse_kv_pairs[NewLine, SquareBracketOpen](
            data,
            idx,
            inline_table_paths,
            dotted_table_paths,
            scoped_table_path,
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

        if scoped_table_path in dotted_table_paths:
            return Error("A dotted-key table cannot be redefined.")
        if not is_array and scoped_table_path in declared_table_paths:
            return Error("Table has already been defined.")

        _printif[log](t">> Getting container from ref: {keys}")
        var cont_res = get_table_ref(
            keys,
            base,
            default=def_cont^,
            array_table_paths=array_table_paths,
            inline_table_paths=inline_table_paths,
        )
        if not cont_res:
            return cont_res^.unsafe_take_error()
        var cont = cont_res^.unsafe_take_value()

        if not cont[].isa[Toml.Table]():
            return Error("container should be a table, but inner value isn't")

        if is_array:
            if table_path not in array_table_paths:
                array_table_paths.append(table_path)
        elif scoped_table_path not in declared_table_paths:
            declared_table_paths.append(scoped_table_path)

        for kv in values.items():
            if kv.key in cont[].unsafe_ref[Toml.Table]():
                return Error(t"Table key already defined: {kv.key}")

        cont[].unsafe_ref[Toml.Table]().update(values^)
        _printif[log](t"Current base repr: {base}")

    return None


def validate_control_characters(data: Span[Byte, _]) -> Optional[Error]:
    for i in range(len(data)):
        var char = data[i]
        if char == Tab or char == NewLine:
            continue
        if char == Enter:
            if i + 1 < len(data) and data[i + 1] == NewLine:
                continue
            return Error("Carriage return must be followed by line feed.")
        if char < Byte(0x20) or char == Byte(0x7F):
            return Error("Invalid control character in TOML document.")
    return None


def parse_toml[*, log: Bool = False](content: StringSlice) -> Result[Toml]:
    var data = content.as_bytes()
    _printif[log](
        t"\n\n~~~*** Starting new parse -- content: \n'''{content}'''"
    )

    var control_error = validate_control_characters(data)
    if control_error:
        return control_error.unsafe_take()

    var idx = 0
    var inline_table_paths = List[String]()
    var dotted_table_paths = List[String]()
    var declared_table_paths = List[String]()
    skip_blanks_and_comments(data, idx)

    if idx >= len(data):
        _printif[log]("Empty table, just return an empty object.")
        return Toml(Toml.Table(capacity=0))

    _printif[log]("parsing initial kv pairs...")
    var base_res = parse_kv_pairs[NewLine, SquareBracketOpen, log=log](
        data, idx, inline_table_paths, dotted_table_paths, ""
    )
    if not base_res:
        return base_res^.unsafe_take_error()
    var base = base_res^.unsafe_take_value()

    _printif[log](t"end parsing initial kv pairs... Current idx: {idx}")

    var err_or_none = parse_multiline_collections[log](
        data,
        idx,
        base,
        inline_table_paths,
        dotted_table_paths,
        declared_table_paths,
    )
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
