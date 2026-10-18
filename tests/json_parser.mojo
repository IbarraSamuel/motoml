from motoml.types.toml import Toml


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

    def __init__(out self, source: String):
        self.source = String(source)
        self.bytes = List[Byte]()
        for byte in source.bytes():
            self.bytes.append(byte)
        self.position = 0

    def parse(mut self) raises -> Toml:
        self.skip_whitespace()
        var result = self.parse_value()
        self.skip_whitespace()
        if self.position != self.source.byte_length():
            raise "Unexpected trailing content in JSON."
        return result^

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

    def parse_value(mut self) raises -> Toml:
        self.skip_whitespace()
        if self.position >= self.source.byte_length():
            raise "Unexpected end of JSON."

        var c = self.byte_at(self.position)
        if c == Quote:
            return Toml.String(self.parse_string())
        if c == OpenObject:
            return self.parse_object()
        if c == OpenArray:
            return self.parse_array()
        if c == Byte(ord("t")):
            self.expect_literal("true")
            return Toml.Boolean(True)
        if c == Byte(ord("f")):
            self.expect_literal("false")
            return Toml.Boolean(False)
        if c == Byte(ord("n")):
            self.expect_literal("null")
            return materialize[Toml.NaN]()
        return self.parse_number()

    def parse_array(mut self) raises -> Toml:
        self.position += 1
        self.skip_whitespace()
        var values = List[Toml]()
        if self.byte_at(self.position) == CloseArray:
            self.position += 1
            return Toml.Array(values^)

        while True:
            values.append(self.parse_value())
            self.skip_whitespace()
            var c = self.byte_at(self.position)
            if c == CloseArray:
                self.position += 1
                return Toml.Array(values^)
            if c != Comma:
                raise "Expected ',' or ']' in JSON array."
            self.position += 1

    def parse_object(mut self) raises -> Toml:
        self.position += 1
        self.skip_whitespace()
        var values = Dict[String, Toml](capacity=16)
        if self.byte_at(self.position) == CloseObject:
            self.position += 1
            return Toml.Table(values^)

        while True:
            self.skip_whitespace()
            if self.byte_at(self.position) != Quote:
                raise "Expected a quoted key in JSON object."
            var key = self.parse_string()
            self.skip_whitespace()
            if self.byte_at(self.position) != Colon:
                raise "Expected ':' after JSON object key."
            self.position += 1
            values[key] = self.parse_value()
            self.skip_whitespace()
            var c = self.byte_at(self.position)
            if c == CloseObject:
                self.position += 1
                return Toml.Table(values^)
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

    def parse_number(mut self) raises -> Toml:
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
            return Toml.Float(Float64(number))
        return Toml.Integer(Int(number))

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


def parse_json(source: String) raises -> Toml:
    var parser = JsonParser(String(source))
    return parser.parse()


def translate_json_to_types(var json: Toml) raises -> Toml:
    if case .Array = json:
        var values = json^.unsafe_take[List[Toml]]()
        var translated = List[Toml]()
        for var value in values^:
            translated.append(translate_json_to_types(value^))
        return Toml.Array(translated^)

    if case .Table = json:
        var values = json^.unsafe_take[Dict[String, Toml]]()
        if len(values) == 2 and "type" in values and "value" in values:
            var type = values.pop("type")
            var value = values.pop("value")
            if case (.String(var kind), .String(var text)) = (type^, value^):
                var translated_value = Toml.String(text)
                if kind == "integer":
                    translated_value = Toml.Integer(Int(text))
                elif kind == "float":
                    if text == "nan":
                        translated_value = materialize[Toml.NaN]()
                    else:
                        translated_value = Toml.Float(Float64(text))

                var translated = Dict[String, Toml](capacity=2)
                translated["type"] = Toml.String(kind)
                translated["value"] = translated_value^
                return Toml.Table(translated^)

        var translated = Dict[String, Toml](capacity=len(values))

        def ins(var k: String, var v: Toml) {mut translated}:
            try:
                translated[k] = translate_json_to_types(v^)
            except:
                pass

        for var item in values.take_items():
            item^.deinit_with(ins)

        return Toml.Table(translated^)

    return json^
