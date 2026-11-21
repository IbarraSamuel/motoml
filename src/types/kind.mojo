"""Public TOML value kinds (`Kind`) and runtime tag (`KindTag`)."""


__enum KindTag(Equatable, ImplicitlyCopyable, Writable):
    """Runtime kind tag returned by `Toml.kind()`."""

    case String
    case Integer
    case Float
    case Boolean
    case Date
    case Time
    case DateTime
    case Array
    case Table
    case Missing

    @always_inline
    def __eq__[id: Int](self, other: _Kind[id]) -> Bool:
        return Int(self._get_enum_discriminant()) == id

    @always_inline
    def __ne__[id: Int](self, other: _Kind[id]) -> Bool:
        return Int(self._get_enum_discriminant()) != id

    def write_to(self, mut w: Some[Writer]):
        match self:
            case .String:
                w.write("String")
            case .Integer:
                w.write("Integer")
            case .Float:
                w.write("Float")
            case .Boolean:
                w.write("Boolean")
            case .Date:
                w.write("Date")
            case .Time:
                w.write("Time")
            case .DateTime:
                w.write("DateTime")
            case .Array:
                w.write("Array")
            case .Table:
                w.write("Table")
            case .Missing:
                w.write("Missing")


@fieldwise_init
struct _Kind[id: Int](
    Equatable, ImplicitlyCopyable, TrivialRegisterPassable, Writable
):
    """Compile-time kind token used to cast and inspect `Toml` values."""

    @always_inline
    def __eq__(self, other: KindTag) -> Bool:
        return Self.id == Int(other._get_enum_discriminant())

    @always_inline
    def __ne__(self, other: KindTag) -> Bool:
        return Self.id != Int(other._get_enum_discriminant())

    @always_inline
    def __eq__[other_id: Int](self, other: _Kind[other_id]) -> Bool:
        return Self.id == other_id

    @always_inline
    def __ne__[other_id: Int](self, other: _Kind[other_id]) -> Bool:
        return Self.id != other_id

    def write_to(self, mut w: Some[Writer]):
        comptime match Self.id:
            case 0:
                w.write("String")
            case 1:
                w.write("Integer")
            case 2:
                w.write("Float")
            case 3:
                w.write("Boolean")
            case 4:
                w.write("Date")
            case 5:
                w.write("Time")
            case 6:
                w.write("DateTime")
            case 7:
                w.write("Array")
            case 8:
                w.write("Table")
            case _:
                w.write("Missing")


struct Kind:
    """Public TOML value kinds (`Kind.String`, `Kind.Integer`, etc.)."""

    comptime String = _Kind[0]()
    comptime Integer = _Kind[1]()
    comptime Float = _Kind[2]()
    comptime Boolean = _Kind[3]()
    comptime Date = _Kind[4]()
    comptime Time = _Kind[5]()
    comptime DateTime = _Kind[6]()
    comptime Array = _Kind[7]()
    comptime Table = _Kind[8]()
    comptime Missing = _Kind[9]()
