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
from iter import map

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


fn parse_inline_table(
    data: Span[Byte], mut idx: Int
) raises -> toml.TomlType[data.origin]:
    skip_blanks_and_comments(data, idx)
    return parse_kv_pairs[separator=Comma, end_char=CurlyBracketClose](
        data, idx
    )


fn parse_inline_array(
    data: Span[Byte], mut idx: Int
) raises -> toml.TomlType[data.origin]:
    """Assumes the first char is already within the collection, but could be a space.
    """
    skip_blanks_and_comments(data, idx)

    var value = toml.TomlType[data.origin].new_array()
    ref arr = value.as_opaque_array()

    while data[idx] != SquareBracketClose:
        # print(
        #     "parsing array value at idx:",
        #     idx,
        #     "and span: `{}`".format(
        #         StringSlice(unsafe_from_utf8=data[idx : idx + 30])
        #     ),
        # )
        var arr_item = parse_value[SquareBracketClose](data, idx)
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
](data: Span[Byte], mut idx: Int) raises -> toml.TomlType[data.origin]:
    # Assumes the first char is the first value of the value to parse.
    if data[idx] == DoubleQuote:
        if data[idx + 1] == DoubleQuote and data[idx + 2] == DoubleQuote:
            # print("value is a triple double quote string")
            var s = parse_multiline_string[DoubleQuote](data, idx)
            return toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
        else:
            # print("value is double quote string")
            var s = parse_quoted_string[DoubleQuote](data, idx)
            return toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
    elif data[idx] == SingleQuote:
        if data[idx + 1] == SingleQuote and data[idx + 2] == SingleQuote:
            # print("value is a triple single quote string")
            var s = parse_multiline_string[SingleQuote](data, idx)
            return toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
        else:
            # print("value is single quote string")
            var s = parse_quoted_string[SingleQuote](data, idx)
            return toml.TomlType[data.origin](StringSlice(unsafe_from_utf8=s))
    elif data[idx] == SquareBracketOpen:
        idx += 1
        # print("parsing inline array...")
        return parse_inline_array(data, idx)
        # print("last multiline array codepoint parsed is:", Codepoint(data[idx]))
    elif data[idx] == CurlyBracketOpen:
        idx += 1
        # print("parsing inline table...")
        return parse_inline_table(data, idx)
        # print("last multiline table codepoint parsed is:", Codepoint(data[idx]))
    else:
        return string_to_type[end_char](data, idx)


fn get_container_ref[
    o: Origin, //
](
    keys: Span[Span[Byte, o]],
    mut base: toml.TomlType[o],
    *,
    var default: toml.TomlType[o],
) -> ref[base] toml.TomlType[o]:
    var is_array = default.inner.isa[toml.TomlType[o].OpaqueArray]()
    var cont = base.to_addr().unsafe_origin_cast[MutExternalOrigin]()
    for k in keys[: len(keys) - 1]:
        cont = (
            cont.bitcast[toml.TomlType[o]]()[]
            .as_opaque_table()
            .setdefault(
                StringSlice(unsafe_from_utf8=k), base.new_table().move_to_addr()
            )
        )

    var k = StringSlice(unsafe_from_utf8=keys[len(keys) - 1])
    ref pre_last = cont.bitcast[toml.TomlType[o]]()[].as_opaque_table()
    var last = pre_last.setdefault(k, default^.move_to_addr()).bitcast[
        toml.TomlType[o]
    ]()
    if not is_array:
        # just refer to the placeholder of the key.
        return last[]

    # Add a last element and refer to it. So we can modify the last element.
    ref arr = last[].as_opaque_array()
    arr.append(toml.TomlType[o].new_table().move_to_addr())
    return arr[len(arr) - 1].bitcast[toml.TomlType[o]]()[]


fn parse_keys[
    o: Origin, //, close_char: Byte
](data: Span[Byte, o], mut idx: Int, var key_base: List[Span[Byte, o]]) -> List[
    Span[Byte, o]
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
        elif not key and (chr == Space or chr == Tab):
            key = data[key_init:idx]
            skip[Space, Tab](data, idx)
            continue
        elif chr == Period:
            if not key:
                key = data[key_init:idx]

            # store the next level in the key_base list
            key_base.append(key.unsafe_value())
            # skip dot
            idx += 1
            # Return the inner element?
            return parse_keys[close_char](data, idx, key_base^)

        idx += 1

    if not key:
        key = data[key_init:idx]

    var k = key.unsafe_take()
    key_base.append(k)
    return key_base^


fn parse_kv_pairs[
    separator: Byte, end_char: Byte
](data: Span[Byte], mut idx: Int) raises -> toml.TomlType[data.origin]:
    """This function expect to be on top of the value to start parsing. So item=1.
    End at the last value + 1.
    """
    var table = toml.TomlType[data.origin].new_table()
    while idx < len(data) and data[idx] != end_char:
        # Base is always a new table because you are not parsing
        # something on multiline mode.
        var key_base = List[Span[Byte, data.origin]]()
        var keys = parse_keys[Equal](data, idx, key_base^)
        print(
            "inline keys -> <",
            ",".join([StringSlice(unsafe_from_utf8=k) for k in keys]),
            ">",
            sep="",
        )
        idx += 1
        skip[Space, Tab](data, idx)
        var v = parse_value[end_char](data, idx)
        print("inline value -> '", v.__repr__(), "'", sep="")
        idx += 1

        ref cont = get_container_ref(
            keys, table, default=toml.TomlType[data.origin].new_table()
        )
        # var kk = StringSlice[mut=False](unsafe_from_utf8=keys[-1])
        cont = v^
        stop_at[separator, end_char](data, idx)
        if data[idx] == end_char or idx >= len(data):
            break

        # we are at separator
        skip[separator](data, idx)
        skip_blanks_and_comments(data, idx)
    return table^


# fn parse_multiline_collection_and_store[
#     o: Origin, //, collection: toml.CollectionType
# ](
#     data: Span[Byte, o],
#     mut idx: Int,
#     # mut base: toml.TomlType[o],
#     # TODO: Usse this!
#     mut last_keys: List[Span[Byte, o]],
#     mut last_base: toml.TomlType[o],
# ) raises -> ref[base] toml.TomlType[o]:
#     """Assume where are on the position to start parsing the multiline key.
#     But please skip spaces and tabs.
#     """
#     skip[Space, Tab](data, idx)
#     print("parsing multiline collection key:")
#     key_levels = parse_keys[SquareBracketClose](data, idx, {})
#     idx += comptime (1 + Int(collection == "array"))

#     # Create container
#     ref container_ptr = get_or_ref_container[collection](key_levels, base)

#     if idx >= len(data):
#         return container_ptr

#     print("parsing values for the key")
#     stop_at[NewLine, SquareBracketOpen](data, idx)
#     skip_blanks_and_comments(data, idx)

#     var table = parse_kv_pairs[NewLine, SquareBracketOpen](data, idx)

#     @parameter
#     if collection == "table":
#         container_ptr = table^
#     else:
#         container_ptr.as_opaque_array().append(table^.move_to_addr())

#     return container_ptr


# fn parse_multiline_key(
#     data: Span[Byte], mut idx: Int, mut keys: List[Span[Byte, data.origin]]
# ) raises -> toml.TomlType[data.origin]:
#     """Assume where are on the position to start parsing the multiline key.
#     But please skip spaces and tabs.
#     """
#     skip[Space, Tab](data, idx)
#     # print("parsing multiline collection key:")
#     keys = parse_keys[SquareBracketClose](data, idx, {})

#     # In case you are on a list, just skip the second squarebracket open
#     idx += 1 + Int(data[idx] == SquareBracketOpen)

#     stop_at[NewLine, SquareBracketOpen](data, idx)
#     if data[idx] == SquareBracketOpen or idx >= len(data):
#         return toml.TomlType[data.origin].new_table()
#     skip_blanks_and_comments(data, idx)

#     # print("parsing values for the key")
#     return parse_kv_pairs[NewLine, SquareBracketOpen](data, idx)


fn parse_multiline_keys(
    data: Span[Byte], mut idx: Int
) raises -> List[Span[Byte, data.origin]]:
    """Assume where are on the position to start parsing the multiline key.
    But please skip spaces and tabs.
    """
    skip[Space, Tab](data, idx)
    # print("parsing multiline collection key:")
    var keys = parse_keys[SquareBracketClose](data, idx, {})

    # In case you are on a list, just skip the second squarebracket open
    idx += 1 + Int(data[idx] == SquareBracketOpen)

    stop_at[NewLine, SquareBracketOpen](data, idx)
    skip_blanks_and_comments(data, idx)

    return keys^


# fn parse_multiline_collection(
#     data: Span[Byte], mut idx: Int, mut keys: List[Span[Byte, data.origin]]
# ) raises -> toml.TomlType[data.origin]:
#     """Assume where are on the position to start parsing the multiline key.
#     But please skip spaces and tabs.
#     """
#     skip[Space, Tab](data, idx)
#     print("parsing multiline collection key:")
#     keys = parse_keys[SquareBracketClose](data, idx, {})

#     # In case you are on a list, just skip the second squarebracket open
#     idx += 1 + Int(data[idx] == SquareBracketOpen)

#     stop_at[NewLine, SquareBracketOpen](data, idx)
#     if data[idx] == SquareBracketOpen or idx >= len(data):
#         return toml.TomlType[data.origin].new_table()
#     skip_blanks_and_comments(data, idx)

#     print("parsing values for the key")
#     return parse_kv_pairs[NewLine, SquareBracketOpen](data, idx)

# @parameter
# if collection == "table":
#     container_ptr = table^
# else:
#     container_ptr.as_opaque_array().append(table^.move_to_addr())

# TODO: Handle tables within array values.

# Ends at SquareBracketClose all the time
# var b = UnsafePointer(to=base)
# for k in key_levels:
#     b = UnsafePointer(to=get_or_ref_container[collection](k, base))

# return container_ptr


# fn parse_and_store_multiline_collection[
#     collection: toml.CollectionType, _lvl: Int
# ](
#     data: Span[Byte],
#     mut idx: Int,
#     mut base: toml.TomlType[data.origin],
#     var base_key: Span[Byte, data.origin],
# ) raises:
#     """Assume we are already at the place where we should start parsing.
#     But could be a space or a tab, so just skip it.
#     """
#     skip[Space, Tab](data, idx)
#     # if data[idx] == SquareBracketOpen:
#     #     raise ("Not an array or table")

#     # var is_array = data[idx + 1] == SquareBracketOpen
#     # idx += 1 + Int(is_array)

#     var init_idx = idx
#     var tb: UnsafePointer[toml.TomlType[data.origin], MutAnyOrigin]
#     var key = data[idx:idx]
#     # Right away parse the key

#     print("parsing key for mulitiline collection...")
#     ref container = parse_key_span_and_get_container[
#         o = data.origin, collection, SquareBracketClose
#     ](data, idx, base, key)

#     print(
#         "multiline collection key elem: `",
#         StringSlice(unsafe_from_utf8=key),
#         "`",
#         sep="",
#     )

#     @parameter
#     if collection == "array":
#         idx += 1
#         ref array = container.as_opaque_array()
#         array.append(base.new_table().move_to_addr())
#         tb = array[len(array) - 1].bitcast[toml.TomlType[data.origin]]()
#     else:
#         tb = UnsafePointer(to=container)

#     # Use `tb` to store any kv pairs

#     # If there is a table key, there should be values right?
#     stop_at[NewLine, SquareBracketOpen](data, idx)
#     skip_blanks_and_comments(data, idx)

#     # Identify if there is a nested table within a table list
#     # for that, the next table should have the same key as the table list.
#     # which one is the key you have curently? Take the init to idx now.
#     # Which key is in nested table? Check from [ to ] and match if the key startswith table arr key.

#     # in case we hit end of file.
#     if idx >= len(data):
#         return

#     print(
#         "Parsing values for table with key:",
#         StringSlice(unsafe_from_utf8=key),
#         "starting at: `{}`".format(
#             StringSlice(unsafe_from_utf8=data[idx : idx + 40])
#         ),
#     )
#     parse_and_update_kv_pairs[separator=NewLine, end_char=SquareBracketOpen](
#         data, idx, tb[], _lvl
#     )
#     print("parsing values done!.")
#     print("collection type:", collection.inner)

#     # TODO
#     # In case of nested structures in here, we need to consider quotes when comparing base values with key values.
#     @parameter
#     if collection == "array":
#         # Base should NOT HAVE dot included.
#         if len(base_key) == 0:
#             base_key = key
#         else:
#             base_key = data[init_idx - len(base_key) - 1 : init_idx + len(key)]

#         while data[idx] == SquareBracketOpen and (
#             (
#                 # It's a table
#                 data[idx + 1 : idx + 1 + len(base_key)] == base_key
#                 and data[idx + 1 + len(base_key)] != SquareBracketClose
#             )
#             or (
#                 # It's an array
#                 data[idx + 1] == SquareBracketOpen
#                 and data[idx + 2 : idx + 2 + len(base_key)] == base_key
#                 and data[idx + 2 + len(base_key)] != SquareBracketClose
#             )
#         ):
#             print(
#                 "we have a nested table definition within an array with base"
#                 " key `{}` starting at:: `{}...`".format(
#                     StringSlice(unsafe_from_utf8=base_key),
#                     StringSlice(unsafe_from_utf8=data[idx : idx + 30]),
#                 )
#             )
#             # Since you need to skip the current level, you can just strip key
#             # from the multiline collection.

#             # Then, next inner iterations have no clue on the initial keys, for that, let's keep
#             # a runtime optional value, when available, you should check on that one, instead of
#             # the generated key. If not available, just go with the generated key.
#             idx += 1
#             if data[idx] == SquareBracketOpen:
#                 idx += 1
#                 # Since you need to skip the current level, you can just strip key
#                 # from the multiline collection.
#                 idx += len(base_key)
#                 if data[idx] != Period:
#                     print(
#                         "no period found at `{}`, skipping...".format(
#                             Codepoint(data[idx])
#                         )
#                     )
#                     break
#                 idx += 1
#                 parse_and_store_multiline_collection["array", _lvl](
#                     data, idx, tb[], base_key
#                 )
#             else:
#                 idx += len(base_key)
#                 if data[idx] != Period:
#                     print(
#                         "no period found at `{}`, skipping...".format(
#                             Codepoint(data[idx])
#                         )
#                     )
#                     break
#                 idx += 1
#                 parse_and_store_multiline_collection["table", _lvl](
#                     data, idx, tb[], base_key
#                 )


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
    while True:
        skip[NewLine, Enter, Space, Tab](data, idx)
        if data[idx] != Comment:
            break
        stop_at[NewLine](data, idx)


# fn keys_are_equal[
#     o: Origin, //
# ](keys: Tuple[Span[Byte, o], Span[Byte, o]]) -> Bool:
#     return keys[0] == keys[1]


fn parse_toml_raises(
    content: StringSlice,
) raises -> toml.TomlType[content.origin]:
    var data = content.as_bytes()

    var idx = 0
    skip_blanks_and_comments(data, idx)

    if idx >= len(data):
        return toml.TomlType[content.origin].new_table()

    print("parsing initial kv pairs...")
    var base = parse_kv_pairs[NewLine, SquareBracketOpen](data, idx)
    print("end parsing initial kv pairs...")

    # Here we are at end of file or start of a table or table list
    # print("parsing tables...")
    var last_base = Pointer(to=base)
    var last_keys = List[Span[Byte, data.origin]]()

    # NOTES:
    # 1. Do not store base. Calculate base using the last keys values.
    # 2. Assume all nested values will be a location of an array point.
    # 3. in cases like a list of lists
    # [[a]]
    # [[a.b]]
    #     [a.b.c]
    #         d = "val0"
    # [[a.b]]
    #     [a.b.c]
    #         d = "val1"
    # a is a last_keys candidate but not a nested attr
    # a.b is a last_keys candidate and a nested attr
    # a.b.c is a nested attr

    # For table-related collections, you should have the placeholder on the key,
    # to just insert the parsed table in there.
    # For array-related, you should return a reference to the list index, to just put
    # the parsed value in there. By default, you can just use a empty table.

    fn tp_eq[o: Origin](v: Tuple[Span[Byte, o], Span[Byte, o]]) -> Bool:
        return v[0] == v[1]

    print(
        "starting multiline parsing on row: `{}...`".format(
            StringSlice(unsafe_from_utf8=data[idx : idx + 30])
        )
    )
    while idx < len(data):
        var is_array = data[idx + 1] == SquareBracketOpen

        idx += 1 + Int(is_array)

        print(
            "---------- multiline keys[",
            "array" if is_array else "table",
            "]------------:",
        )
        var keys = parse_multiline_keys(data, idx)
        print(
            "[",
            ".".join([StringSlice(unsafe_from_utf8=k) for k in keys]),
            "]",
            sep="",
        )
        var values = parse_kv_pairs[NewLine, SquareBracketOpen](data, idx)
        print(
            "----------- multiline values -------------:\n", values.__repr__()
        )
        var default_cont = (
            toml.TomlType[content.origin]
            .new_array() if is_array else toml.TomlType[content.origin]
            .new_table()
        )

        # var is_subset = all(map[keys_are_equal[o=content.origin]](zip(last_keys, keys)))
        var container: Pointer[toml.TomlType[content.origin], origin_of(base)]

        var is_arr_nested = (
            len(last_keys) > 0
            and all(map[tp_eq[content.origin]](zip(last_keys, keys)))
            and len(keys[len(last_keys) :]) > 0
        )
        print("count of base:", len(last_keys))
        print(
            "is really subset:",
            all(map[tp_eq[content.origin]](zip(last_keys, keys))),
        )
        print("count of keys after base:", len(keys[len(last_keys) :]))

        if not is_arr_nested:
            print("base collection")
            ref cont = get_container_ref(keys, base, default=default_cont^)
            container = Pointer(to=cont)
            last_base = container if is_array else Pointer(to=base)
            last_keys = keys^ if is_array else []

        else:
            # keys is a subset of last_keys
            # Assume keys is larger or the same as last_keys
            # var tp = "array" if default_cont.inner.isa[
            #     toml.TomlType[content.origin].OpaqueArray
            # ]() else "table"
            print("relative collection")
            # print(
            #     "nested collection. Creating a container with default type:",
            #     tp,
            #     ". Current multiline type is:",
            #     "array" if is_array else "table",
            #     "and last base type is:",
            #     "array" if last_base[].inner.isa[
            #         toml.TomlType[content.origin].OpaqueArray
            #     ]() else "table",
            # )
            # print(
            #     "previous keys: [",
            #     ",".join([StringSlice(unsafe_from_utf8=k) for k in last_keys]),
            #     "] and len of:",
            #     len(last_keys),
            #     sep="",
            # )
            # print(
            #     "nested keys to use: [",
            #     ",".join(
            #         [
            #             StringSlice(unsafe_from_utf8=k)
            #             for k in keys[len(last_keys) :]
            #         ]
            #     ),
            #     "]",
            #     sep="",
            # )
            ref cont = get_container_ref(
                keys[len(last_keys) :],
                last_base[],
                default=default_cont^,
            )
            container = Pointer(to=cont)

        container[] = values^
    # print("done parsing toml!")
    return base^


fn parse_toml(content: StringSlice) -> Optional[toml.TomlType[content.origin]]:
    try:
        return parse_toml_raises(content)
    except:
        return None


fn toml_to_tagged_json(content: StringSlice[...]) raises -> String:
    var toml_values = parse_toml_raises(content)
    return toml_values.__repr__()
