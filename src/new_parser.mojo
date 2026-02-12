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


fn parse_multiline_string[
    quote_type: Byte
](data: Span[Byte], mut idx: Int) -> Span[Byte, data.origin]:
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
    return data[value_init : idx - 2]


fn parse_quoted_string[
    quote_type: Byte
](data: Span[Byte], mut idx: Int) -> Span[Byte, data.origin]:
    # print(
    #     "parsing quoted string from span: `",
    #     StringSlice(unsafe_from_utf8=data[idx : idx + 39]),
    #     "`",
    #     sep="",
    # )
    idx += 1
    var value_init = idx

    while data[idx] != quote_type:
        idx += 1
        if data[idx] == quote_type and data[idx - 1] == Escape:
            idx += 1

    # print("span from: `", value_init, "` ,`", idx, "`", sep="")
    # print(
    #     "span: `",
    #     StringSlice(unsafe_from_utf8=data[value_init:idx]),
    #     "`",
    #     sep="",
    # )
    return data[value_init:idx]


fn parse_inline_collection[
    collection: toml.CollectionType
](data: Span[Byte], mut idx: Int, _lvl: Int) raises -> toml.TomlType[
    data.origin
]:
    """Assumes the first char is already within the collection, but could be a space.
    """
    # comptime ContainerEnd = SquareBracketClose if collection == "array" else CurlyBracketClose

    var value: toml.TomlType[data.origin]
    skip_blanks_and_comments(data, idx)

    @parameter
    if collection == "array":
        value = toml.TomlType[data.origin].new_array()
    else:
        value = toml.TomlType[data.origin].new_table()

    # We should be at the start of the inner value.
    # Could not be triple quoted.
    @parameter
    if collection == "table":
        # skip[Space, Tab, Enter](data, idx)
        parse_and_update_kv_pairs[separator=Comma, end_char=CurlyBracketClose](
            data, idx, value, _lvl
        )
        return value^

    elif collection == "plain":
        raise ("cannot use plain in this context.")

    ref arr = value.as_opaque_array()

    # For sure this is an array or list.
    # skip_blanks_and_comments(data, idx)
    # skip[Space, NewLine](data, idx)

    while data[idx] != SquareBracketClose:
        # print(
        #     "parsing array value at idx:",
        #     idx,
        #     "and span: `{}`".format(
        #         StringSlice(unsafe_from_utf8=data[idx : idx + 30])
        #     ),
        # )
        var arr_item = parse_value[SquareBracketClose](data, idx, _lvl)
        # var s = String()
        # arr_item.write_tagged_json_to(s)
        # print("value parsed: `{}`".format(s))
        arr.append(arr_item^.move_to_addr())
        # We are at the end of the item parsed, let's move +1
        idx += 1
        # For both table and array, you need to split by comma
        skip_blanks_and_comments(data, idx)

        stop_at[Comma, SquareBracketClose](data, idx)
        if data[idx] == SquareBracketClose:
            break

        # we are at a comma
        idx += 1

        skip_blanks_and_comments(data, idx)

    return value^


fn string_to_type[
    end_char: Byte
](data: Span[Byte], mut idx: Int) raises -> toml.TomlType[data.origin]:
    """Returns end of value + 1."""
    # print("parsing value at idx: ", idx)
    comptime lower, upper = Byte(ord("0")), Byte(ord("9"))
    comptime INT_AGG, DEC_AGG = 10.0, 0.1
    comptime neg, pos = Byte(ord("-")), Byte(ord("+"))
    # var all_is_digit = True
    # var has_period = False

    if data[idx : idx + 4] == "true".as_bytes():
        idx += 3
        return toml.TomlType[data.origin](True)

    elif data[idx : idx + 5] == "false".as_bytes():
        idx += 4
        return toml.TomlType[data.origin](False)

    elif data[idx : idx + 3] == "nan".as_bytes():
        idx += 2
        return toml.TomlType[data.origin](None)
    elif data[idx : idx + 3] == "inf".as_bytes():
        idx += 2
        return toml.TomlType[data.origin](Float64.MAX)
    var v_init = idx

    # Parse floats
    var sign = 1.0
    if data[idx] == neg:
        sign = -1.0
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
    # Roll back one step because we finalized all time in the next item
    idx -= 1
    if flt:
        try:
            var vi = atof(v)
            return toml.TomlType[data.origin](vi)
        except:
            raise ("should be a float but it's not a float: {}.".format(v))

    else:
        try:
            var vi = atol(v)
            return toml.TomlType[data.origin](vi)
        except:
            raise ("should be a int but it's not a integer: {}".format(v))


fn parse_value[
    end_char: Byte
](
    data: Span[Byte],
    mut idx: Int,
    out value: toml.TomlType[data.origin],
    _lvl: Int,
) raises:
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
        # print("parsing inline array...")
        value = parse_inline_collection["array"](data, idx, _lvl)
        # print("last multiline array codepoint parsed is:", Codepoint(data[idx]))
    elif data[idx] == CurlyBracketOpen:
        idx += 1
        # print("parsing inline table...")
        value = parse_inline_collection["table"](data, idx, _lvl)
        # print("last multiline table codepoint parsed is:", Codepoint(data[idx]))
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


fn parse_key[
    o: Origin, //, close_char: Byte
](data: Span[Byte, o], mut idx: Int, mut base: List[Span[Byte, o]]) -> Span[
    Byte, o
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
    var key_found = False
    var key_init = idx
    var key: Optional[Span[Byte, o]] = {}

    while (chr := data[idx]) != close_char and idx < len(data):
        if chr == SingleQuote:
            key = parse_quoted_string[SingleQuote](data, idx)
            idx += 1
            continue
        elif chr == DoubleQuote:
            key = parse_quoted_string[DoubleQuote](data, idx)
            idx += 1
            continue
        elif not key_found and (chr == Space or chr == Tab):
            key = data[key_init:idx]
            skip[Space, Tab](data, idx)
            continue
        elif chr == Period:
            if not key:
                key = data[key_init:idx]

            # we have new key -> key
            # we have a base (or not?)

            base.append(key.unsafe_value())
            # skip dot
            idx += 1
            return parse_key[close_char](data, idx, base)

        idx += 1

    if not key:
        key = data[key_init:idx]

    var k = key.unsafe_take()
    base.append(k)
    return k


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
    var key_found = False
    var key_init = idx
    while data[idx] != close_char and idx < len(data):
        if not key_found and data[idx] == SingleQuote:
            # print("is single quoted key")
            key = parse_quoted_string[SingleQuote](data, idx)
            # print("key:", StringSlice(unsafe_from_utf8=key))
            key_found = True
        elif not key_found and data[idx] == DoubleQuote:
            # print("is double quoted key")
            key = parse_quoted_string[DoubleQuote](data, idx)
            # print("key:", StringSlice(unsafe_from_utf8=key))
            key_found = True
        # TODO: include tabs here too.
        elif not key_found and (data[idx] == Space or data[idx] == Tab):
            # You should close the key, and keep going
            key = data[key_init:idx]
            key_found = True
        elif data[idx] == Period:
            # calculate the key if it's dummy, because it's not calculated
            if not key_found:
                key = data[key_init:idx]

            # print(
            #     "Initializing inner table within key: `",
            #     StringSlice(unsafe_from_utf8=key),
            #     "`",
            #     sep="",
            # )
            ref cont = get_or_ref_container["table"](key, base)
            # ignore dot
            idx += 1
            skip[Space, Tab](data, idx)
            return parse_key_span_and_get_container[collection, close_char](
                data, idx, cont, key
            )
        idx += 1

    # print("key upstream:", StringSlice(unsafe_from_utf8=key))
    # TODO: Check if this is affecting the case when the key is empty or something similar.
    if not key_found:
        # Dummy key found. Replace with the last span.
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
](
    data: Span[Byte],
    mut idx: Int,
    mut base: toml.TomlType[data.origin],
    _lvl: Int,
) raises:
    var key = data[idx:idx]
    # print("parsing kv pair")
    # print(
    #     " -? trying to find key at span: `",
    #     StringSlice(unsafe_from_utf8=data[idx : idx + 30]),
    #     "...` at idx: ",
    #     idx,
    #     sep="",
    # )
    ref tb = parse_key_span_and_get_container["plain", Equal](
        data, idx, base, key
    )
    # ends at the last char
    # print(
    #     " -> key in kv finding: `",
    #     StringSlice(unsafe_from_utf8=key),
    #     "` at idx: ",
    #     idx,
    #     sep="",
    # )
    idx += 1

    skip[Space](data, idx)

    # NOTE: changed from CloseCurlyBracket to end_char... Check
    # print(
    #     "Parsing value starting at:",
    #     "`{}...`".format(StringSlice(unsafe_from_utf8=data[idx : idx + 30])),
    # )
    var value = parse_value[end_char](data, idx, _lvl)
    idx += 1
    # var s = String()
    # value.write_tagged_json_to(s)
    # print("value parsed!", s)
    tb.as_opaque_table()[StringSlice(unsafe_from_utf8=key)] = (
        value^.move_to_addr()
    )
    # print("value parsing and storing done!")


fn parse_and_update_kv_pairs[
    separator: Byte, end_char: Byte
](
    data: Span[Byte],
    mut idx: Int,
    mut base: toml.TomlType[data.origin],
    _lvl: Int,
) raises:
    """This function expect to be on top of the value to start parsing. So item=1.
    End at the last value + 1.
    """
    while idx < len(data) and data[idx] != end_char:
        # skip[Space, NewLine](data, idx)
        # print(
        #     "->->" * _lvl,
        #     "Finding kv pairs... span: ```{}...```\n\n".format(
        #         StringSlice(unsafe_from_utf8=data[idx : idx + 50]).replace(
        #             "\n", "\\n"
        #         )
        #     ),
        # )
        find_kv_and_update_base[end_char=end_char](data, idx, base, _lvl + 1)
        # You are one char after the end of the value.
        # print(
        #     "->->" * _lvl,
        #     "we are at end of kv parsing at: `{}` with span: ```{}...```\n\n"
        #     .format(
        #         Codepoint(data[idx]),
        #         StringSlice(unsafe_from_utf8=data[idx : idx + 50]).replace(
        #             "\n", "\\n"
        #         ),
        #     ),
        # )
        # print("end with finding...")
        # skip[Space, Enter, Tab](data, idx)
        stop_at[separator, end_char](data, idx)
        if data[idx] == end_char or idx >= len(data):
            # print(
            #     "->->" * _lvl,
            #     "found collection end before separator. Break at:",
            #     Codepoint(end_char),
            # )
            break

        # we are at separator
        skip[separator](data, idx)
        skip_blanks_and_comments(data, idx)


fn parse_multiline_collection[
    collection: toml.CollectionType
](
    data: Span[Byte], mut idx: Int, mut base: toml.TomlType[data.origin]
) -> UnsafePointer[toml.TomlType[data.origin], MutAnyOrigin]:
    """Assume where are on the position to start parsing the multiline key.
    But please skip spaces and tabs.
    """
    skip[Space, Tab](data, idx)
    print("parsing multiline collection key:")
    var key_levels = List[Span[Byte, data.origin]]()
    var key = parse_key[SquareBracketClose](data, idx, key_levels)
    idx += comptime (1 + Int(collection == "array"))
    parse_and_update_kv_pairs[separator=NewLine, end_char=SquareBracketOpen](
        data, idx, tb[], _lvl
    )
    if idx >= len(data):
        return
    # Ends at SquareBracketClose all the time
    print("parsing values for the key")
    stop_at[NewLine, SquareBracketOpen](data, idx)
    skip_blanks_and_comments(data, idx)

    parse_and_update_kv_pairs[separator=NewLine, end_char=SquareBracketOpen](
        data, idx, tb[], _lvl
    )
    # var b = UnsafePointer(to=base)
    # for k in key_levels:
    #     b = UnsafePointer(to=get_or_ref_container[collection](k, base))

    return b


fn parse_and_store_multiline_collection[
    collection: toml.CollectionType, _lvl: Int
](
    data: Span[Byte],
    mut idx: Int,
    mut base: toml.TomlType[data.origin],
    var base_key: Span[Byte, data.origin],
) raises:
    """Assume we are already at the place where we should start parsing.
    But could be a space or a tab, so just skip it.
    """
    skip[Space, Tab](data, idx)
    # if data[idx] == SquareBracketOpen:
    #     raise ("Not an array or table")

    # var is_array = data[idx + 1] == SquareBracketOpen
    # idx += 1 + Int(is_array)

    var init_idx = idx
    var tb: UnsafePointer[toml.TomlType[data.origin], MutAnyOrigin]
    var key = data[idx:idx]
    # Right away parse the key

    print("parsing key for mulitiline collection...")
    ref container = parse_key_span_and_get_container[
        o = data.origin, collection, SquareBracketClose
    ](data, idx, base, key)

    print(
        "multiline collection key elem: `",
        StringSlice(unsafe_from_utf8=key),
        "`",
        sep="",
    )

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
    skip_blanks_and_comments(data, idx)

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
        data, idx, tb[], _lvl
    )
    print("parsing values done!.")
    print("collection type:", collection.inner)

    # TODO
    # In case of nested structures in here, we need to consider quotes when comparing base values with key values.
    @parameter
    if collection == "array":
        # Base should NOT HAVE dot included.
        if len(base_key) == 0:
            base_key = key
        else:
            base_key = data[init_idx - len(base_key) - 1 : init_idx + len(key)]

        while data[idx] == SquareBracketOpen and (
            (
                # It's a table
                data[idx + 1 : idx + 1 + len(base_key)] == base_key
                and data[idx + 1 + len(base_key)] != SquareBracketClose
            )
            or (
                # It's an array
                data[idx + 1] == SquareBracketOpen
                and data[idx + 2 : idx + 2 + len(base_key)] == base_key
                and data[idx + 2 + len(base_key)] != SquareBracketClose
            )
        ):
            print(
                "we have a nested table definition within an array with base"
                " key `{}` starting at:: `{}...`".format(
                    StringSlice(unsafe_from_utf8=base_key),
                    StringSlice(unsafe_from_utf8=data[idx : idx + 30]),
                )
            )
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
                idx += len(base_key)
                if data[idx] != Period:
                    print(
                        "no period found at `{}`, skipping...".format(
                            Codepoint(data[idx])
                        )
                    )
                    break
                idx += 1
                parse_and_store_multiline_collection["array", _lvl](
                    data, idx, tb[], base_key
                )
            else:
                idx += len(base_key)
                if data[idx] != Period:
                    print(
                        "no period found at `{}`, skipping...".format(
                            Codepoint(data[idx])
                        )
                    )
                    break
                idx += 1
                parse_and_store_multiline_collection["table", _lvl](
                    data, idx, tb[], base_key
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


@always_inline
fn skip_blanks_and_comments(data: Span[Byte], mut idx: Int):
    # print(
    #     "blank shift starts at:", Codepoint(data[idx]), "with ord:", data[idx]
    # )
    while True:
        skip[NewLine, Enter, Space, Tab](data, idx)
        if data[idx] != Comment:
            break
        stop_at[NewLine](data, idx)
    # print(
    #     "blank shift stop at:",
    #     Codepoint(data[idx]),
    #     "with ord:",
    #     data[idx],
    #     "and span: `{}`".format(
    #         StringSlice(unsafe_from_utf8=data[idx : idx + 30])
    #     ),
    # )


fn parse_toml_raises(
    content: StringSlice,
) raises -> toml.TomlType[content.origin]:
    var idx = 0

    var base = toml.TomlType[content.origin].new_table()
    var data = content.as_bytes()

    skip_blanks_and_comments(data, idx)

    if not idx < len(data):
        return base^

    print("parsing initial kv pairs...")
    parse_and_update_kv_pairs[separator=NewLine, end_char=SquareBracketOpen](
        data, idx, base, 0
    )
    print("end parsing initial kv pairs...")

    # Here we are at end of file or start of a table or table list
    print("parsing tables...")
    while idx < len(data):
        # already assume data[idx] is SquareBracketOpen
        idx += 1
        if data[idx] == SquareBracketOpen:
            # it's an array
            idx += 1
            parse_and_store_multiline_collection["array", 0](
                data, idx, base, {}
            )
        else:
            # it's a table
            parse_and_store_multiline_collection["table", 0](
                data, idx, base, {}
            )

    print("done parsing toml!")
    return base^


fn parse_toml(content: StringSlice) -> Optional[toml.TomlType[content.origin]]:
    try:
        return parse_toml_raises(content)
    except:
        return None


fn toml_to_tagged_json(content: StringSlice[...]) raises -> String:
    var toml_values = parse_toml_raises(content)
    return toml_values.__repr__()
