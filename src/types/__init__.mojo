from std.builtin.rebind import downcast
from std.sys.intrinsics import likely, _type_is_eq
from std.utils import Variant
from std.collections.dict import _DictEntryIter
from std.hashlib import Hasher
from std.utils.numerics import FPUtils
from std.builtin._format_float import _to_decimal
from std.python import ConvertibleToPython, PythonObject

from std.memory import OwnedPointer

from .string_ref import StringRef
from .tempo import Date, DateTime, Time

# TYPES


struct TomlTypes:
    comptime String = String
    comptime Integer = Int
    comptime Float = Float64
    comptime Boolean = Bool
    comptime Date = Date
    comptime Time = Time
    comptime DateTime = DateTime
    comptime Array = List[TomlType]
    comptime Table = Dict[String, TomlType]

    comptime IsTomlType[T: Movable] = AnyTomlType.Ts.contains[T]()


comptime AnyTomlType = Variant[
    TomlTypes.String,
    TomlTypes.Integer,
    TomlTypes.Float,
    NoneType,
    TomlTypes.Boolean,
    TomlTypes.Date,
    TomlTypes.Time,
    TomlTypes.DateTime,
    TomlTypes.Array,
    TomlTypes.Table,
]


# struct TomlRef[toml: ImmutOrigin](Iterable, TrivialRegisterPassable):
#     comptime Toml = TomlType
#     comptime IteratorType[origin: Origin]: Iterator = Self.Toml.IteratorType[
#         Self.toml
#     ]
#     var pointer: Pointer[Self.Toml, Self.toml]

#     def __init__(out self, ref[Self.toml] v: Self.Toml):
#         self.pointer = Pointer(to=v)

#     def __getitem__(ref self) -> ref[Self.toml] Self.Toml:
#         return self.pointer[]

#     def __getitem__(ref self, idx: Int) -> ref[Self.toml] Self.Toml:
#         return self.pointer[][idx]

#     def __getitem__(
#         ref self, key: StringSlice
#     ) raises -> ref[Self.toml] Self.Toml:
#         return self.pointer[][key]

#     def __iter__(ref self) -> Self.IteratorType[Self.toml]:
#         return self.pointer[].__iter__()


# struct TomlListIter[
#     toml: ImmutOrigin,
# ](Iterator):
#     comptime Element = TomlType
#     var pointer: Pointer[Self.Element.OpaqueArray, Self.toml]
#     var index: Int

#     def __init__(out self, ref[Self.toml] v: Self.Element.OpaqueArray):
#         self.pointer = Pointer(to=v)
#         self.index = 0

#     def __next__(
#         mut self,
#     ) raises StopIteration -> ref[Self.toml] Self.Element:
#         if self.index >= len(self.pointer[]):
#             raise StopIteration()

#         ref elem = self.pointer[][self.index][]
#         self.index += 1
#         return elem


# struct TomlTableIter[
#     toml: Origin,
# ](ImplicitlyCopyable, Iterable, Iterator):
#     comptime Element = Tuple[String, TomlRef[MutUntrackedOrigin]]
#     comptime IteratorType[origin: Origin]: Iterator = Self
#     comptime Toml = TomlType
#     var dict_iter: _DictEntryIter[
#         mut=Self.toml.mut,
#         K=downcast[
#             Self.Toml.OpaqueTable.K,
#             Copyable & KeyElement & ImplicitlyDeletable,
#         ],
#         V=downcast[
#             Self.Toml.OpaqueTable.V,
#             Copyable & KeyElement & ImplicitlyDeletable,
#         ],
#         H=Self.Toml.OpaqueTable.H,
#         origin=Self.toml,
#     ]

#     def __init__(
#         out self: TomlTableIter[origin_of(v)],
#         ref v: Self.Toml.OpaqueTable,
#     ):
#         self.dict_iter = v.items()

#     def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
#         return self.copy()

#     def __next__(
#         mut self,
#     ) raises StopIteration -> Self.Element:
#         ref kv = next(self.dict_iter)

#         ref toml_value = kv.value[]
#         return kv.key, TomlRef(toml_value)


# struct TomlType(Copyable, Iterable, Writable):
struct TomlType(Copyable, Writable):
    # Store a list of addesses.
    # comptime OpaqueArray = PointerList
    # comptime OpaqueTable = PointerDict

    # comptime RefArray[o: ImmutOrigin] = List[TomlRef[o]]
    # comptime RefTable[o: ImmutOrigin] = Dict[String, TomlRef[o]]

    # For ease of use of the type
    # comptime Array = List[Self]
    # comptime Table = Dict[String, Self]

    # Runtime
    # comptime AnyToml = AnyTomlType
    var inner: OpaquePointer[MutUntrackedOrigin]

    # Iterable
    # comptime IteratorType[
    #     mut: Bool, //, origin: Origin[mut=mut]
    # ] = TomlListIter[origin]

    # def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
    #     # upcast origin to self.
    #     ref array = UnsafePointer(
    #         to=self.inner[Self.OpaqueArray]
    #     ).unsafe_origin_cast[origin_of(self)]()[]

    #     return TomlListIter[origin_of(self)](array)

    def isa[T: AnyType](self) -> Bool:
        ref inner = self.get_inner()
        return inner.isa[T]()

    def take_inner(deinit self) -> AnyTomlType:
        return self.inner.bitcast[AnyTomlType]().take_pointee()

    # @staticmethod
    # def from_addr(addr: TomlPtr) -> ref[addr] Self:
    #     return addr^.take()

    # @staticmethod
    # def take_from_addr(var addr: OwnedPointer[Self]) -> Self:
    #     return addr^.take()

    # def move_to_addr(var self) -> OwnedPointer[Self]:
    #     return OwnedPointer(self)

    # def to_addr(mut self) -> TomlPtr[origin_of(self)]:
    #     return Pointer(to=self)

    @staticmethod
    def new_array(out self: Self, capacity: Int = 32):
        self = Self(array=TomlTypes.Array(capacity=capacity))

    @staticmethod
    def new_table(out self: Self, capacity: Int = 32):
        self = Self(table=TomlTypes.Table(capacity=capacity))

    def ref_table(ref self) -> ref[self] TomlTypes.Table:
        ref inner = self.get_inner()
        return inner[TomlTypes.Table]

    def ref_array(ref self) -> ref[self] TomlTypes.Array:
        ref inner = self.get_inner()
        return inner[TomlTypes.Array]

    # ==== Access inner values using methods ====

    def string(ref self) -> TomlTypes.String:
        return self.get_inner()[TomlTypes.String]

    def integer(ref self) -> TomlTypes.Integer:
        return self.get_inner()[TomlTypes.Integer]
        # return self.inner[Self.Integer]

    def float(ref self) -> TomlTypes.Float:
        return self.get_inner()[TomlTypes.Float]
        # return self.inner[Self.Float]

    def boolean(ref self) -> TomlTypes.Boolean:
        return self.get_inner()[TomlTypes.Boolean]
        # return self.inner[Self.Boolean]

    def array(deinit self) -> TomlTypes.Array:
        """Points to self, because external origin it's managed by self."""
        return self^.take_inner().take[TomlTypes.Array]()

    def table(deinit self) -> TomlTypes.Table:
        """Points to self, because external origin it's managed by self."""
        return self^.take_inner().take[TomlTypes.Table]()

    # For interop with list

    def get_inner(ref self) -> ref[self] AnyTomlType:
        return self.inner.bitcast[AnyTomlType]()[]

    def __getitem__(ref self, idx: Int) -> ref[self] Self:
        return self.get_inner()[TomlTypes.Array][idx]

    def __contains__(ref self, v: StringSlice) -> Bool:
        # Only works for arrays and tables
        if self.isa[TomlTypes.Array]():
            for ptrs in self.ref_array():
                if ptrs.isa[TomlTypes.String]() and ptrs.string() == v:
                    return True
            return False
        elif self.isa[TomlTypes.Table]():
            for i in self.ref_table():
                if i == v:
                    return True
            return False
        return False

    # For interop with dict

    def __getitem__(ref self, key: StringSlice) raises -> ref[self] Self:
        ref table = self.get_inner()[TomlTypes.Table]

        for ref kv in table.items():
            if kv.key == key:
                return UnsafePointer(to=kv.value).unsafe_origin_cast[
                    origin_of(self)
                ]()[]

        raise "key not found in toml"
        # String(key)
        # os.abort(String("Key '", key, "' not found in TOML table."))

    # def items(ref self) -> TomlTableIter[origin_of(self.inner)]:
    #     return TomlTableIter(self.inner[Self.OpaqueTable])

    # def __init__(out self, *, var toml: AnyTomlType):
    #     self.inner = (
    #         UnsafePointer(to=toml)
    #         .bitcast[NoneType]()
    #         .unsafe_origin_cast[MutUntrackedOrigin]()
    #     )

    def __init__(out self, *, var string: TomlTypes.String):
        var _val = string^
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var integer: TomlTypes.Integer):
        var _val = integer
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var float: TomlTypes.Float):
        var _val = float
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var none: NoneType):
        var _val = none
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var boolean: TomlTypes.Boolean):
        var _val = boolean
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var date: TomlTypes.Date):
        var _val = date
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var time: TomlTypes.Time):
        var _val = time
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var datetime: TomlTypes.DateTime):
        var _val = datetime
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var array: TomlTypes.Array):
        var _val = array^
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val^))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __init__(out self, *, var table: TomlTypes.Table):
        var _val = table^
        self.inner = (
            UnsafePointer(to=AnyTomlType(_val^))
            .bitcast[NoneType]()
            .unsafe_origin_cast[MutUntrackedOrigin]()
            .unsafe_mut_cast[target_mut=True]()
        )

    def __del__(deinit self):
        self.inner.bitcast[AnyTomlType]().destroy_pointee()

    def to_json(self, mut w: Some[Writer]) raises:
        ref inner = self.get_inner()
        if inner.isa[TomlTypes.String]():
            ref s = inner[TomlTypes.String]
            return w.write('{"type": "string", "value": "', s, '"}')
        if inner.isa[TomlTypes.Integer]():
            var intg = inner[TomlTypes.Integer]
            return w.write('{"type": "integer", "value": "', intg, '"}')
        if inner.isa[TomlTypes.Float]():
            var fl = inner[TomlTypes.Float]
            return w.write('{"type": "float", "value": "', fl, '"}')
        if inner.isa[NoneType]():
            return w.write('{"type": "float", "value": "nan"}')
        if inner.isa[TomlTypes.Boolean]():
            var value = "true" if inner[TomlTypes.Boolean] else "false"
            return w.write('{"type": "bool", "value": "', value, '"}')
        if inner.isa[TomlTypes.DateTime]():
            var dt = inner[TomlTypes.DateTime]
            var nm = "datetime-local" if dt.is_local else "datetime"
            return w.write('{"type": "', nm, '", "value": "', dt, '"}')
        if inner.isa[TomlTypes.Date]():
            var date = inner[TomlTypes.Date]
            return w.write('{"type": "date-local", "value": "', date, '"}')
        if inner.isa[TomlTypes.Time]():
            var time = inner[TomlTypes.Time]
            return w.write('{"type": "time-local", "value": "', time, '"}')

        if inner.isa[TomlTypes.Array]():
            ref array = inner[TomlTypes.Array]
            w.write("[")
            for i, v in enumerate(array):
                if i != 0:
                    w.write(", ")

                v.to_json(w)
            w.write("]")
            return

        if inner.isa[TomlTypes.Table]():
            ref table = inner[TomlTypes.Table]
            w.write("{")
            for i, kv in enumerate(table.items()):
                if i != 0:
                    w.write(", ")

                w.write(t'"{kv.key}": ')
                kv.value.to_json(w)
            w.write("}")
            return

        raise "type to write not identified"
