from hashlib import Hasher
from os import abort


# Table key needs to be pre-process because could be changed by unicode escapes
struct StringRef[origin: ImmutOrigin](KeyElement):
    comptime CommonEscape: Variadic.ValuesOfType[
        Tuple[String, String]
    ] = Variadic.values[
        ("\b", "\\b"),
        ("\t", "\\t"),
        ("\n", "\\n"),
        ("\f", "\\f"),
        ("\r", "\\r"),
    ]
    comptime BackSlash = "\\"
    comptime DoubleQuote = '"'

    var is_literal: Bool
    var is_multiline: Bool
    var value: Span[Byte, Self.origin]

    fn __init__(
        out self,
        value: Span[Byte, Self.origin],
        *,
        literal: Bool,
        multiline: Bool,
    ):
        self.value = value
        self.is_literal = literal
        self.is_multiline = multiline

    fn __eq__(self, other: Self) -> Bool:
        return self.calc_value() == other.calc_value()
        # return self.is_literal == other.is_literal and self.value == other.value

    fn __hash__[H: Hasher](self, mut h: H):
        h.update(self.calc_value())

    fn as_pure_slice(self) -> StringSlice[Self.origin]:
        return StringSlice(unsafe_from_utf8=self.value)

    fn calc_value(self) -> String:
        # print("original string: `{}`".format(self.as_pure_slice()))
        var s = String(self.as_pure_slice().removeprefix("\n"))
        # print("stirng whitout prefix: `{}`".format(s))

        # var ss = parse_string_escape(s) if not self.is_literal else s.replace(Self.BackSlash, "\\\\").replace('"', '\\"')
        var ss: String
        if self.is_literal:
            # print("Is literal: -> ", s)
            ss = s.replace(Self.BackSlash, "\\\\").replace('"', '\\"')
        else:
            ss = parse_string_escape(s)

        comptime for i in range(Variadic.size(Self.CommonEscape)):
            comptime Pair: Tuple[String, String] = Self.CommonEscape[i]
            ss = ss.replace(Pair[0], Pair[1])
        return ss


fn _find_escapes[
    *chars: Tuple[Byte, Int]
](ssb: Span[Byte], offset: Int) -> Tuple[Byte, Int, Span[Byte, ssb.origin]]:
    for i, b in enumerate(ssb[offset:]):
        var ii = i + offset
        if b != Byte(ord("\\")):
            continue

        backslash_count = 1
        while backslash_count <= ii and ssb[ii - backslash_count] == Byte(
            ord("\\")
        ):
            backslash_count += 1

        if backslash_count % 2 == 0:
            continue

        # if ii != 0 and ssb[ii - 1] == Byte(ord("\\")):
        #     continue

        var c = ssb[ii + 1]
        comptime for ci in range(Variadic.size(chars)):
            comptime char, span_len = chars[ci]
            if c == char:
                comptime if char == Byte(ord("e")):
                    return char, ii, {}
                else:
                    var sp = ssb[ii + 2 : ii + 2 + span_len]
                    return char, ii, sp

    return Byte(), -1, {}


fn parse_string_escape(v: StringSlice) -> String:
    var ss = String(v)
    # print("parsing string escape for s:", ss)
    var ssb = ss.as_bytes()

    comptime fesc = _find_escapes[
        (Byte(ord("x")), 2),
        (Byte(ord("u")), 4),
        (Byte(ord("U")), 8),
        (Byte(ord("e")), -1),
    ]
    # var search_base = 0
    var char, init, spn = fesc(ssb, 0)

    while init != -1:
        # sleep(0.5)
        comptime (min_n, max_n) = Byte(ord("0")), Byte(ord("9"))
        comptime (min_c, max_c) = Byte(ord("a")), Byte(ord("f"))
        comptime (min_C, max_C) = Byte(ord("A")), Byte(ord("F"))

        var i = init + 2 + len(spn)
        var codepoint: String
        var nc = ssb[i]

        if len(spn) > 0:
            var value: UInt32 = 0
            for ii, byte in enumerate(reversed(spn)):
                var rtv: Byte
                if min_n <= byte and byte <= max_n:
                    rtv = byte - min_n
                elif min_C <= byte and byte <= max_C:
                    rtv = 10 + byte - min_C
                elif min_c <= byte and byte <= max_c:
                    rtv = 10 + byte - min_c
                else:
                    abort("Span doesn't contain a valid hex value")
                value += UInt32(rtv) * UInt32(16**ii)

            if value == 8:
                codepoint = "\b"
            elif value == 9:
                codepoint = "\t"
            elif value == 10:
                codepoint = "\n"
            elif value == 12:
                codepoint = "\f"
            elif value == 13:
                codepoint = "\r"
            elif value == 14:
                codepoint = "\f"
            elif value == 27:
                codepoint = "\\u001b"
            elif value >= 0 and value <= 8:
                codepoint = "\\u000{}".format(value)
            elif value >= 10 and value <= 15:
                codepoint = hex(value, prefix="\\u000")
            elif value >= 16 and value <= 31:
                codepoint = hex(value, prefix="\\u00")
            elif value == 92:  # Is a backslash
                codepoint = "\\\\"
            elif value == 127:
                codepoint = hex(value, prefix="\\u00")
            else:
                codepoint = String(Codepoint(unsafe_unchecked_codepoint=value))

        elif char == Byte(ord("e")):
            # print("found \\e at {} under char: {}".format(init, ss))
            if nc == Byte(ord("[")):
                for bi, b in enumerate(ssb[i + 1 :]):
                    if b == Byte(ord("m")):
                        i += bi + 1
                        break
                else:
                    abort(
                        "\\e scape found, and [ found but not found m at the"
                        " end."
                    )
                codepoint = ""
            else:
                codepoint = "\\u001b"
        else:
            abort("error! value not found")
        ss = (
            StringSlice(unsafe_from_utf8=ssb[:init])
            + codepoint
            + StringSlice(unsafe_from_utf8=ssb[i:])
        )
        ssb = ss.as_bytes()
        # should be handled distinct if you replace things up
        # search_base += init + 1

        char, init, spn = fesc(ssb, init + 1)
        # x, u, U, e = _find_escapes(ssb[search_base:])
        # init = x if x != -1 else u if u != -1 else U if U != -1 else e

    # print("Codepoint Replacements done: Final value is:", ss)
    var last_esc = -1
    while (esc := ss.find("\\", last_esc + 1)) != -1:
        last_esc = esc

        # if The scape character is escaped
        if ss[byte = esc + 1] == "\\":
            # Don't use this or the next escaped character
            last_esc += 1
            continue

        # if the next value is not identified as a "space"
        if not ss[byte = esc + 1].isspace():
            continue

        esc += 1

        while esc < len(ss) and ss[byte=esc].isspace[True]():
            esc += 1

        ss = ss[:last_esc] + ss[esc:]
        # ssb = ss.as_bytes()

    last_qte = -1
    # print("Before quote replace:", ss)
    while (qte := ss.find('"', last_qte + 1)) != -1:
        last_qte = qte

        var esc_count = 0
        while esc_count <= qte - 1 and ss[byte = qte - 1 - esc_count] == "\\":
            esc_count += 1

        # print("for string: '{}' esc count:".format(ss), esc_count)
        if esc_count != 0 and esc_count % 2 != 0:
            continue

        last_qte += 1
        ss = ss[:qte] + "\\" + ss[qte:]
    # if ssb[len(ssb) - 1] == Byte(ord("\\")) and (
    #     len(ssb) == 1 or ssb[len(ssb) - 2] != Byte(ord("\\"))
    # ):
    #     ss = String(ss[: len(ss) - 1])
    return ss
