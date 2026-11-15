from std.math import isnan
from std.collections import Dict, List


struct _JsonNode(Copyable, Movable):
    comptime TAG_NAN = 0
    comptime TAG_STRING = 1
    comptime TAG_INTEGER = 2
    comptime TAG_FLOAT = 3
    comptime TAG_BOOLEAN = 4
    comptime TAG_ARRAY = 5
    comptime TAG_TABLE = 6

    var tag: Int
    var str_val: String
    var int_val: Int
    var float_val: Float64
    var bool_val: Bool
    var arr_children: List[Int]
    var tbl_children: Dict[String, Int]

    def __init__(out self, tag: Int = Self.TAG_NAN):
        self.tag = tag
        self.str_val = String()
        self.int_val = 0
        self.float_val = 0.0
        self.bool_val = False
        self.arr_children = List[Int]()
        self.tbl_children = Dict[String, Int]()


struct JsonDoc(Copyable, Equatable, Movable, Writable):
    """Non-recursive flat-arena JSON AST used by test_toml_suite."""

    var nodes: List[_JsonNode]
    var root: Int

    def __init__(out self):
        self.nodes = List[_JsonNode]()
        self.root = 0

    def add_node(mut self, var node: _JsonNode) -> Int:
        var idx = len(self.nodes)
        self.nodes.append(node^)
        return idx

    def _eq_at(self, idx: Int, other: Self, other_idx: Int) -> Bool:
        ref a = self.nodes[idx]
        ref b = other.nodes[other_idx]
        if a.tag != b.tag:
            return False
        if a.tag == _JsonNode.TAG_NAN:
            return True
        if a.tag == _JsonNode.TAG_STRING:
            return a.str_val == b.str_val
        if a.tag == _JsonNode.TAG_INTEGER:
            return a.int_val == b.int_val
        if a.tag == _JsonNode.TAG_FLOAT:
            return (
                isnan(a.float_val) and isnan(b.float_val)
            ) or a.float_val == b.float_val
        if a.tag == _JsonNode.TAG_BOOLEAN:
            return a.bool_val == b.bool_val
        if a.tag == _JsonNode.TAG_ARRAY:
            if len(a.arr_children) != len(b.arr_children):
                return False
            for i in range(len(a.arr_children)):
                if not self._eq_at(a.arr_children[i], other, b.arr_children[i]):
                    return False
            return True
        if len(a.tbl_children) != len(b.tbl_children):
            return False
        for item in a.tbl_children.items():
            var ob = b.tbl_children.get(item.key)
            if not ob:
                return False
            if not self._eq_at(item.value, other, ob.value()):
                return False
        return True

    def __eq__(self, other: Self) -> Bool:
        if len(self.nodes) == 0 and len(other.nodes) == 0:
            return True
        if len(self.nodes) == 0 or len(other.nodes) == 0:
            return False
        return self._eq_at(self.root, other, other.root)

    def _write_at(self, idx: Int, mut w: Some[Writer]):
        ref n = self.nodes[idx]
        if n.tag == _JsonNode.TAG_NAN:
            w.write("NaN")
        elif n.tag == _JsonNode.TAG_STRING:
            w.write('"', n.str_val, '"')
        elif n.tag == _JsonNode.TAG_INTEGER:
            w.write(n.int_val)
        elif n.tag == _JsonNode.TAG_FLOAT:
            w.write(n.float_val)
        elif n.tag == _JsonNode.TAG_BOOLEAN:
            w.write("true" if n.bool_val else "false")
        elif n.tag == _JsonNode.TAG_ARRAY:
            w.write("[")
            for i in range(len(n.arr_children)):
                if i > 0:
                    w.write(", ")
                self._write_at(n.arr_children[i], w)
            w.write("]")
        else:
            w.write("{")
            var first = True
            for item in n.tbl_children.items():
                if not first:
                    w.write(", ")
                first = False
                w.write('"', item.key, '": ')
                self._write_at(item.value, w)
            w.write("}")

    def write_to(self, mut w: Some[Writer]):
        if len(self.nodes) == 0:
            w.write("<empty>")
            return
        self._write_at(self.root, w)


comptime Quote = Byte(ord('"'))
comptime Backslash = Byte(ord("\\"))
comptime OpenArray = Byte(ord("["))
comptime CloseArray = Byte(ord("]"))
comptime OpenObject = Byte(ord("{"))
comptime CloseObject = Byte(ord("}"))
comptime Colon = Byte(ord(":"))
comptime Comma = Byte(ord(","))


struct JsonParser(Movable):
    var source: String
    var bytes: List[Byte]
    var position: Int
    var doc: JsonDoc

    def __init__(out self, source: String):
        self.source = String(source)
        self.bytes = List[Byte]()
        for byte in source.bytes():
            self.bytes.append(byte)
        self.position = 0
        self.doc = JsonDoc()

    def parse(mut self) raises -> JsonDoc:
        self.skip_whitespace()
        self.doc.root = self.parse_value()
        self.skip_whitespace()
        if self.position != self.source.byte_length():
            raise "Unexpected trailing content in JSON."
        return self.doc.copy()

    def skip_whitespace(mut self):
        while self.position < self.source.byte_length():
            var c = self.byte_at(self.position)
            if (
                c == Byte(ord(" "))
                or c == Byte(ord("\n"))
                or c == Byte(ord("\r"))
                or c == Byte(ord("\t"))
            ):
                self.position += 1
            else:
                return

    def parse_value(mut self) raises -> Int:
        self.skip_whitespace()
        if self.position >= self.source.byte_length():
            raise "Unexpected end of JSON."

        var c = self.byte_at(self.position)
        if c == Quote:
            var n = _JsonNode(_JsonNode.TAG_STRING)
            n.str_val = self.parse_string()
            return self.doc.add_node(n^)
        if c == OpenObject:
            return self.parse_object()
        if c == OpenArray:
            return self.parse_array()
        if c == Byte(ord("t")):
            self.expect_literal("true")
            var n = _JsonNode(_JsonNode.TAG_BOOLEAN)
            n.bool_val = True
            return self.doc.add_node(n^)
        if c == Byte(ord("f")):
            self.expect_literal("false")
            var n = _JsonNode(_JsonNode.TAG_BOOLEAN)
            n.bool_val = False
            return self.doc.add_node(n^)
        if c == Byte(ord("n")):
            self.expect_literal("null")
            return self.doc.add_node(_JsonNode(_JsonNode.TAG_NAN))
        return self.parse_number()

    def parse_array(mut self) raises -> Int:
        self.position += 1
        self.skip_whitespace()
        var children = List[Int]()
        if self.byte_at(self.position) == CloseArray:
            self.position += 1
            var n = _JsonNode(_JsonNode.TAG_ARRAY)
            n.arr_children = children^
            return self.doc.add_node(n^)

        while True:
            children.append(self.parse_value())
            self.skip_whitespace()
            var c = self.byte_at(self.position)
            if c == CloseArray:
                self.position += 1
                var n = _JsonNode(_JsonNode.TAG_ARRAY)
                n.arr_children = children^
                return self.doc.add_node(n^)
            if c != Comma:
                raise "Expected ',' or ']' in JSON array."
            self.position += 1

    def parse_object(mut self) raises -> Int:
        self.position += 1
        self.skip_whitespace()
        var children = Dict[String, Int](capacity=16)
        if self.byte_at(self.position) == CloseObject:
            self.position += 1
            var n = _JsonNode(_JsonNode.TAG_TABLE)
            n.tbl_children = children^
            return self.doc.add_node(n^)

        while True:
            self.skip_whitespace()
            if self.byte_at(self.position) != Quote:
                raise "Expected a quoted key in JSON object."
            var key = self.parse_string()
            self.skip_whitespace()
            if self.byte_at(self.position) != Colon:
                raise "Expected ':' after JSON object key."
            self.position += 1
            children[key] = self.parse_value()
            self.skip_whitespace()
            var c = self.byte_at(self.position)
            if c == CloseObject:
                self.position += 1
                var n = _JsonNode(_JsonNode.TAG_TABLE)
                n.tbl_children = children^
                return self.doc.add_node(n^)
            if c != Comma:
                raise "Expected ',' or '}' in JSON object."
            self.position += 1

    def parse_string(mut self) raises -> String:
        self.position += 1
        var decoded = String()
        var segment_start = self.position

        while self.position < self.source.byte_length():
            var c = self.byte_at(self.position)
            if c == Quote:
                decoded += String(
                    self.source[byte = segment_start : self.position]
                )
                self.position += 1
                return decoded^
            if c == Backslash:
                decoded += String(
                    self.source[byte = segment_start : self.position]
                )
                self.position += 1
                if self.position >= self.source.byte_length():
                    raise "Incomplete escape in JSON string."
                var escaped = self.byte_at(self.position)
                if escaped == Quote:
                    decoded += '"'
                elif escaped == Backslash:
                    decoded += "\\"
                elif escaped == Byte(ord("/")):
                    decoded += "/"
                elif escaped == Byte(ord("b")):
                    decoded += "\b"
                elif escaped == Byte(ord("f")):
                    decoded += "\f"
                elif escaped == Byte(ord("n")):
                    decoded += "\n"
                elif escaped == Byte(ord("r")):
                    decoded += "\r"
                elif escaped == Byte(ord("t")):
                    decoded += "\t"
                elif escaped == Byte(ord("u")):
                    self.position += 1
                    var codepoint = self.parse_hex4()
                    if codepoint >= 0xD800 and codepoint <= 0xDBFF:
                        if (
                            self.position + 5 >= self.source.byte_length()
                            or self.byte_at(self.position) != Backslash
                            or self.byte_at(self.position + 1) != Byte(ord("u"))
                        ):
                            raise "Invalid JSON unicode surrogate pair."
                        self.position += 2
                        var low = self.parse_hex4()
                        codepoint = (
                            0x10000
                            + (codepoint - 0xD800) * 0x400
                            + (low - 0xDC00)
                        )
                    decoded += self.encode_codepoint(codepoint)
                    segment_start = self.position
                    continue
                else:
                    raise "Invalid escape in JSON string."
                self.position += 1
                segment_start = self.position
                continue
            self.position += 1

        raise "Unterminated JSON string."

    def parse_hex4(mut self) raises -> Int:
        var value = 0
        for _ in range(4):
            if self.position >= self.source.byte_length():
                raise "Incomplete unicode escape in JSON string."
            var c = self.byte_at(self.position)
            var digit: Int
            if c >= Byte(ord("0")) and c <= Byte(ord("9")):
                digit = Int(c) - ord("0")
            elif c >= Byte(ord("a")) and c <= Byte(ord("f")):
                digit = Int(c) - ord("a") + 10
            elif c >= Byte(ord("A")) and c <= Byte(ord("F")):
                digit = Int(c) - ord("A") + 10
            else:
                raise "Invalid unicode escape in JSON string."
            value = value * 16 + digit
            self.position += 1
        return value

    def encode_codepoint(self, codepoint: Int) raises -> String:
        return String(Codepoint(unsafe_unchecked_codepoint=UInt32(codepoint)))

    def parse_number(mut self) raises -> Int:
        var start = self.position
        while self.position < self.source.byte_length():
            var c = self.byte_at(self.position)
            if (
                (c >= Byte(ord("0")) and c <= Byte(ord("9")))
                or c == Byte(ord("-"))
                or c == Byte(ord("+"))
                or c == Byte(ord("."))
                or c == Byte(ord("e"))
                or c == Byte(ord("E"))
            ):
                self.position += 1
            else:
                break
        var number = String(self.source[byte = start : self.position])
        if (
            number.find(".") >= 0
            or number.find("e") >= 0
            or number.find("E") >= 0
        ):
            var n = _JsonNode(_JsonNode.TAG_FLOAT)
            n.float_val = Float64(number)
            return self.doc.add_node(n^)
        var n = _JsonNode(_JsonNode.TAG_INTEGER)
        n.int_val = Int(number)
        return self.doc.add_node(n^)

    def expect_literal(mut self, literal: String) raises:
        var literal_bytes = List[Byte]()
        for byte in literal.bytes():
            literal_bytes.append(byte)
        for i in range(literal.byte_length()):
            if (
                self.position + i >= self.source.byte_length()
                or self.byte_at(self.position + i) != literal_bytes[i]
            ):
                raise "Invalid JSON literal."
        self.position += literal.byte_length()

    def byte_at(self, index: Int) -> Byte:
        return self.bytes[index]


def parse_json(source: String) raises -> JsonDoc:
    var parser = JsonParser(String(source))
    return parser.parse()


def _translate_node(src: JsonDoc, idx: Int, mut dst: JsonDoc) raises -> Int:
    ref node = src.nodes[idx]
    if node.tag == _JsonNode.TAG_ARRAY:
        var children = List[Int](capacity=len(node.arr_children))
        for c in node.arr_children:
            children.append(_translate_node(src, c, dst))
        var out = _JsonNode(_JsonNode.TAG_ARRAY)
        out.arr_children = children^
        return dst.add_node(out^)

    if node.tag == _JsonNode.TAG_TABLE:
        if (
            len(node.tbl_children) == 2
            and "type" in node.tbl_children
            and "value" in node.tbl_children
        ):
            var t_idx = node.tbl_children.get("type").value()
            var v_idx = node.tbl_children.get("value").value()
            ref t_node = src.nodes[t_idx]
            ref v_node = src.nodes[v_idx]
            if (
                t_node.tag == _JsonNode.TAG_STRING
                and v_node.tag == _JsonNode.TAG_STRING
            ):
                var kind = t_node.str_val
                var text = v_node.str_val
                var t_out = _JsonNode(_JsonNode.TAG_STRING)
                t_out.str_val = kind
                var new_t = dst.add_node(t_out^)

                var new_v: Int
                if kind == "integer":
                    var iv = _JsonNode(_JsonNode.TAG_INTEGER)
                    iv.int_val = Int(text)
                    new_v = dst.add_node(iv^)
                elif kind == "float":
                    if text == "nan":
                        new_v = dst.add_node(_JsonNode(_JsonNode.TAG_NAN))
                    else:
                        var fv = _JsonNode(_JsonNode.TAG_FLOAT)
                        fv.float_val = Float64(text)
                        new_v = dst.add_node(fv^)
                else:
                    var sv = _JsonNode(_JsonNode.TAG_STRING)
                    sv.str_val = text
                    new_v = dst.add_node(sv^)

                var tbl = Dict[String, Int](capacity=2)
                tbl["type"] = new_t
                tbl["value"] = new_v
                var out = _JsonNode(_JsonNode.TAG_TABLE)
                out.tbl_children = tbl^
                return dst.add_node(out^)

        var tbl = Dict[String, Int](capacity=len(node.tbl_children))
        for item in node.tbl_children.items():
            tbl[item.key] = _translate_node(src, item.value, dst)
        var out = _JsonNode(_JsonNode.TAG_TABLE)
        out.tbl_children = tbl^
        return dst.add_node(out^)

    return dst.add_node(node.copy())


def translate_json_to_types(var json: JsonDoc) raises -> JsonDoc:
    var dst = JsonDoc()
    if len(json.nodes) > 0:
        dst.root = _translate_node(json, json.root, dst)
    return dst^
