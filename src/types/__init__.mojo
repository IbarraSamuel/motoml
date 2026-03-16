import std.os as os
from std.builtin.rebind import downcast
from std.sys.intrinsics import likely, _type_is_eq
from std.reflection import get_type_name
from std.utils import Variant
from std.collections.dict import _DictEntryIter
from std.hashlib import Hasher
from std.utils.numerics import FPUtils
from std.builtin._format_float import _to_decimal
from std.python import ConvertibleToPython, PythonObject

from .string_ref import StringRef
from .tempo import Date, DateTime, Time

# TYPES
comptime Integer = Int
comptime Float = Float64
comptime Boolean = Bool
# comptime OffsetDateTime = DateTime[WithOffset=True]
# comptime LocalDateTime = DateTime[WithOffset=False]

comptime Opaque[o: MutOrigin] = OpaquePointer[o]
comptime OpaqueArray = List[Opaque[MutExternalOrigin]]
comptime OpaqueTable = Dict[String, Opaque[MutExternalOrigin]]

# TODO: Add new time types

comptime AnyTomlType = Variant[
    String,
    Integer,
    Float,
    NoneType,
    Boolean,
    Date,
    Time,
    DateTime,
    OpaqueArray,
    OpaqueTable,
]


struct TomlRef[toml: ImmutOrigin](Iterable, TrivialRegisterPassable):
    comptime Toml = TomlType
    comptime IteratorType[origin: Origin]: Iterator = Self.Toml.IteratorType[
        Self.toml
    ]
    var pointer: Pointer[Self.Toml, Self.toml]

    def __init__(out self, ref[Self.toml] v: Self.Toml):
        self.pointer = Pointer(to=v)

    def __getitem__(ref self) -> ref[Self.toml] Self.Toml:
        return self.pointer[]

    def __getitem__(ref self, idx: Int) -> ref[Self.toml] Self.Toml:
        return self.pointer[][idx]

    def __getitem__(ref self, key: StringSlice) -> ref[Self.toml] Self.Toml:
        return self.pointer[][key]

    def __iter__(ref self) -> Self.IteratorType[Self.toml]:
        return self.pointer[].__iter__()


struct TomlListIter[
    toml: ImmutOrigin,
](Iterator):
    comptime Element = TomlType
    var pointer: Pointer[Self.Element.OpaqueArray, Self.toml]
    var index: Int

    def __init__(out self, ref[Self.toml] v: Self.Element.OpaqueArray):
        self.pointer = Pointer(to=v)
        self.index = 0

    def __next__(
        mut self,
    ) raises StopIteration -> ref[Self.toml] Self.Element:
        if self.index >= len(self.pointer[]):
            raise StopIteration()

        ref elem = self.pointer[][self.index].bitcast[Self.Element]()[]
        self.index += 1
        return elem


struct TomlTableIter[
    toml: Origin,
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Tuple[String, TomlRef[MutExternalOrigin]]
    comptime IteratorType[origin: Origin]: Iterator = Self
    comptime Toml = TomlType
    var dict_iter: _DictEntryIter[
        mut=Self.toml.mut,
        K=Self.Toml.OpaqueTable.K,
        V=Self.Toml.OpaqueTable.V,
        H=Self.Toml.OpaqueTable.H,
        origin=Self.toml,
    ]

    def __init__(
        out self: TomlTableIter[origin_of(v)],
        ref v: Self.Toml.OpaqueTable,
    ):
        self.dict_iter = v.items()

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    def __next__(
        mut self,
    ) raises StopIteration -> Self.Element:
        ref kv = next(self.dict_iter)

        ref toml_value = kv.value.bitcast[Self.Toml]()[]
        return kv.key, TomlRef(toml_value)


struct TomlType(ConvertibleToPython, Copyable, Iterable, Writable):
    comptime String = String
    # comptime StringLiteral = StringLit[Self.o]
    comptime Integer = Integer
    comptime Float = Float
    comptime NaN = NoneType
    comptime Boolean = Boolean
    comptime Date = Date
    comptime Time = Time
    comptime DateTime = DateTime

    # Store a list of addesses.
    comptime OpaqueArray = OpaqueArray
    comptime OpaqueTable = OpaqueTable

    comptime RefArray[o: ImmutOrigin] = List[TomlRef[o]]
    comptime RefTable[o: ImmutOrigin] = Dict[String, TomlRef[o]]

    # For ease of use of the type
    comptime Array = List[Self]
    comptime Table = Dict[String, Self]

    # Runtime
    var inner: AnyTomlType

    # Iterable
    comptime IteratorType[
        mut: Bool, //, origin: Origin[mut=mut]
    ] = TomlListIter[origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        # upcast origin to self.
        ref array = UnsafePointer(
            to=self.inner[Self.OpaqueArray]
        ).unsafe_origin_cast[origin_of(self)]()[]

        return TomlListIter[origin_of(self)](array)

    def isa[T: AnyType](self) -> Bool:
        comptime if _type_is_eq[T, Self.Array]():
            return self.inner.isa[Self.OpaqueArray]()
        elif _type_is_eq[T, Self.Table]():
            return self.inner.isa[Self.OpaqueTable]()
        elif _type_is_eq[T, Self.OpaqueArray]():
            return False
        elif _type_is_eq[T, Self.OpaqueTable]():
            return False
        else:
            return self.inner.isa[T]()

    @staticmethod
    def from_addr(addr: Opaque) -> ref[addr.origin] Self:
        return addr.bitcast[Self]()[]

    @staticmethod
    def take_from_addr(var addr: Opaque[MutExternalOrigin]) -> Self:
        return addr.bitcast[Self]().take_pointee()

    def move_to_addr(var self) -> Opaque[MutExternalOrigin]:
        var ptr = alloc[Self](1)
        ptr.init_pointee_move(self^)
        return ptr.bitcast[NoneType]()

    def to_addr(mut self) -> Opaque[origin_of(self)]:
        return UnsafePointer(to=self).bitcast[NoneType]()

    # TODO: Ask to provide capacity, to minimize allocations
    @staticmethod
    def new_array(out self: Self):
        self = Self(array=Self.OpaqueArray(capacity=32))

    @staticmethod
    def new_table(out self: Self):
        self = Self(table=Self.OpaqueTable(capacity=32))

    def as_opaque_table(ref self) -> ref[self] Self.OpaqueTable:
        return UnsafePointer(
            to=self.inner[Self.OpaqueTable]
        ).unsafe_origin_cast[origin_of(self)]()[]

    def as_opaque_array(ref self) -> ref[self] Self.OpaqueArray:
        return UnsafePointer(
            to=self.inner[Self.OpaqueArray]
        ).unsafe_origin_cast[origin_of(self)]()[]

    # ==== Access inner values using methods ====

    def string(ref self) -> String:
        return self.inner[Self.String]

    def integer(ref self) -> Self.Integer:
        return self.inner[Self.Integer]

    def float(ref self) -> Self.Float:
        return self.inner[Self.Float]

    def boolean(ref self) -> Self.Boolean:
        return self.inner[Self.Boolean]

    def to_array(deinit self) -> Self.Array:
        """Points to self, because external origin it's managed by self."""
        return [Self.take_from_addr(it) for it in self.inner[Self.OpaqueArray]]

    def to_table(deinit self) -> Self.Table:
        """Points to self, because external origin it's managed by self."""
        return {
            kv.key.copy(): Self.take_from_addr(kv.value)
            for kv in self.inner[Self.OpaqueTable].items()
        }

    def array(self) -> Self.RefArray[origin_of(self.inner)]:
        """Points to self, because external origin it's managed by self."""
        return [
            TomlRef[origin_of(self.inner)](Self.from_addr(it))
            for it in self.inner[Self.OpaqueArray]
        ]

    def table(self) -> Self.RefTable[origin_of(self.inner)]:
        """Points to self, because external origin it's managed by self."""
        return {
            kv.key: TomlRef[origin_of(self.inner)](Self.from_addr(kv.value))
            for kv in self.inner[Self.OpaqueTable].items()
        }

    # For interop with list

    def __getitem__(ref self, idx: Int) -> ref[self] Self:
        return self.inner[Self.OpaqueArray][idx].bitcast[Self]()[]

    def __contains__(ref self, v: StringSlice) -> Bool:
        # Only works for arrays and tables
        if self.isa[Self.Array]():
            for ptrs in self.as_opaque_array():
                if (
                    ptrs.bitcast[Self]()[].isa[Self.String]()
                    and ptrs.bitcast[Self]()[].string() == v
                ):
                    return True
            return False
        elif self.isa[Self.Table]():
            for i in self.as_opaque_table():
                if i == v:
                    return True
            return False
        return False

    # For interop with dict

    def __getitem__(ref self, key: StringSlice) -> ref[self] Self:
        ref table = self.inner[Self.OpaqueTable]

        for kv in table.items():
            if kv.key == key:
                return Self.from_addr(kv.value)

        os.abort("key not found in toml")
        # String(key)
        # os.abort(String("Key '", key, "' not found in TOML table."))

    def items(ref self) -> TomlTableIter[origin_of(self.inner)]:
        return TomlTableIter(self.inner[Self.OpaqueTable])

    def __init__(out self, *, var string: Self.String):
        self.inner = string

    # def __init__(out self, *, var string_literal: Self.StringLiteral):
    #     self.inner = string_literal

    def __init__(out self, *, var integer: Self.Integer):
        self.inner = integer

    def __init__(out self, *, var float: Self.Float):
        self.inner = float

    def __init__(out self, *, var none: NoneType):
        self.inner = none

    def __init__(out self, *, var boolean: Self.Boolean):
        self.inner = boolean

    def __init__(out self, *, var date: Self.Date):
        self.inner = date

    def __init__(out self, *, var time: Self.Time):
        self.inner = time

    def __init__(out self, *, var datetime: Self.DateTime):
        self.inner = datetime

    def __init__(out self, *, var array: Self.OpaqueArray):
        self.inner = array^

    def __init__(out self, *, var table: Self.OpaqueTable):
        self.inner = table^

    def __del__(deinit self):
        ref inner = self.inner

        if inner.isa[self.OpaqueArray]():
            var array = inner.take[self.OpaqueArray]()
            for _ in range(len(array)):
                array.pop().destroy_pointee()
        elif inner.isa[self.OpaqueTable]():
            var table = inner.take[self.OpaqueTable]()
            for v in table.take_items():
                v.value.destroy_pointee()

    def to_python_object(var self) raises -> PythonObject:
        return PythonObject("TomlType is a text for now...")

    def write_to(self, mut w: Some[Writer]):
        ref inner = self.inner
        if inner.isa[self.String]():
            ref s = inner[self.String]
            return w.write('{"type": "string", "value": "', s, '"}')
        elif inner.isa[self.Integer]():
            var intg = inner[self.Integer]
            return w.write('{"type": "integer", "value": "', intg, '"}')
        elif inner.isa[self.Float]():
            var fl = inner[self.Float]
            return w.write('{"type": "float", "value": "', fl, '"}')
        elif inner.isa[self.NaN]():
            return w.write('{"type": "float", "value": "nan"}')
        elif inner.isa[self.Boolean]():
            var value = "true" if inner[self.Boolean] else "false"
            return w.write('{"type": "bool", "value": "', value, '"}')
        elif inner.isa[self.DateTime]():
            var dt = inner[self.DateTime]
            var nm = "datetime-local" if dt.is_local else "datetime"
            return w.write('{"type": "', nm, '", "value": "', dt, '"}')
        elif inner.isa[self.Date]():
            var date = inner[self.Date]
            return w.write('{"type": "date-local", "value": "', date, '"}')
        elif inner.isa[self.Time]():
            var time = inner[self.Time]
            return w.write('{"type": "time-local", "value": "', time, '"}')
        elif inner.isa[self.OpaqueArray]():
            ref array = inner[self.OpaqueArray]
            var values = ", ".join(
                [String(Self.from_addr(addr)) for addr in array]
            )
            return w.write("[", values, "]")

        elif inner.isa[self.OpaqueTable]():
            ref table = inner[self.OpaqueTable]
            var content = ", ".join(
                [
                    String(t'"{kv.key}": {Self.from_addr(kv.value)}')
                    for kv in table.items()
                ]
            )
            return w.write("{", content, "}")
        else:
            os.abort("type to write not identified")
