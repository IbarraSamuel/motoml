import os
from builtin.rebind import downcast
from sys.intrinsics import likely, _type_is_eq
from reflection import get_type_name
from utils import Variant
from collections.dict import _DictEntryIter
from hashlib import Hasher

from .types.string_ref import StringRef

# TYPES
comptime Integer = Int
comptime Float = Float64
comptime Boolean = Bool

comptime Opaque[o: MutOrigin] = OpaquePointer[o]
comptime OpaqueArray = List[Opaque[MutExternalOrigin]]
comptime OpaqueTable[o: ImmutOrigin] = Dict[
    StringRef[o], Opaque[MutExternalOrigin]
]

# TODO: Add new time types

comptime AnyTomlType[o: ImmutOrigin] = Variant[
    StringRef[o],
    Integer,
    Float,
    NoneType,
    Boolean,
    OpaqueArray,
    OpaqueTable[o],
]


struct TomlRef[data: ImmutOrigin, toml: ImmutOrigin](
    Iterable, TrivialRegisterPassable
):
    comptime Toml = TomlType[Self.data]
    comptime IteratorType[origin: Origin]: Iterator = Self.Toml.IteratorType[
        Self.toml
    ]
    var pointer: Pointer[Self.Toml, Self.toml]

    fn __init__(out self, ref[Self.toml] v: Self.Toml):
        self.pointer = Pointer(to=v)

    fn __getitem__(ref self) -> ref[Self.toml] Self.Toml:
        return self.pointer[]

    fn __getitem__(ref self, idx: Int) -> ref[Self.toml] Self.Toml:
        return self.pointer[][idx]

    fn __getitem__(ref self, key: StringSlice) -> ref[Self.toml] Self.Toml:
        return self.pointer[][key]

    fn __iter__(ref self) -> Self.IteratorType[Self.toml]:
        return self.pointer[].__iter__()


struct TomlListIter[
    data: ImmutOrigin,
    toml: ImmutOrigin,
](Iterator):
    comptime Element = TomlType[Self.data]
    var pointer: Pointer[Self.Element.OpaqueArray, Self.toml]
    var index: Int

    fn __init__(out self, ref[Self.toml] v: Self.Element.OpaqueArray):
        self.pointer = Pointer(to=v)
        self.index = 0

    fn __next__(
        mut self,
    ) raises StopIteration -> ref[Self.toml] Self.Element:
        if self.index >= len(self.pointer[]):
            raise StopIteration()

        ref elem = self.pointer[][self.index].bitcast[Self.Element]()[]
        self.index += 1
        return elem


struct TomlTableIter[
    data: ImmutOrigin,
    toml: ImmutOrigin,
](ImplicitlyCopyable, Iterable, Iterator):
    comptime Element = Tuple[
        StringSlice[Self.data], TomlRef[Self.data, ImmutExternalOrigin]
    ]
    comptime IteratorType[origin: Origin]: Iterator = Self
    comptime Toml = TomlType[Self.data]
    var dict_iter: _DictEntryIter[
        mut=False,
        K = Self.Toml.OpaqueTable.K,
        V = Self.Toml.OpaqueTable.V,
        H = Self.Toml.OpaqueTable.H,
        origin = Self.toml,
    ]

    fn __init__(
        out self: TomlTableIter[Self.data, origin_of(v)],
        v: Self.Toml.OpaqueTable,
    ):
        self.dict_iter = v.items()

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    fn __next__(
        mut self,
    ) raises StopIteration -> Self.Element:
        ref kv = next(self.dict_iter)

        ref toml_value = kv.value.bitcast[Self.Toml]()[]
        return StringSlice(unsafe_from_utf8=kv.key.value), TomlRef(toml_value)


struct TomlType[o: ImmutOrigin](Copyable, Iterable, Representable):
    comptime String = StringRef[Self.o]
    # comptime StringLiteral = StringLit[Self.o]
    comptime Integer = Integer
    comptime Float = Float
    comptime NaN = NoneType
    comptime Boolean = Boolean

    comptime Array = List[Self]
    comptime Table = Dict[StringRef[Self.o], Self]

    # Store a list of addesses.
    comptime OpaqueArray = OpaqueArray
    comptime OpaqueTable = OpaqueTable[Self.o]
    comptime RefArray[o: ImmutOrigin] = List[TomlRef[Self.o, o]]
    comptime RefTable[o: ImmutOrigin] = Dict[
        StringRef[Self.o], TomlRef[Self.o, o]
    ]

    # Iterable
    comptime IteratorType[
        mut: Bool, //, origin: Origin[mut=mut]
    ] = TomlListIter[Self.o, origin]

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        # upcast origin to self.
        ref array = UnsafePointer(
            to=self.inner[Self.OpaqueArray]
        ).unsafe_origin_cast[origin_of(self)]()[]

        return TomlListIter[toml = origin_of(self), data = Self.o](array)

    # Runtime
    var inner: AnyTomlType[Self.o]

    fn isa[T: AnyType](self) -> Bool:
        @parameter
        if _type_is_eq[T, Self.Array]():
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
    fn from_addr(addr: Opaque) -> ref[addr.origin] Self:
        return addr.bitcast[Self]()[]

    @staticmethod
    fn take_from_addr(var addr: Opaque[MutExternalOrigin]) -> Self:
        return addr.bitcast[Self]().take_pointee()

    fn move_to_addr(var self) -> Opaque[MutExternalOrigin]:
        var ptr = alloc[Self](1)
        ptr.init_pointee_move(self^)
        return ptr.bitcast[NoneType]()

    fn to_addr(mut self) -> Opaque[origin_of(self)]:
        return UnsafePointer(to=self).bitcast[NoneType]()

    # TODO: Ask to provide capacity, to minimize allocations
    @staticmethod
    fn new_array(out self: Self):
        self = Self(array=Self.OpaqueArray(capacity=32))

    @staticmethod
    fn new_table(out self: Self):
        self = Self(table=Self.OpaqueTable(capacity=32))

    fn as_opaque_table(ref self) -> ref[self] Self.OpaqueTable:
        return UnsafePointer(
            to=self.inner[Self.OpaqueTable]
        ).unsafe_origin_cast[origin_of(self)]()[]

    fn as_opaque_array(ref self) -> ref[self] Self.OpaqueArray:
        return UnsafePointer(
            to=self.inner[Self.OpaqueArray]
        ).unsafe_origin_cast[origin_of(self)]()[]

    # ==== Access inner values using methods ====

    fn string(ref self) -> ref[self.inner] Self.String:
        return self.inner[Self.String]

    fn integer(ref self) -> Self.Integer:
        return self.inner[Self.Integer]

    fn float(ref self) -> Self.Float:
        return self.inner[Self.Float]

    fn boolean(ref self) -> Self.Boolean:
        return self.inner[Self.Boolean]

    fn to_array(deinit self) -> Self.Array:
        """Points to self, because external origin it's managed by self."""
        return [Self.take_from_addr(it) for it in self.inner[Self.OpaqueArray]]

    fn to_table(deinit self) -> Self.Table:
        """Points to self, because external origin it's managed by self."""
        return {
            kv.key.copy(): Self.take_from_addr(kv.value)
            for kv in self.inner[Self.OpaqueTable].items()
        }

    fn array(self) -> Self.RefArray[origin_of(self.inner)]:
        """Points to self, because external origin it's managed by self."""
        return [
            TomlRef[Self.o, origin_of(self.inner)](Self.from_addr(it))
            for it in self.inner[Self.OpaqueArray]
        ]

    fn table(self) -> Self.RefTable[origin_of(self.inner)]:
        """Points to self, because external origin it's managed by self."""
        return {
            kv.key.copy(): TomlRef[Self.o, origin_of(self.inner)](
                Self.from_addr(kv.value)
            )
            for kv in self.inner[Self.OpaqueTable].items()
        }

    # For interop with list

    fn __getitem__(ref self, idx: Int) -> ref[self] Self:
        return self.inner[Self.OpaqueArray][idx].bitcast[Self]()[]

    fn __contains__(ref self, v: StringSlice) -> Bool:
        # Only works for arrays and tables
        if self.isa[Self.Array]():
            for ptrs in self.as_opaque_array():
                if (
                    ptrs.bitcast[Self]()[].isa[Self.String]()
                    and ptrs.bitcast[Self]()[].string().calc_value() == v
                ):
                    return True
            return False
        elif self.isa[Self.Table]():
            for i in self.as_opaque_table():
                # TODO: Handle modified string cases
                if StringSlice(unsafe_from_utf8=i.value) == v:
                    return True
            return False
        return False

    # For interop with dict

    fn __getitem__(ref self, key: StringSlice) -> ref[self] Self:
        ref table = self.inner[Self.OpaqueTable]

        for kv in table.items():
            if StringSlice(unsafe_from_utf8=kv.key.value) == key:
                return Self.from_addr(kv.value)

        os.abort("key not found in toml")
        # String(key)
        # os.abort(String("Key '", key, "' not found in TOML table."))

    fn items(ref self) -> TomlTableIter[Self.o, origin_of(self.inner)]:
        return TomlTableIter(self.inner[Self.OpaqueTable])

    fn __init__(out self, *, var string: Self.String):
        self.inner = string^

    # fn __init__(out self, *, var string_literal: Self.StringLiteral):
    #     self.inner = string_literal

    # TODO: Add new time types
    fn __init__(out self, *, var integer: Self.Integer):
        self.inner = integer

    fn __init__(out self, *, var float: Self.Float):
        self.inner = float

    fn __init__(out self, *, var none: NoneType):
        self.inner = none

    fn __init__(out self, *, var boolean: Self.Boolean):
        self.inner = boolean

    fn __init__(out self, *, var array: Self.OpaqueArray):
        self.inner = array^

    fn __init__(out self, *, var table: Self.OpaqueTable):
        self.inner = table^

    fn __del__(deinit self):
        ref inner = self.inner

        if inner.isa[self.OpaqueArray]():
            ref array = inner[self.OpaqueArray]
            for addr in array:
                addr.free()
        elif inner.isa[self.OpaqueTable]():
            ref table = inner[self.OpaqueTable]
            for v in table.values():
                v.free()

    fn __repr__(self) -> String:
        ref inner = self.inner

        # if inner.isa[self.StringLiteral]():
        #     var s = TableKey(is_literal=True, value=inner[self.StringLiteral])
        #     return String('{"type": "string", "value": "', s.calc_value(), '"}')
        if inner.isa[self.String]():
            ref s = inner[self.String]
            return String('{"type": "string", "value": "', s.calc_value(), '"}')
        elif inner.isa[self.Integer]():
            var intg = inner[self.Integer]
            return String('{"type": "integer", "value": "', intg, '"}')
        elif inner.isa[self.Float]():
            var v = inner[self.Float]
            var final: String
            if v == self.Float.MAX:
                final = "inf"
            elif v == self.Float.MIN:
                final = "-inf"
            elif v - self.Float(Int(v)) == 0.0:
                final = String(Int(v))
            else:
                final = String(v)
            return String('{"type": "float", "value": "', final, '"}')
        elif inner.isa[self.NaN]():
            return String('{"type": "float", "value": "nan"}')
        elif inner.isa[self.Boolean]():
            var value = "true" if inner[self.Boolean] else "false"
            return String('{"type": "bool", "value": "', value, '"}')
        elif inner.isa[self.OpaqueArray]():
            ref array = inner[self.OpaqueArray]
            var values = ", ".join(
                [repr(Self.from_addr(addr)) for addr in array]
            )
            return String("[", values, "]")

        elif inner.isa[self.OpaqueTable]():
            ref table = inner[self.OpaqueTable]
            var content = ", ".join(
                [
                    '"{}": {}'.format(
                        kv.key.calc_value(), repr(Self.from_addr(kv.value))
                    )
                    for kv in table.items()
                ]
            )
            return String("{", content, "}")
            # TODO: Add new time types
        else:
            os.abort("type to repr not identified")
