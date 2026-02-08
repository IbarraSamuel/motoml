"""
Rules:
Dotted keys, can create a dictionary grouping the values.
"""

from utils import Variant
from sys.intrinsics import _type_is_eq, unlikely, likely
from collections.dict import _DictEntryIter
from builtin.builtin_slice import ContiguousSlice
from sys.compile import codegen_unreachable
from memory import OwnedPointer

from motoml import toml_types as toml

comptime SquareBracketOpen = ord("[")
comptime SquareBracketClose = ord("]")
comptime CurlyBracketOpen = ord("{")
comptime CurlyBracketClose = ord("}")

comptime NewLine = ord("\n")
comptime Enter = ord("\r")
comptime Space = ord(" ")

comptime Comma = ord(",")
comptime Equal = ord("=")
comptime Period = ord(".")

comptime Quote = ord('"')
comptime Escape = ord("\\")


fn parse_multiline_string(
    data: Span[Byte], var idx: Int, out value: Span[Byte, data.origin]
):
    idx += 3
    var value_init = idx

    while (
        data[idx] != Quote or data[idx - 1] != Quote or data[idx - 2] != Quote
    ):
        idx += 1
        if (
            data[idx] == Quote
            and data[idx - 1] == Quote
            and data[idx - 2] == Quote
            and data[idx - 3] == Escape
        ):
            idx += 1

    # When it stopped, the value already have two quotes, remove them from value
    value = data[value_init : idx - 2]


fn parse_quoted_string(
    data: Span[Byte], mut idx: Int, out value: Span[Byte, data.origin]
):
    idx += 1
    var value_init = idx

    while data[idx] != Quote:
        idx += 1
        if data[idx] == Quote and data[idx - 1] == Escape:
            idx += 1

    value = data[value_init:idx]


fn parse_inline_collection[
    collection: toml.CollectionType
](data: Span[Byte], mut idx: Int) raises -> toml.TomlType[data.origin]:
    """Assumes the first char is already within the collection, but could be a space.
    """
    # print("parse inline collection", collection.inner)
    # comptime ContainerEnd = SquareBracketClose if collection == "array" else CurlyBracketClose

    var value: toml.TomlType[data.origin]

    @parameter
    if collection == "array":
        value = toml.TomlType[data.origin].new_array()
    else:
        value = toml.TomlType[data.origin].new_table()

    skip[Space](data, idx)

    # We should be at the start of the inner value.
    # Could not be triple quoted.
    @parameter
    if collection == "table":
        parse_and_update_kv_pairs[separator=Comma, end_char=CurlyBracketClose](
            data, idx, value
        )
        return value^
        # print("finished table", value)

    elif collection == "plain":
        raise ("cannot use plain in this context.")

    ref arr = value.as_opaque_array()

    # For sure this is an array or list.
    skip[Space, NewLine](data, idx)

    while data[idx] != SquareBracketClose:
        arr.append(parse_value[SquareBracketClose](data, idx).move_to_addr())

        # For both table and array, you need to split by comma
        stop_at[Comma, SquareBracketClose](data, idx)
        if data[idx] == SquareBracketClose:
            break

        # we are at a comma
        idx += 1

        skip[Space, NewLine](data, idx)

    return value^


fn string_to_type[
    end_char: Byte
](data: Span[Byte], mut idx: Int) raises -> toml.TomlType[data.origin]:
    """Returns end of value + 1."""
    print("parsing value at idx: ", idx)
    comptime lower, upper = ord("0"), ord("9")
    comptime INT_AGG, DEC_AGG = 10.0, 0.1
    comptime neg, pos = ord("-"), ord("+")
    # var all_is_digit = True
    # var has_period = False

    if data[idx : idx + 4] == StringSlice("true").as_bytes():
        idx += 4
        return toml.TomlType[data.origin](True)

    elif data[idx : idx + 5] == StringSlice("false").as_bytes():
        idx += 5
        return toml.TomlType[data.origin](False)

    var v_init = idx

    # Parse floats
    var sign = 1
    if data[idx] == neg:
        sign = -1
        idx += 1
    elif data[idx] == pos:
        idx += 1

    var num = 0.0 * sign
    var flt = False

    # to agg later on the decimals
    var init = idx

    while (
        idx < len(data)
        and data[idx] != end_char
        and data[idx] != NewLine
        and data[idx] != Space
        and data[idx] != Comma
    ):
        var c = data[idx]
        if c < lower or c > upper:
            if c == Period and not flt:
                flt = True
                init = idx
                idx += 1
                continue

            raise ("value is not a numeric value. It's another dtype")

        var cc = Float64(c - lower)
        num = (
            num * 10
            + sign * cc if not flt else num
            + sign * cc * 0.1 ** (idx - init)
        )
        idx += 1

    # TODO: Change this. For now let's use this one:
    var v = StringSlice(unsafe_from_utf8=data[v_init:idx])
    if flt:
        try:
            var vi = atof(v)
            return toml.TomlType[data.origin](vi)
        except:
            raise ("should be a float but it's not a float")

    else:
        try:
            var vi = atol(v)
            return toml.TomlType[data.origin](vi)
        except:
            raise ("should be a int but it's not a integer")


fn parse_value[
    end_char: Byte
](data: Span[Byte], mut idx: Int, out value: toml.TomlType[data.origin]) raises:
    # Assumes the first char is the first value of the value to parse.
    if data[idx] == Quote:
        if data[idx + 1] == Quote and data[idx + 2] == Quote:
            var s = parse_multiline_string(data, idx)
            value = toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
        else:
            var s = parse_quoted_string(data, idx)
            value = toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
    elif data[idx] == SquareBracketOpen:
        idx += 1
        value = parse_inline_collection["array"](data, idx)
    elif data[idx] == CurlyBracketOpen:
        idx += 1
        value = parse_inline_collection["table"](data, idx)
    else:
        value = string_to_type[end_char](data, idx)


fn get_or_ref_container[
    collection: toml.CollectionType
](key: Span[Byte], mut base: toml.TomlType[key.origin]) -> ref[
    base
] toml.TomlType[key.origin]:
    str_key = StringSlice(unsafe_from_utf8=key)
    var def_addr: toml.Opaque[MutExternalOrigin]

    @parameter
    if collection == "array":
        def_addr = base.new_array().move_to_addr()
    else:
        def_addr = base.new_table().move_to_addr()

    ref base_tb = base.as_opaque_table().setdefault(str_key, def_addr)
    return base.from_addr(base_tb)


fn parse_key_span_and_get_container[
    o: Origin, //, collection: toml.CollectionType, close_char: Byte
](
    data: Span[Byte, o],
    mut idx: Int,
    mut base: toml.TomlType[o],
    mut key: Span[Byte, o],
) -> ref[base] toml.TomlType[o]:
    """Assumes that first character is not a space. Ends on close char."""
    var key_init = idx
    print("parsing key span and getting container.")
    if data[idx] == Quote:
        key = parse_quoted_string(data, idx)
        # Ignore closing quote
        idx += 1

    else:
        while (
            data[idx] != close_char and data[idx] != Space and idx < len(data)
        ):
            if data[idx] == Period:
                key = data[key_init:idx]
                ref cont = get_or_ref_container["table"](key, base)
                # ignore dot
                idx += 1
                skip[Space](data, idx)
                return parse_key_span_and_get_container[collection, close_char](
                    data, idx, cont, key
                )
            idx += 1

        key = data[key_init:idx]

    # if data[idx] == Space:
    stop_at[close_char](data, idx)

    # Here we are at close char, so key should be set up

    # For multiline collections, you actually want to use the current base
    if collection == "plain":
        return base

    print("key:", StringSlice(unsafe_from_utf8=key))
    # For the rest, use the table as the holder of the key.
    return get_or_ref_container[collection](key, base)


fn find_kv_and_update_base[
    end_char: Byte
](data: Span[Byte], mut idx: Int, mut base: toml.TomlType[data.origin]) raises:
    var key = data[idx:idx]

    ref tb = parse_key_span_and_get_container["plain", Equal](
        data, idx, base, key
    )
    idx += 1

    skip[Space](data, idx)

    # NOTE: changed from CloseCurlyBracket to end_char... Check
    tb.as_opaque_table()[StringSlice(unsafe_from_utf8=key)] = parse_value[
        end_char
    ](data, idx).move_to_addr()


fn parse_and_update_kv_pairs[
    separator: Byte, end_char: Byte
](data: Span[Byte], mut idx: Int, mut base: toml.TomlType[data.origin]) raises:
    """This function ends at end_char always."""
    skip[Space, NewLine](data, idx)
    print(
        "parsing kv at idx:",
        idx,
        "and value:",
        Codepoint(data[idx]),
        "and len(data) =",
        len(data),
    )
    while idx < len(data) and data[idx] != end_char:
        find_kv_and_update_base[end_char=end_char](data, idx, base)
        skip[Space](data, idx)
        stop_at[separator, end_char](data, idx)
        if data[idx] == end_char or idx == len(data):
            break

        # we are at separator
        skip[separator, Space](data, idx)


fn parse_and_store_multiline_collection(
    data: Span[Byte], mut idx: Int, mut base: toml.TomlType[data.origin]
) raises:
    if data[idx] != SquareBracketOpen:
        raise ("Not an array or table")

    var is_array = data[idx + 1] == SquareBracketOpen
    idx += 1 + Int(is_array)

    var tb: UnsafePointer[toml.TomlType[data.origin], MutAnyOrigin]
    var key = data[idx:idx]
    # Right away parse the key

    var cont_getter = parse_key_span_and_get_container[
        o = data.origin, "array", SquareBracketClose
    ] if is_array else parse_key_span_and_get_container[
        o = data.origin, "table", SquareBracketClose
    ]

    ref container = cont_getter(data, idx, base, key)
    idx += Int(is_array)

    if is_array:
        ref array = container.as_opaque_array()
        array.append(base.new_table().move_to_addr())
        tb = array[len(array) - 1].bitcast[toml.TomlType[data.origin]]()
    else:
        tb = UnsafePointer(to=container)

    # Use `tb` to store any kv pairs

    # If there is a table key, there should be values right?
    stop_at[NewLine, SquareBracketOpen](data, idx)
    skip[NewLine](data, idx)

    # Identify if there is a nested table within a table list
    # for that, the next table should have the same key as the table list.
    # which one is the key you have curently? Take the init to idx now.
    # Which key is in nested table? Check from [ to ] and match if the key startswith table arr key.

    if data[idx] == SquareBracketOpen or idx >= len(data):
        return

    parse_and_update_kv_pairs[separator=NewLine, end_char=SquareBracketOpen](
        data, idx, tb[]
    )


@always_inline
fn skip[*chars: Byte](data: Span[Byte], mut idx: Int):
    while idx < len(data):

        @parameter
        for i in range(Variadic.size(chars)):
            comptime c = chars[i]
            if data[idx] == c:
                idx += 1
                break
        else:
            return


fn stop_at[*chars: Byte](data: Span[Byte], mut idx: Int):
    while idx < len(data):

        @parameter
        for i in range(Variadic.size(chars)):
            comptime c = chars[i]
            if data[idx] == c:
                return

        idx += 1


# TODO: impl array subtables.
fn parse_toml_raises(
    content: StringSlice,
) raises -> toml.TomlType[content.origin]:
    var idx = 0

    var base = toml.TomlType[content.origin].new_table()
    var data = content.as_bytes()

    skip[NewLine, Enter, Space](data, idx)
    if not idx < len(data):
        return base^

    print("parsing initial kv pairs...")
    parse_and_update_kv_pairs[separator=NewLine, end_char=SquareBracketOpen](
        data, idx, base
    )

    # Here we are at end of file or start of a table or table list
    print("parsing tables...")
    while idx < len(data):
        parse_and_store_multiline_collection(data, idx, base)

    print("done parsing toml!")
    return base^


fn parse_toml(content: StringSlice) -> Optional[toml.TomlType[content.origin]]:
    try:
        return parse_toml_raises(content)
    except:
        return None


fn toml_to_tagged_json(
    content: StringSlice[...],
) raises -> StringSlice[ImmutAnyOrigin]:
    from collections.string import String

    s = String()
    parse_toml_raises(content).write_tagged_json_to(s)
    return s
