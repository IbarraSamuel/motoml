"""
Rules:
Dotted keys, can create a dictionary grouping the values.
"""

from .result import Result
from .types.toml import Toml
from .types.string_ref import StringRef
from .mmap_file import MappedFile
from std.collections.string._utf8 import _is_valid_utf8
from std.memory import forget_deinit
from std.collections import Set

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
        return .Err("Multiline not closed.")

    # move two if there is a end like: """""
    # comptime if ignore_escape:
    #     return data[value_init : idx - 2]

    if len(data) > idx + 1 and data[idx + 1] == quote_type:
        idx += 1
    if len(data) > idx + 1 and data[idx + 1] == quote_type:
        idx += 1
    # When it stopped, the value already have two quotes, remove them from value
    return .Ok(data[value_init : idx - 2])


def parse_quoted_string[
    quote_type: Byte, *, ignore_escape: Bool
](data: Span[Byte, _], mut idx: Int) -> Result[Span[Byte, data.origin]]:
    idx += 1
    var value_init = idx
    if idx >= len(data):
        return .Err("String not closed.")

    while data[idx] != quote_type:
        if data[idx] == NewLine or data[idx] == Enter:
            return .Err("Newlines are not allowed in single-line strings.")
        idx += 1

        if idx >= len(data):
            return .Err("String not closed.")

        comptime if not ignore_escape:
            if data[idx] == quote_type:
                var n_esc = 0
                while data[idx - n_esc - 1] == Escape:
                    n_esc += 1

                if n_esc % 2 != 0:
                    idx += 1

    return .Ok(data[value_init:idx])


def parse_inline_array[
    log: Bool
](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut inline_table_paths: Set[String],
    mut dotted_table_paths: Set[String],
    prefix: String,
) -> Result[List[Toml]]:
    """Assumes the first char is already within the collection, but could be a space.
    """
    skip_blanks_and_comments(data, idx)

    # var value = toml.TomlType.new_array()
    var arr = List[Toml](capacity=4)
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
        if case .Err = arr_item:
            return .Err(arr_item^.unsafe_take_error())
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
            return .Err("Expected a comma between array elements.")

        # we are at a comma
        idx += 1

        skip_blanks_and_comments(data, idx)

    if idx >= len(data):
        return .Err("Array not closed.")

    return .Ok(arr^)


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


@always_inline
def is_digit_for_base(char: Byte, base: Int) -> Bool:
    if Byte(ord("0")) <= char <= Byte(ord("9")):
        return Int(char) - Int(Byte(ord("0"))) < base
    if base == 16:
        return Byte(ord("a")) <= char <= Byte(ord("f")) or Byte(
            ord("A")
        ) <= char <= Byte(ord("F"))
    return False


def is_valid_digit_sequence[
    *, reject_leading_zero: Bool = False
](data: Span[Byte, _], start: Int, end: Int, base: Int) -> Bool:
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
    return (
        digit_count > 0
        and previous_was_digit
        and (
            not reject_leading_zero
            or digit_count == 1
            or data[start] != Byte(ord("0"))
        )
    )


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

    return is_valid_digit_sequence[reject_leading_zero=True](
        data, start, len(data), 10
    )


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
        if not is_valid_digit_sequence[reject_leading_zero=True](
            data, start, mantissa_end, 10
        ):
            return False
    elif not is_valid_digit_sequence[reject_leading_zero=True](
        data, start, dot, 10
    ) or not is_valid_digit_sequence(data, dot + 1, mantissa_end, 10):
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
    if data[idx] == Byte(ord("t")):
        if (
            idx + 4 <= max_idx
            and data[idx : idx + 4] == "true".as_bytes()
            and is_value_terminator[end_char](data, idx + 4)
        ):
            idx += 3
            return .Ok(Toml.Boolean(True))
    elif data[idx] == Byte(ord("f")):
        if (
            idx + 5 <= max_idx
            and data[idx : idx + 5] == "false".as_bytes()
            and is_value_terminator[end_char](data, idx + 5)
        ):
            idx += 4
            return .Ok(Toml.Boolean(False))
    elif data[idx] == Byte(ord("n")):
        if idx + 3 <= max_idx and data[idx : idx + 3] == "nan".as_bytes():
            idx += 2
            return .Ok(materialize[Toml.NaN]())
    elif data[idx] == Byte(ord("i")):
        if idx + 3 <= max_idx and data[idx : idx + 3] == "inf".as_bytes():
            idx += 2
            return .Ok(Toml.Float(Float64.MAX))
    elif data[idx] == Byte(ord("+")) or data[idx] == Byte(ord("-")):
        if idx + 4 <= max_idx:
            var special_value = data[idx + 1 : idx + 4]
            if special_value == "nan".as_bytes():
                idx += 3
                return .Ok(materialize[Toml.NaN]())
            elif special_value == "inf".as_bytes():
                var is_negative = data[idx] == Byte(ord("-"))
                idx += 3
                return .Ok(
                    Toml.Float(Float64.MIN) if is_negative else Toml.Float(
                        Float64.MAX
                    )
                )

    var v_init = idx

    comptime lower = Byte(ord("0"))
    comptime upper = Byte(ord("9"))

    comptime neg = Byte(ord("-"))

    var datetime_split: Int = -1
    var dashes: Int = 0
    var colons: Int = 0

    var has_prefix = data[idx] == lower and idx + 1 < max_idx
    var is_hex = has_prefix and (
        data[idx + 1] == Byte(ord("x")) or data[idx + 1] == Byte(ord("X"))
    )
    var is_bin = has_prefix and (
        data[idx + 1] == Byte(ord("b")) or data[idx + 1] == Byte(ord("B"))
    )
    var is_oct = has_prefix and (
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
            and idx + 1 < len(data)
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
        return Toml.Types.DateTime.from_string(v_slice).map(
            lambda (dt: Toml.Types.DateTime) -> Toml: Toml.DateTime(dt)
        )

    elif dashes == 2 and len(v_span) == 10:
        _printif[log]("parsing date")
        return Toml.Types.Date.from_string(v_slice).map(
            lambda (d: Toml.Types.Date) -> Toml: Toml.Date(d)
        )

    elif colons > 0:
        _printif[log]("parsing time")
        return Toml.Types.Time.from_string(v_slice).map(
            lambda (t: Toml.Types.Time) -> Toml: Toml.Time(t)
        )

    elif is_valid_integer(v_slice):
        _printif[log]("parsing int")
        var digits = v_slice[byte = 2 if is_hex or is_bin or is_oct else 0 :]
        var base = 16 if is_hex else 8 if is_oct else 2 if is_bin else 10
        try:
            # Only allocate a cleaned copy when there are separators to strip.
            if Byte(ord("_")) in v_span:
                return .Ok(
                    Toml.Integer(atol(digits.replace("_", ""), base=base))
                )
            return .Ok(Toml.Integer(atol(digits, base=base)))
        except e:
            return .Err(e^)

    elif is_valid_float(v_slice):
        _printif[log]("try parse float")
        try:
            if Byte(ord("_")) in v_span:
                return .Ok(Toml.Float(atof(v_slice.replace("_", ""))))
            return .Ok(Toml.Float(atof(v_slice)))
        except e:
            return .Err(e^)

    return .Err(t"Could not find a type for value: `{v_slice}`")


def calc_value[
    o: Origin, lit: Bool, multi: Bool, log: Bool
](var s: Span[Byte, o]) -> Result[String]:
    _printif[log](
        t"Codepoint to calc value is: `{StringSlice(unsafe_from_utf8=s)}`"
    )
    var sr = StringRef(s, literal=lit, multiline=multi).calc_value()
    # print(t"Value is: `{sr}`")
    return sr^


def parse_value[
    end_char: Byte, *, log: Bool
](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut inline_table_paths: Set[String],
    mut dotted_table_paths: Set[String],
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
            ).map(lambda (v: String) -> Toml: Toml.String(v))

        else:
            _printif[log]("value is double quote string")
            var s = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            return s^.and_then(
                calc_value[data.origin, lit=False, multi=False, log=log]
            ).map(lambda (v: String) -> Toml: Toml.String(v))

    elif data[idx] == SingleQuote:
        if data[idx + 1] == SingleQuote and data[idx + 2] == SingleQuote:
            _printif[log]("value is a triple single quote string")
            var s = parse_multiline_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return s^.and_then(
                calc_value[data.origin, lit=True, multi=True, log=log]
            ).map(lambda (v: String) -> Toml: Toml.String(v))
        else:
            _printif[log]("value is single quote string")
            var s = parse_quoted_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return s^.and_then(
                calc_value[data.origin, lit=True, multi=False, log=log]
            ).map(lambda (v: String) -> Toml: Toml.String(v))
    elif data[idx] == SquareBracketOpen:
        idx += 1
        _printif[log]("parsing inline array...")
        return parse_inline_array[log=log](
            data, idx, inline_table_paths, dotted_table_paths, prefix
        ).map(lambda (var v: List[Toml]) -> Toml: Toml.Array(v^))
    elif data[idx] == CurlyBracketOpen:
        idx += 1
        _printif[log]("parsing inline table...")
        skip_blanks_and_comments(data, idx)
        return parse_kv_pairs[separator=Comma, end_char=CurlyBracketClose](
            data, idx, inline_table_paths, dotted_table_paths, prefix
        ).map(lambda (var v: Dict[String, Toml]) -> Toml: Toml.Table(v^))
        # print("last multiline table codepoint parsed is:", Codepoint(data[idx]))
    else:
        return string_to_type[end_char, log=log](data, idx)


def unsafe_get(ref dict: Dict, k: type_of(dict).K) -> ref[dict] type_of(dict).V:
    var h = hash[type_of(dict).H](k)
    var (_, idx) = dict._table.find_slot(h, k)
    return dict._table._slots.unsafe_offset(idx)[].value


def get_table_ref[
    log: Bool = False
](
    keys: Span[String, _],
    mut base: Dict[String, Toml],
    *,
    var default: Toml,  # it's the leaf. The last container
    array_table_paths: Set[String],
    inline_table_paths: Set[String],
) -> Result[Pointer[Toml, origin_of(base)]]:
    var cont = Pointer(to=base)
    # Built incrementally: O(total key bytes) instead of O(keys^2).
    var key_path = String()
    for k in keys[: len(keys) - 1]:
        _push_key_segment(key_path, k)
        if key_path in inline_table_paths:
            return .Err("Inline tables cannot be extended.")
        _printif[log](
            t"|> k -> '{k}' ",
            end="",
        )

        # Only allocate the intermediate table when it is really missing.
        if k not in cont[]:
            cont[][k] = Toml.Table(Dict[String, Toml]())
        ref inner_v = unsafe_get(cont[], k)
        match inner_v:
            case .Array:
                ref inner_arr = inner_v[List[Toml]]
                if len(inner_arr) == 0:
                    inner_arr.append(
                        Toml.Table(Dict[String, Toml](capacity=16))
                    )

                if key_path not in array_table_paths:
                    return .Err("Cannot extend a table inside a static array.")
                if case .Table = inner_arr[len(inner_arr) - 1]:
                    ref tb = inner_arr[len(inner_arr) - 1][Dict[String, Toml]]
                    cont = Pointer(to=tb).unsafe_origin_cast[origin_of(base)]()
                else:
                    return .Err("Array should contain tables, but it doesn't.")

            case .Table:
                cont = Pointer(
                    to=inner_v[Dict[String, Toml]]
                ).unsafe_origin_cast[origin_of(base)]()
            case _:
                return .Err("Toml type is not a container.")

    ref k = keys[len(keys) - 1]
    # key_path now holds the full path; reuse it instead of rebuilding it.
    _push_key_segment(key_path, k)
    if key_path in inline_table_paths:
        return .Err("Inline tables cannot be redefined.")

    var final_c: Pointer[Toml, origin_of(base)]
    if case .Array = default:
        var already_defined = k in cont[]
        if not already_defined:
            cont[][k] = Toml.Array(List[Toml](capacity=4))
        ref v = unsafe_get(cont[], k)
        final_c = Pointer(to=v).unsafe_origin_cast[origin_of(base)]()

        if key_path not in array_table_paths and already_defined:
            return .Err(
                "Cannot define an array-of-tables over an existing array."
            )

        if case .Array = final_c[]:
            ref arr = final_c[][List[Toml]]
            if case .Array = default:
                arr.extend(default^.unsafe_take[List[Toml]]())
            else:
                return .Err("Default value should be an array, but it's not.")

            if len(arr) > 0:
                final_c = Pointer(to=arr[len(arr) - 1]).unsafe_origin_cast[
                    origin_of(base)
                ]()
        else:
            return .Err("Container should be an array, but it's not.")

    else:
        final_c = Pointer(to=cont[].setdefault(k, default^)).unsafe_origin_cast[
            origin_of(base)
        ]()

    return .Ok(final_c)


def set_key_value[
    log: Bool = False
](
    keys: Span[String, _],
    mut base: Dict[String, Toml],
    *,
    var value: Toml,
    inline_table_paths: Set[String],
    prefix: String,
) -> Optional[Error]:
    var cont = Pointer(to=base)
    var key_path = String(prefix)
    for k in keys[: len(keys) - 1]:
        _push_key_segment(key_path, k)
        if key_path in inline_table_paths:
            return Error("Inline tables cannot be extended.")
        _printif[log](t"|> k -> '{k}' ", end="")
        # Only allocate the intermediate table when it is really missing.
        if k not in cont[]:
            cont[][k] = Toml.Table(Dict[String, Toml]())
        ref inner_v = unsafe_get(cont[], k)
        if case .Table = inner_v:
            ref tb = inner_v[Dict[String, Toml]]
            cont = Pointer(to=tb).unsafe_origin_cast[origin_of(base)]()
        else:
            return Error("Toml type is not a table container.")

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


@always_inline
def _push_key_segment(mut path: String, key: String):
    path += String(t"{key.byte_length()}:{key};")


def toml_key_path(prefix: String, keys: Span[String, _]) -> String:
    var path = String(prefix)
    for key in keys:
        _push_key_segment(path, key)
    return path


def table_scope_prefix(
    keys: Span[String, _],
    array_table_paths: Set[String],
    array_table_occurrences: Dict[String, Int],
    include_full_path: Bool = False,
) -> String:
    var scope = String()
    # Holds keys[:i] at iteration i, built incrementally.
    var path = String()
    for i in range(1, len(keys) + Int(include_full_path)):
        _push_key_segment(path, keys[i - 1])
        if path not in array_table_paths and not (
            include_full_path and i == len(keys)
        ):
            continue
        var occurrence = array_table_occurrences.get(path, 0)
        scope += String(t"@{path}={occurrence};")
    return scope + toml_key_path("", keys)


@always_inline
def _bare_key(span: Span[Byte, _]) -> Optional[String]:
    # Bare keys were already validated byte-by-byte as [A-Za-z0-9_-], so they
    # never contain anything calc_value() would need to process or escape.
    return String(StringSlice(unsafe_from_utf8=span))


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
            return .Err("Invalid key Definition: key opened twice.")
        elif chr != Space and chr != Tab and chr != Period and key:
            return .Err("Invalid Key Definition: Key is not closed.")
        elif chr == SingleQuote:
            if bare_key_started:
                return .Err("Bare and quoted key segments cannot be combined.")
            var quoted = parse_quoted_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            if case .Err = quoted:
                return .Err(quoted^.unsafe_take_error())
            var quoted_span = quoted^.unsafe_take_value()
            if NewLine in quoted_span or Enter in quoted_span:
                return .Err("Newlines are not allowed in quoted keys.")
            key = calc_value[o, lit=True, multi=False, log=log](
                quoted_span
            ).as_optional()
            idx += 1
            continue
        elif chr == DoubleQuote:
            if bare_key_started:
                return .Err("Bare and quoted key segments cannot be combined.")
            var quoted = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            if case .Err = quoted:
                return .Err(quoted^.unsafe_take_error())
            var quoted_span = quoted^.unsafe_take_value()
            if NewLine in quoted_span or Enter in quoted_span:
                return .Err("Newlines are not allowed in quoted keys.")
            key = calc_value[o, lit=False, multi=False, log=log](
                quoted_span
            ).as_optional()
            # var is_literal = Escape not in k
            idx += 1
            continue
        elif not key and (chr == Space or chr == Tab):
            if idx == key_init:
                return .Err("A bare key cannot be empty.")
            key = _bare_key(data[key_init:idx])
            skip[Space, Tab](data, idx)
            continue
        elif chr == Period:
            if not key:
                if idx == key_init:
                    return .Err("A dotted key segment cannot be empty.")
                key = _bare_key(data[key_init:idx])

            # store the next level in the key_base list
            key_base.append(key.take())
            # skip dot
            idx += 1
            if (
                idx >= len(data)
                or data[idx] == close_char
                or data[idx] == Period
            ):
                return .Err(
                    "Error while creating nested table. No key defined after"
                    " dot."
                )
            # Skip any space between parsed element and next key
            skip[Space, Tab](data, idx)
            # Return the inner element?
            return parse_keys[close_char, log=log](data, idx, key_base^)
        elif chr == Byte(ord("#")):
            return .Err("Comment found in middle of key")
        # elif key and chr == Equal:
        #     return Error("Assignment in middle of key definition.")
        elif not key and not is_bare_key_char(chr):
            return .Err("Invalid character in bare key.")
        elif not key:
            bare_key_started = True
        idx += 1

    # _printif[log](t"Len data is: {len(data)} and curr idx is: {idx}")
    if idx == len(data) or idx > len(data):
        return .Err("Key not closed.")

    if not key:
        if idx == key_init:
            return .Err("A bare key cannot be empty.")
        key = _bare_key(data[key_init:idx])

    var k = key.take()
    key_base.append(k)
    _printif[log](t"!- Parsed key base: {key_base}")
    return .Ok(key_base^)


def parse_kv_pairs[
    separator: Byte,
    end_char: Byte,
    log: Bool = False,
](
    data: Span[mut=False, Byte, _],
    mut idx: Int,
    mut inline_table_paths: Set[String],
    mut dotted_table_paths: Set[String],
    prefix: String,
) -> Result[Dict[String, Toml]]:
    """This function expect to be on top of the value to start parsing. So item=1.
    End at the last value + 1.
    """

    _printif[log]("++ kcreate new empty table container")
    var table = Dict[String, Toml](capacity=16)
    while idx < len(data) and data[idx] != end_char:
        # Base is always a new table because you are not parsing
        # something on multiline mode.
        var key_base = List[String]()

        _printif[log]("Parsing inline keys...")

        var keys_res = parse_keys[Equal, log=log](data, idx, key_base^)
        if case .Err = keys_res:
            return .Err(keys_res^.unsafe_take_error())
        var keys = keys_res^.unsafe_take_value()

        comptime if log:
            _printif[log](t"inline keys -> '{",".join(keys)}'")
        idx += 1
        skip[Space, Tab](data, idx)

        if idx >= len(data):
            break

        # The path is only consumed by arrays / inline tables, so skip building
        # it for scalar values (the vast majority of key/value pairs).
        var value_path = String()
        if data[idx] == CurlyBracketOpen or data[idx] == SquareBracketOpen:
            value_path = toml_key_path(prefix, keys)
        if len(keys) > 1:
            var implicit_path = String(prefix)
            for i in range(len(keys) - 1):
                _push_key_segment(implicit_path, keys[i])
                dotted_table_paths.add(implicit_path)
        var v_r = parse_value[end_char, log=log](
            data, idx, inline_table_paths, dotted_table_paths, value_path
        )
        if case .Err = v_r:
            return .Err(v_r^.unsafe_take_error())
        var v = v_r^.unsafe_take_value()

        _printif[log](t"inline value -> '{v}'")
        _printif[log]("Getting container ref...")
        idx += 1

        if case .Table = v:
            inline_table_paths.add(value_path)

        var opt_error = set_key_value(
            keys,
            table,
            value=v^,
            inline_table_paths=inline_table_paths,
            prefix=prefix,
        )
        if opt_error:
            return .Err(opt_error.unsafe_take())

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
                return .Err("Unexpected characters after TOML value.")
            idx += 1
            skip_blanks_and_comments(data, idx)
        elif separator == Comma:
            skip_blanks_and_comments(data, idx)
            if idx >= len(data) or data[idx] == end_char:
                break
            if data[idx] != separator:
                return .Err("Expected a comma between inline table entries.")
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
        return .Err("Inline table not closed.")

    # _printif[log](t"Initial table finished! data is: {table}")
    return .Ok(table^)


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
    mut base: Dict[String, Toml],
    mut inline_table_paths: Set[String],
    mut dotted_table_paths: Set[String],
    mut declared_table_paths: Set[String],
) -> Optional[Error]:
    var array_table_paths = Set[String]()
    var array_table_occurrences = Dict[String, Int]()
    while idx < len(data):
        var is_array = (
            idx + 1 < len(data) and data[idx + 1] == SquareBracketOpen
        )
        idx += 1 + Int(is_array)

        skip[Space, Tab](data, idx)
        _printif[log](
            t"---------- multiline"
            t' keys[{"array" if is_array else "table"}]------------:'
        )
        var keys_res = parse_keys[SquareBracketClose, log=log](data, idx, {})
        if case .Err = keys_res:
            return keys_res^.unsafe_take_error()
        var keys = keys_res^.unsafe_take_value()
        _printif[log](t"Mutiline keys result: {keys}")
        var table_path = toml_key_path("", keys)
        if is_array:
            array_table_occurrences[table_path] = (
                array_table_occurrences.get(table_path, 0) + 1
            )
        var scoped_table_path = table_scope_prefix(
            keys, array_table_paths, array_table_occurrences, is_array
        )

        comptime if log:
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
        if case .Err = values_res:
            return values_res^.unsafe_take_error()
        var values = values_res^.unsafe_take_value()

        # _printif[log](t"Multiline values: {values}")

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
        var def_cont = Toml.Table(Dict[String, Toml](capacity=0))
        if is_array:
            # Store the default in na list
            var lst = List[Toml](capacity=1)
            lst.append(def_cont^)
            def_cont = Toml.Array(lst^)

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
        if case .Err = cont_res:
            return cont_res^.unsafe_take_error()
        var cont = cont_res^.unsafe_take_value()

        if case .Table = cont[]:
            if (
                is_array
            ):  # Dead code? Check this, is_array is checking the container?
                array_table_paths.add(table_path)
            else:
                declared_table_paths.add(scoped_table_path)

            ref tbl = cont[][Dict[String, Toml]]

            if len(tbl) == 0:
                # Fresh table (the common case): adopt the parsed dict as a
                # whole instead of re-hashing every entry into an empty one.
                tbl = values^
            else:
                for var kv in values.take_items():
                    if kv.key in tbl:
                        return Error(t"Table key already defined: {kv.key}")
                    kv^.deinit_with(
                        lambda (var k: String, var v: Toml) {
                            mut tbl
                        }: tbl.__setitem__(k^, v^)
                    )

        else:
            return Error("container should be a table, but inner value isn't")

        # _printif[log](t"Current base repr: {base}")

    return None


def validate_control_characters(data: Span[Byte, _]) -> Optional[Error]:
    for i in range(len(data)):
        var char = data[i]
        # Fast path: printable bytes and all UTF-8 continuation bytes.
        if char >= Byte(0x20) and char != Byte(0x7F):
            continue
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
    if not _is_valid_utf8(data):
        return .Err("TOML document is not valid UTF-8.")

    _printif[log](
        t"\n\n~~~*** Starting new parse -- content: \n'''{content}'''"
    )

    var control_error = validate_control_characters(data)
    if case .Some = control_error:
        return .Err(control_error.unsafe_take())

    var idx = 0
    var inline_table_paths = Set[String]()
    var dotted_table_paths = Set[String]()
    var declared_table_paths = Set[String]()
    skip_blanks_and_comments(data, idx)

    if idx >= len(data):
        _printif[log]("Empty table, just return an empty object.")
        var tb = Dict[String, Toml](capacity=0)
        return .Ok(Toml.Table(tb^))

    _printif[log]("parsing initial kv pairs...")
    var base_res = parse_kv_pairs[NewLine, SquareBracketOpen, log=log](
        data, idx, inline_table_paths, dotted_table_paths, ""
    )
    if case .Err = base_res:
        return .Err(base_res^.unsafe_take_error())
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
        return .Err(err_or_none.unsafe_take())

    var toml = Toml.Table(base^)
    _printif[log](t"done parsing toml!\nfinal data is: {toml}")

    return .Ok(toml^)


def parse_toml_file[
    *, log: Bool = False
](path: StringSlice) raises -> Result[Toml]:
    """Parse a TOML file through a read-only memory mapping."""
    var mapped_file = MappedFile(path)
    return parse_toml[log=log](mapped_file.unsafe_view())


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
