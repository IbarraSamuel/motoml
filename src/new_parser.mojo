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

import . toml_types as toml

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
    quote_type: Byte, *, ignore_escape: Bool
](data: Span[Byte], mut idx: Int) -> Span[Byte, data.origin]:
    idx += 3
    var value_init = idx
    idx += 3

    while (
        data[idx] != quote_type
        or data[idx - 1] != quote_type
        or data[idx - 2] != quote_type
        or (data[idx - 3] == Escape and not ignore_escape)
    ):
        idx += 1

    # move two if there is a end like: """""
    # comptime if ignore_escape:
    #     return data[value_init : idx - 2]

    if len(data) > idx + 1 and data[idx + 1] == quote_type:
        idx += 1
    if len(data) > idx + 1 and data[idx + 1] == quote_type:
        idx += 1
    # When it stopped, the value already have two quotes, remove them from value
    return data[value_init : idx - 2]


fn parse_quoted_string[
    quote_type: Byte, *, ignore_escape: Bool
](data: Span[Byte], mut idx: Int) -> Span[Byte, data.origin]:
    idx += 1
    var value_init = idx

    while data[idx] != quote_type:
        idx += 1

        comptime if not ignore_escape:
            if data[idx] == quote_type:
                var n_esc = 0
                while data[idx - n_esc - 1] == Escape:
                    n_esc += 1

                if n_esc % 2 != 0:
                    idx += 1

    return data[value_init:idx]


fn parse_inline_array(
    data: Span[mut=False, Byte], mut idx: Int
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
](data: Span[mut=False, Byte], mut idx: Int) raises -> toml.TomlType[
    data.origin
]:
    """Returns end of value + 1."""
    # print("parsing value at idx: ", idx)
    comptime lower, upper = Byte(ord("0")), Byte(ord("9"))
    comptime INT_AGG, DEC_AGG = 10.0, 0.1
    comptime neg, pos = Byte(ord("-")), Byte(ord("+"))
    # var all_is_digit = True
    # var has_period = False

    if data[idx : idx + 4] == "true".as_bytes():
        idx += 3
        return toml.TomlType[data.origin](boolean=True)

    elif data[idx : idx + 5] == "false".as_bytes():
        idx += 4
        return toml.TomlType[data.origin](boolean=False)

    elif data[idx : idx + 3] == "nan".as_bytes():
        idx += 2
        return toml.TomlType[data.origin](none=None)
    elif data[idx : idx + 3] == "inf".as_bytes():
        idx += 2
        return toml.TomlType[data.origin](float=Float64.MAX)
    elif data[idx : idx + 4] == "-inf".as_bytes():
        idx += 3
        return toml.TomlType[data.origin](float=Float64.MIN)
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

    # TODO: Add new dtypes
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
    var k = data[v_init:idx]
    # var v = StringSlice(unsafe_from_utf8=data[v_init:idx])
    # Roll back one step because we finalized all time in the next item
    idx -= 1
    if flt:
        try:
            var vi = atof(StringSlice(unsafe_from_utf8=k))
            return toml.TomlType[data.origin](float=vi)
        except:
            raise (
                "should be a float but it's not a float: {}.".format(
                    StringSlice(unsafe_from_utf8=k)
                )
            )

    else:
        try:
            var vi = atol(StringSlice(unsafe_from_utf8=k))
            return toml.TomlType[data.origin](integer=vi)
        except:
            raise (
                "should be a int but it's not a integer: {}".format(
                    StringSlice(unsafe_from_utf8=k)
                )
            )


fn parse_value[
    end_char: Byte
](data: Span[mut=False, Byte], mut idx: Int) raises -> toml.TomlType[
    data.origin
]:
    # Assumes the first char is the first value of the value to parse.
    if data[idx] == DoubleQuote:
        if data[idx + 1] == DoubleQuote and data[idx + 2] == DoubleQuote:
            # print("value is a triple double quote string")
            var s = parse_multiline_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            return toml.TomlType[data.origin](
                string=toml.StringRef(s, literal=False, multiline=True)
            )
        else:
            # print("value is double quote string")
            var s = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            return toml.TomlType[data.origin](
                string=toml.StringRef(s, literal=False, multiline=False)
            )
    elif data[idx] == SingleQuote:
        if data[idx + 1] == SingleQuote and data[idx + 2] == SingleQuote:
            # print("value is a triple single quote string")
            var s = parse_multiline_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return toml.TomlType[data.origin](
                string=toml.StringRef(s, literal=True, multiline=True)
            )
        else:
            # print("value is single quote string")
            var s = parse_quoted_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            return toml.TomlType[data.origin](
                string=toml.StringRef(s, literal=True, multiline=False)
            )
    elif data[idx] == SquareBracketOpen:
        idx += 1
        # print("parsing inline array...")
        return parse_inline_array(data, idx)
        # print("last multiline array codepoint parsed is:", Codepoint(data[idx]))
    elif data[idx] == CurlyBracketOpen:
        idx += 1
        # print("parsing inline table...")
        skip_blanks_and_comments(data, idx)
        var inline_tb = parse_kv_pairs[
            separator=Comma, end_char=CurlyBracketClose
        ](data, idx)
        return toml.TomlType[data.origin](table=inline_tb^)
        # print("last multiline table codepoint parsed is:", Codepoint(data[idx]))
    else:
        return string_to_type[end_char](data, idx)


fn get_container_ref[
    o: ImmutOrigin, //, log: Bool = False
](
    keys: Span[toml.StringRef[o]],
    mut base: toml.TomlType[keys.T.origin].OpaqueTable,
    *,
    var default: toml.TomlType[o],  # it's any container-like
) -> ref[base] toml.TomlType[o]:
    var is_array = default.inner.isa[toml.TomlType[o].OpaqueArray]()
    var cont = Pointer[origin=MutAnyOrigin](to=base)
    for k in keys[: len(keys) - 1]:
        comptime if log:
            print(
                "|> k -> '{}' ".format(StringSlice(unsafe_from_utf8=k.value)),
                end="",
            )

        ref inner_v = cont[].setdefault(
            k,
            toml.TomlType[o].new_table().move_to_addr(),
        )
        cont = Pointer(
            to=inner_v.bitcast[toml.TomlType[o]]()
            .unsafe_origin_cast[MutAnyOrigin]()[]
            .inner[toml.TomlType[o].OpaqueTable]
        )

    ref k = keys[len(keys) - 1]

    comptime if log:
        print("|> k -> '{}'".format(StringSlice(unsafe_from_utf8=k.value)))
    ref pre_last = cont[]
    var last = pre_last.setdefault(k, default^.move_to_addr()).bitcast[
        toml.TomlType[o]
    ]()

    return last[]
    # if not is_array:
    #     # just refer to the placeholder of the key.
    #     return last[]

    # # Add a last element and refer to it. So we can modify the last element.
    # ref arr = last[].as_opaque_array()
    # arr.append(toml.TomlType[o].new_table().move_to_addr())
    # return arr[len(arr) - 1].bitcast[toml.TomlType[o]]()[]


# fn store_in_container[
#     o: Origin, //
# ](
#     keys: Span[Span[Byte, o]],
#     mut base: toml.TomlType[o].OpaqueTable,
#     *,
#     var store_obj: toml.TomlType[o],
# ):
#     var cont = Pointer[origin=MutAnyOrigin](to=base)
#     for k in keys[: len(keys) - 1]:
#         ref inner_v = base.setdefault(
#             StringSlice(unsafe_from_utf8=k),
#             toml.TomlType[o].new_table().move_to_addr(),
#         )
#         cont = Pointer(
#             to=inner_v.bitcast[toml.TomlType[o]]()
#             .unsafe_origin_cast[MutAnyOrigin]()[]
#             .inner[toml.TomlType[o].OpaqueTable]
#         )

#     var k = StringSlice(unsafe_from_utf8=keys[len(keys) - 1])
#     ref pre_last = cont[]
#     var default = toml.TomlType[o].new_table()
#     var last = pre_last.setdefault(k, default^.move_to_addr()).bitcast[
#         toml.TomlType[o]
#     ]()
#     last[] = store_obj^


fn parse_keys[
    o: ImmutOrigin, //, close_char: Byte
](
    data: Span[Byte, o], mut idx: Int, var key_base: List[toml.StringRef[o]]
) -> List[toml.StringRef[o]]:
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
    var key: Optional[toml.StringRef[o]] = {}

    while (chr := data[idx]) != close_char and idx < len(data):
        if chr == SingleQuote:
            var k = parse_quoted_string[SingleQuote, ignore_escape=True](
                data, idx
            )
            key = toml.StringRef(k, literal=True, multiline=False)
            idx += 1
            continue
        elif chr == DoubleQuote:
            var k = parse_quoted_string[DoubleQuote, ignore_escape=False](
                data, idx
            )
            # var is_literal = Escape not in k
            key = toml.StringRef(k, literal=False, multiline=False)
            idx += 1
            continue
        elif not key and (chr == Space or chr == Tab):
            var k = data[key_init:idx]
            key = toml.StringRef(k, literal=False, multiline=False)
            skip[Space, Tab](data, idx)
            continue
        elif chr == Period:
            if not key:
                key = toml.StringRef(
                    data[key_init:idx], literal=False, multiline=False
                )

            # store the next level in the key_base list
            key_base.append(key.unsafe_take())
            # skip dot
            idx += 1
            # Skip any space between parsed element and next key
            skip[Space, Tab](data, idx)
            # Return the inner element?
            return parse_keys[close_char](data, idx, key_base^)

        idx += 1

    if not key:
        key = toml.StringRef(data[key_init:idx], literal=False, multiline=False)

    var k = key.unsafe_take()
    key_base.append(k^)
    return key_base^


fn parse_kv_pairs[
    separator: Byte, end_char: Byte, *, log: Bool = False
](data: Span[mut=False, Byte], mut idx: Int) raises -> toml.TomlType[
    data.origin
].OpaqueTable:
    """This function expect to be on top of the value to start parsing. So item=1.
    End at the last value + 1.
    """

    comptime if log:
        print("++ kcreate new empty table container")
    var table = toml.TomlType[data.origin].OpaqueTable()
    while idx < len(data) and data[idx] != end_char:
        # Base is always a new table because you are not parsing
        # something on multiline mode.
        var key_base = List[toml.StringRef[data.origin]]()

        comptime if log:
            print("Parsing inline keys...")

        var keys = parse_keys[Equal](data, idx, key_base^)

        comptime if log:
            print(
                "inline keys -> <",
                ",".join([StringSlice(unsafe_from_utf8=k.value) for k in keys]),
                ">",
                sep="",
            )
        idx += 1
        skip[Space, Tab](data, idx)
        var v = parse_value[end_char](data, idx)

        comptime if log:
            print("inline value -> '", v.__repr__(), "'", sep="")
            print("Getting container ref...")
        idx += 1

        _ = get_container_ref[o = data.origin](keys, table, default=v^)

        # var kk = StringSlice[mut=False](unsafe_from_utf8=keys[-1])
        comptime if log:
            print("container found and data saved!")
        stop_at[separator, end_char](data, idx)
        if data[idx] == end_char or idx >= len(data):
            break

        # we are at separator
        skip[separator](data, idx)
        skip_blanks_and_comments(data, idx)
    # _ = get_container_ref[o = data.origin](keys, table, default=v^)
    return table^


fn parse_multiline_keys(
    data: Span[mut=False, Byte], mut idx: Int
) raises -> List[toml.StringRef[data.origin]]:
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


@always_inline
fn skip[*chars: Byte](data: Span[Byte], mut idx: Int):
    while idx < len(data):
        comptime for i in range(Variadic.size(chars)):
            comptime c = chars[i]
            if data[idx] == c:
                idx += 1
                break
        else:
            return


fn stop_at[*chars: Byte](data: Span[Byte], mut idx: Int):
    while idx < len(data):
        comptime for i in range(Variadic.size(chars)):
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


fn tp_eq[
    o: ImmutOrigin
](v: Tuple[toml.StringRef[o], toml.StringRef[o]]) -> Bool:
    # TODO: Evaluate if need to parse string in this stage
    return v[0] == v[1]


# fn parse_multiline_collections_new[
#     *, log: Bool = True
# ](
#     data: Span[Byte],
#     mut idx: Int,
#     mut base: toml.TomlType[data.origin],
#     base_keys: Span[Span[Byte, data.origin]],
#     nested: UnsafePointer[toml.TomlType[data.origin], MutAnyOrigin],
# ) raises:
#     # Assume current container is a table where I need to push each kv found
#     while idx < len(data):
#         var is_array = data[idx + 1] == SquareBracketOpen
#         idx += 1 + Int(is_array)
#         var keys = parse_multiline_keys(data, idx)
#         var values = parse_kv_pairs[NewLine, SquareBracketOpen](data, idx)
#         var def_cont = base.new_array() if is_array else base.new_table()

#         var should_be_nested = (
#             len(base_keys) > 0
#             and len(keys[len(base_keys) :]) > 0
#             and all(map[tp_eq[data.origin]](zip(base_keys, keys)))
#         )

#         comptime if log:
#             print(
#                 "---------- multiline keys[",
#                 "array" if is_array else "table",
#                 "] [nested?:",
#                 should_be_nested,
#                 "]------------:",
#             )
#             print(
#                 "[",
#                 ".".join([StringSlice(unsafe_from_utf8=k) for k in keys]),
#                 "]",
#                 sep="",
#             )
#             print(
#                 "----------- multiline values -------------:\n",
#                 values.__repr__(),
#             )

#         var new_keys = keys[len(base_keys) :] if should_be_nested else keys
#         var new_base = Pointer(to=nested[]) if should_be_nested else Pointer(
#             to=base
#         )

#         ref cont = get_container_ref(new_keys, new_base[], default=def_cont^)
#         cont = values^

#         if is_array:
#             print("going deeper...")
#             parse_multiline_collections_new[log=log](
#                 data, idx, new_base[], keys, UnsafePointer(to=cont)
#             )

#         if not should_be_nested and Pointer(to=base) != Pointer(to=nested[]):
#             print("going out...")
#             return


fn parse_multiline_collections[
    *, log: Bool = True
](
    data: Span[mut=False, Byte],
    mut idx: Int,
    mut base: toml.TomlType[data.origin].OpaqueTable,
    # base_keys: Span[Span[Byte, data.origin]],
    # nested: UnsafePointer[toml.TomlType[data.origin], MutAnyOrigin],
) raises:
    # Assume current container is a table where I need to push each kv found
    var contexts: List[
        Tuple[
            List[toml.StringRef[data.origin]],
            Pointer[toml.TomlType[data.origin].OpaqueTable, origin_of(base)],
        ]
    ] = [(List[toml.StringRef[data.origin]](), Pointer(to=base))]

    while idx < len(data):
        var is_array = data[idx + 1] == SquareBracketOpen
        idx += 1 + Int(is_array)

        comptime if log:
            print(
                "---------- multiline keys[",
                "array" if is_array else "table",
                "]------------:",
            )
        var keys = parse_multiline_keys(data, idx)

        comptime if log:
            print(
                "[" * (1 + Int(is_array)),
                _repr_keys(keys),
                "]" * (1 + Int(is_array)),
                sep="",
            )

        comptime if log:
            print("----------- multiline values -------------:")
        var values = parse_kv_pairs[NewLine, SquareBracketOpen, log=log](
            data, idx
        )

        comptime if log:
            print(
                {
                    StringSlice(unsafe_from_utf8=kv.key.value): toml.TomlType[
                        data.origin
                    ]
                    .from_addr(kv.value)
                    .__repr__()
                    for kv in values.items()
                }
            )

        var def_cont = (
            toml.TomlType[data.origin]
            .new_array() if is_array else toml.TomlType[data.origin]
            .new_table()
        )

        # Check each last context and pop if current is not a subset untill it is.
        var pair = contexts.pop()
        var base_keys, ctx = pair[0][:], pair[1]

        comptime if log:
            print(" ????? Finding context to store table...")
        while len(contexts) > 0:
            comptime if log:
                print(
                    "compare: `{}` vs `{}`".format(
                        _repr_keys(base_keys), _repr_keys(keys)
                    )
                )
            if len(keys) > len(base_keys) and all(
                map[tp_eq[data.origin]](zip(base_keys, keys))
            ):
                comptime if log:
                    print(
                        "found that current key is nested on key: `{}`".format(
                            _repr_keys(base_keys)
                        ),
                    )
                break

            pair = contexts.pop()
            base_keys, ctx = pair[0][:], pair[1]
        else:
            comptime if log:
                print(
                    "using base container (root) with base keys:",
                    _repr_keys(base_keys),
                )

        # Here we are at the right context
        # var should_be_nested = (
        #     len(base_keys) > 0
        #     and len(keys[len(base_keys) :]) > 0
        #     and all(map[tp_eq[data.origin]](zip(base_keys, keys)))
        # )

        var rltv_keys = keys[len(base_keys) :]

        comptime if log:
            print(
                "[i] Keys used in the current store proc: ->>",
                _repr_keys(rltv_keys),
                "with the value to store as:",
                [
                    "{}: {}".format(
                        StringSlice(unsafe_from_utf8=kv.key.value),
                        kv.value.bitcast[
                            toml.TomlType[data.origin]
                        ]()[].__repr__(),
                    )
                    for kv in values.items()
                ],
            )

        comptime if log:
            print(">> Getting container from ctx...")
        var cont = Pointer(
            to=get_container_ref[log=log](rltv_keys, ctx[], default=def_cont^)
        )

        comptime if log:
            print(">> store value into the container...")

        if is_array:
            ref arr = cont[].as_opaque_array()
            arr.append(toml.TomlType[data.origin].new_table().move_to_addr())
            cont = Pointer(
                to=arr[len(arr) - 1]
                .bitcast[toml.TomlType[data.origin]]()
                .unsafe_origin_cast[origin_of(base)]()[]
            )

        cont[].as_opaque_table().update(values)

        # cont = values^

        # if is_array:
        #     print("going deeper...")
        #     parse_multiline_collections_new[log=log](
        #         data, idx, new_base[], keys, UnsafePointer(to=cont)
        #     )

        # if not should_be_nested and Pointer(to=base) != Pointer(to=nested[]):
        #     print("going out...")
        #     return

        comptime if log:
            print(
                "append back base. `{}`".format(
                    _repr_keys(base_keys),
                )
            )
        contexts.append(pair^)

        comptime if log:
            print("append new keys and ctx. `{}`".format(_repr_keys(keys)))
        var new_ctx = (keys^, Pointer(to=cont[].as_opaque_table()))
        contexts.append(new_ctx^)

        comptime if log:
            print("Current base repr:", _repr_dict(base))


fn _repr_keys[o: ImmutOrigin](v: Span[toml.StringRef[o]]) -> String:
    var r = ".".join([StringSlice(unsafe_from_utf8=k.value) for k in v])
    return r


fn _repr_dict[o: ImmutOrigin](v: toml.TomlType[o].OpaqueTable) -> String:
    var r = [
        "{}: {}".format(
            StringSlice(unsafe_from_utf8=kv.key.value),
            kv.value.bitcast[toml.TomlType[o]]()[].__repr__(),
        )
        for kv in v.items()
    ]
    return String(r)


fn parse_toml_raises[
    *, log: Bool = False
](content: StringSlice) raises -> toml.TomlType[content.origin]:
    var data = content.as_bytes()

    var idx = 0
    skip_blanks_and_comments(data, idx)

    if idx >= len(data):
        return toml.TomlType[content.origin].new_table()

    comptime if log:
        print("parsing initial kv pairs...")
    var base = parse_kv_pairs[NewLine, SquareBracketOpen, log=log](data, idx)

    comptime if log:
        print("end parsing initial kv pairs...")

    parse_multiline_collections[log=log](data, idx, base)

    comptime if log:
        print("done parsing toml!")
    return toml.TomlType[content.origin](table=base^)


fn parse_toml[
    *, log: Bool = False
](content: StringSlice) -> Optional[toml.TomlType[content.origin]]:
    try:
        return parse_toml_raises[log=log](content)
    except:
        return None


fn toml_to_tagged_json[
    *, log: Bool = False
](content: StringSlice[...]) raises -> String:
    var toml_values = parse_toml_raises[log=log](content)
    return toml_values.__repr__()
