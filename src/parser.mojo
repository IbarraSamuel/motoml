"""
Rules:
Dotted keys, can create a dictionary grouping the values.
"""

from collections.string import Codepoint
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

comptime DoubleQuote = ord('"')
comptime SingleQuote = ord("'")
comptime Escape = ord("\\")


fn parse_multiline_string[
    quote_type: Byte
](data: Span[Byte], mut idx: Int, out value: Span[Byte, data.origin]):
    idx += 3
    var value_init = idx

    while (
        data[idx] != quote_type
        or data[idx - 1] != quote_type
        or data[idx - 2] != quote_type
    ):
        idx += 1
        if data[idx] == quote_type and data[idx - 1] == Escape:
            idx += 1

    # When it stopped, the value already have two quotes, remove them from value
    value = data[value_init : idx - 2]


fn parse_quoted_string[
    quote_type: Byte
](data: Span[Byte], mut idx: Int, out value: Span[Byte, data.origin]):
    idx += 1
    var value_init = idx

    while data[idx] != quote_type:
        idx += 1
        if data[idx] == quote_type and data[idx - 1] == Escape:
            idx += 1

    value = data[value_init:idx]


fn parse_inline_collection[
    collection: toml.CollectionType
](data: Span[Byte], mut idx: Int) raises -> toml.TomlType[data.origin]:
    """Assumes the first char is already within the collection, but could be a space.
    """
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
    # print("parsing value at idx: ", idx)
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
    if data[idx] == DoubleQuote:
        if data[idx + 1] == DoubleQuote and data[idx + 2] == DoubleQuote:
            # print("value is a triple double quote string")
            var s = parse_multiline_string[DoubleQuote](data, idx)
            value = toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
        else:
            # print("value is double quote string")
            var s = parse_quoted_string[DoubleQuote](data, idx)
            value = toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
    elif data[idx] == SingleQuote:
        if data[idx + 1] == SingleQuote and data[idx + 2] == SingleQuote:
            # print("value is a triple single quote string")
            var s = parse_multiline_string[SingleQuote](data, idx)
            value = toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
        else:
            # print("value is single quote string")
            var s = parse_quoted_string[SingleQuote](data, idx)
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
    # TODO: Note: You cannot assume that the quoted keys are already complete. You might have:
    # quote."some".'thing' and it's valid.
    var dummy_key = key
    var key_init = idx
    while data[idx] != close_char and idx < len(data):
        if data[idx] == SingleQuote:
            key = parse_quoted_string[SingleQuote](data, idx)
        elif data[idx] == DoubleQuote:
            key = parse_quoted_string[DoubleQuote](data, idx)
        # TODO: include tabs here too.
        elif data[idx] == Space:
            # You should close the key, and keep going
            key = data[key_init:idx]
        elif data[idx] == Period:
            # calculate the key if it's dummy, because it's not calculated
            if key == dummy_key:
                key = data[key_init:idx]

            ref cont = get_or_ref_container["table"](key, base)
            # ignore dot
            idx += 1
            skip[Space](data, idx)
            return parse_key_span_and_get_container[collection, close_char](
                data, idx, cont, key
            )
        idx += 1

    if key == dummy_key:
        key = data[key_init:idx]

    # if data[idx] == Space:
    stop_at[close_char](data, idx)

    # Here we are at close char, so key should be set up

    # For multiline collections, you actually want to use the current base
    if collection == "plain":
        return base

    # For the rest, use the table as the holder of the key.
    return get_or_ref_container[collection](key, base)


fn find_kv_and_update_base[
    end_char: Byte
](data: Span[Byte], mut idx: Int, mut base: toml.TomlType[data.origin]) raises:
    var key = data[idx:idx]
    # print("parsing kv pair")
    ref tb = parse_key_span_and_get_container["plain", Equal](
        data, idx, base, key
    )
    print("key in kv finding...:", StringSlice(unsafe_from_utf8=key))
    idx += 1

    skip[Space](data, idx)

    # NOTE: changed from CloseCurlyBracket to end_char... Check
    # print("Parsing value...")
    tb.as_opaque_table()[StringSlice(unsafe_from_utf8=key)] = parse_value[
        end_char
    ](data, idx).move_to_addr()
    # print("parsing value done!")


fn parse_and_update_kv_pairs[
    separator: Byte, end_char: Byte
](data: Span[Byte], mut idx: Int, mut base: toml.TomlType[data.origin]) raises:
    """This function ends at end_char always."""
    while idx < len(data) and data[idx] != end_char:
        skip[Space, NewLine](data, idx)
        print("Finding kv pairs...")
        find_kv_and_update_base[end_char=end_char](data, idx, base)
        print("end with finding...")
        skip[Space](data, idx)
        stop_at[separator, end_char](data, idx)
        if data[idx] == end_char or idx >= len(data):
            break

        # we are at separator
        skip[separator, Space](data, idx)


fn parse_and_store_multiline_collection[
    collection: toml.CollectionType
](
    data: Span[Byte],
    mut idx: Int,
    mut base: toml.TomlType[data.origin],
    var base_key: Span[Byte, data.origin],
) raises:
    """Assume we are already at the place where we should start parsing."""
    # if data[idx] == SquareBracketOpen:
    #     raise ("Not an array or table")

    # var is_array = data[idx + 1] == SquareBracketOpen
    # idx += 1 + Int(is_array)

    var init_idx = idx
    var tb: UnsafePointer[toml.TomlType[data.origin], MutAnyOrigin]
    var key = data[idx:idx]
    # Right away parse the key

    ref container = parse_key_span_and_get_container[
        o = data.origin, collection, SquareBracketClose
    ](data, idx, base, key)

    print("on key:", StringSlice(unsafe_from_utf8=key))

    @parameter
    if collection == "array":
        idx += 1
        ref array = container.as_opaque_array()
        array.append(base.new_table().move_to_addr())
        tb = array[len(array) - 1].bitcast[toml.TomlType[data.origin]]()
    else:
        tb = UnsafePointer(to=container)

    # Use `tb` to store any kv pairs

    # If there is a table key, there should be values right?
    stop_at[NewLine, SquareBracketOpen](data, idx)
    skip[NewLine, Space](data, idx)

    # Identify if there is a nested table within a table list
    # for that, the next table should have the same key as the table list.
    # which one is the key you have curently? Take the init to idx now.
    # Which key is in nested table? Check from [ to ] and match if the key startswith table arr key.

    # in case we hit end of file.
    if idx >= len(data):
        return

    print(
        "Parsing values for table with key:",
        StringSlice(unsafe_from_utf8=key),
        "starting at: `{}`".format(
            StringSlice(unsafe_from_utf8=data[idx : idx + 40])
        ),
    )
    parse_and_update_kv_pairs[separator=NewLine, end_char=SquareBracketOpen](
        data, idx, tb[]
    )
    print("parsing values done!.")
    print("collection type:", collection.inner)

    # TODO: Check if nested tables within tables are allowed.
    @parameter
    if collection == "array":
        # Base should NOT HAVE dot included.
        if len(base_key) == 0:
            base_key = key
        else:
            base_key = data[init_idx - len(base_key) - 1 : init_idx + len(key)]
        while (
            # It's a table
            data[idx] == SquareBracketOpen
            and data[idx + 1 : idx + 1 + len(base_key)]
            == base_key  # startswith
            and data[idx + 1 + len(base_key)] != SquareBracketClose
        ) or (
            # It's an array
            data[idx] == SquareBracketOpen
            and data[idx + 1] == SquareBracketOpen
            and data[idx + 2 : idx + 2 + len(base_key)] == base_key
            and data[idx + 2 + len(base_key)] != SquareBracketClose
        ):
            # Since you need to skip the current level, you can just strip key
            # from the multiline collection.

            # Then, next inner iterations have no clue on the initial keys, for that, let's keep
            # a runtime optional value, when available, you should check on that one, instead of
            # the generated key. If not available, just go with the generated key.
            idx += 1
            if data[idx] == SquareBracketOpen:
                idx += 1
                # Since you need to skip the current level, you can just strip key
                # from the multiline collection.
                idx += len(base_key) + 1
                parse_and_store_multiline_collection["array"](
                    data, idx, tb[], base_key
                )
            else:
                idx += len(base_key) + 1
                parse_and_store_multiline_collection["table"](
                    data, idx, tb[], base_key
                )

            # var shift = Int(data[idx + 1] == SquareBracketOpen)
            # # if the table is repeated, could be:
            # # 1. There is a new entry on the list.
            # # just don't do anything, close this, let it to the next.

            # # we have a case of a nested table.
            # var inner_extra_key = data[idx:idx]
            # var inner_cont: UnsafePointer[
            #     toml.TomlType[data.origin], MutAnyOrigin
            # ]
            # # print("parsing inner value:")
            # # Array
            # if data[idx + 1] == SquareBracketOpen:
            #     idx += len(key) + 3
            #     # print("inner value as an array.")
            #     ref array = parse_key_span_and_get_container[
            #         collection="array", close_char=SquareBracketClose
            #     ](data, idx, tb[], inner_extra_key).as_opaque_array()
            #     array.append(base.new_table().move_to_addr())
            #     inner_cont = array[len(array) - 1].bitcast[
            #         toml.TomlType[data.origin]
            #     ]()
            # # Table
            # else:
            #     idx += len(key) + 2
            #     # print("inner value as a table.")
            #     inner_cont = UnsafePointer(
            #         to=parse_key_span_and_get_container[
            #             collection="table", close_char=SquareBracketClose
            #         ](data, idx, tb[], inner_extra_key)
            #     )
            # # print(
            # #     "inner value parsing done!: Inner key:",
            # #     StringSlice(unsafe_from_utf8=inner_extra_key),
            # # )
            # stop_at[NewLine, SquareBracketOpen](data, idx)
            # skip[NewLine](data, idx)
            # if idx >= len(data):
            #     return
            # # print(
            # #     "parsing value for inner container... `",
            # #     StringSlice(unsafe_from_utf8=data[idx : idx + 40]),
            # #     "`",
            # #     sep="",
            # # )
            # parse_and_update_kv_pairs[
            #     separator=NewLine, end_char=SquareBracketOpen
            # ](data, idx, inner_cont[])
            # # print("inner value added!")


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
        # already assume data[idx] is SquareBracketOpen
        idx += 1
        if data[idx] == SquareBracketOpen:
            # it's an array
            idx += 1
            parse_and_store_multiline_collection["array"](data, idx, base, {})
        else:
            # it's a table
            parse_and_store_multiline_collection["table"](data, idx, base, {})

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
