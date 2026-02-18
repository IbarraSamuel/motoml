import os
from builtin.rebind import downcast
from sys.intrinsics import likely, _type_is_eq
from reflection import get_type_name
from utils import Variant
from collections.dict import _DictEntryIter

# TYPES
comptime StringRef[o: Origin] = StringSlice[o]
comptime Integer = Int
comptime Float = Float64
comptime Boolean = Bool

comptime Opaque[o: Origin] = OpaquePointer[o]
comptime OpaqueArray = List[Opaque[MutExternalOrigin]]
comptime OpaqueTable[o: Origin] = Dict[StringRef[o], Opaque[MutExternalOrigin]]


struct CollectionType[_v: __mlir_type.`!kgen.string`](
    Equatable, TrivialRegisterPassable
):
    comptime inner = StringLiteral[Self._v]()

    @implicit
    fn __init__(out self: CollectionType[v.value], v: type_of("table")):
        pass

    @implicit
    fn __init__(out self: CollectionType[v.value], v: type_of("array")):
        pass

    @implicit
    fn __init__(out self: CollectionType[v.value], v: type_of("plain")):
        pass

    fn __eq__(self, other: Self) -> Bool:
        return True

    fn __eq__(self, other: CollectionType[...]) -> Bool:
        return self.inner == other.inner

    # fn write_to(self, mut w: Some[Writer]):
    #     w.write(self.inner)


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
    var pointer: _DictEntryIter[
        mut=False,
        K = Self.Toml.OpaqueTable.K,
        V = Self.Toml.OpaqueTable.V,
        H = Self.Toml.OpaqueTable.H,
        origin = Self.toml,
    ]

    fn __init__(
        out self: TomlTableIter[Self.data, origin_of(v)],
        ref[Self.toml] v: Self.Toml.OpaqueTable,
    ):
        self.pointer = v.items()

    fn __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return self.copy()

    fn __next__(
        mut self,
    ) raises StopIteration -> Self.Element:
        ref kv = next(self.pointer)

        ref toml_value = kv.value.bitcast[Self.Toml]()[]
        return kv.key, TomlRef(toml_value)


struct TomlType[o: ImmutOrigin](Copyable, Iterable, Representable):
    comptime String = StringRef[Self.o]
    comptime Integer = Integer
    comptime Float = Float
    comptime NaN = NoneType
    comptime Boolean = Boolean

    comptime Array = List[Self]
    comptime Table = Dict[Self.String, Self]

    # Store a list of addesses.
    comptime OpaqueArray = OpaqueArray
    comptime OpaqueTable = OpaqueTable[Self.o]
    comptime RefArray[o: ImmutOrigin] = List[TomlRef[Self.o, o]]
    comptime RefTable[o: ImmutOrigin] = Dict[Self.String, TomlRef[Self.o, o]]

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

    fn to_addr(ref self) -> Opaque[origin_of(self)]:
        return UnsafePointer(to=self).bitcast[NoneType]()

    # TODO: Ask to provide capacity, to minimize allocations
    @staticmethod
    fn new_array(out self: Self):
        self = Self(Self.OpaqueArray(capacity=32))

    @staticmethod
    fn new_table(out self: Self):
        self = Self(Self.OpaqueTable(capacity=32))

    fn as_opaque_table(ref self) -> ref[self] Self.OpaqueTable:
        return UnsafePointer(
            to=self.inner[Self.OpaqueTable]
        ).unsafe_origin_cast[origin_of(self)]()[]

    fn as_opaque_array(ref self) -> ref[self] Self.OpaqueArray:
        return UnsafePointer(
            to=self.inner[Self.OpaqueArray]
        ).unsafe_origin_cast[origin_of(self)]()[]

    # ==== Access inner values using methods ====

    fn string(ref self) -> Self.String:
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
            kv.key: Self.take_from_addr(kv.value)
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
            kv.key: TomlRef[Self.o, origin_of(self.inner)](
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

    fn __getitem__(ref self, key: StringSlice) -> ref[self] Self:
        ref table = self.inner[Self.OpaqueTable]

        for kv in table.items():
            if kv.key == key:
                return Self.from_addr(kv.value)

        os.abort("key not found in toml")
        # String(key)
        # os.abort(String("Key '", key, "' not found in TOML table."))

    fn items(ref self) -> TomlTableIter[Self.o, origin_of(self.inner)]:
        return TomlTableIter(self.inner[Self.OpaqueTable])

    fn __init__(out self, var v: Self.String):
        self.inner = v

    fn __init__(out self, var v: Self.Integer):
        self.inner = v

    fn __init__(out self, var v: Self.Float):
        self.inner = v

    fn __init__(out self, var v: NoneType):
        self.inner = v

    fn __init__(out self, var v: Self.Boolean):
        self.inner = v

    fn __init__(out self, var v: Self.OpaqueArray):
        self.inner = v^

    fn __init__(out self, var v: Self.OpaqueTable):
        self.inner = v^

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

        if inner.isa[self.String]():
            var s = (
                inner[self.String]
                .removeprefix("\n")
                .replace("\n", "\\n")
                .replace("\t", "\\t")
                .replace("\r", "\\r")
            )
            # if s.find("\\x") != -1:
            #     s = "".join([c for c in s.codepoints()])

            return String('{"type": "string", "value": "', s, '"}')
        elif inner.isa[self.Integer]():
            return String(
                '{"type": "integer", "value": "', inner[self.Integer], '"}'
            )
        elif inner.isa[self.Float]():
            # var repr = "inf" if inner[self.Float] == self.Float.MAX else String(
            #     inner[self.Float]
            # )
            var v = inner[self.Float]
            var final: String
            if v == self.Float.MAX:
                final = "inf"
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
                [Self.from_addr(addr).__repr__() for addr in array]
            )
            return String("[", values, "]")

        elif inner.isa[self.OpaqueTable]():
            ref table = inner[self.OpaqueTable]
            var values = ", ".join(
                [
                    String(
                        '"',
                        kv.key.replace('\\"', '"')
                        .replace('"', '\\"')
                        .replace("\n", "\\n")
                        .replace("\t", "\\t")
                        .replace("\r", "\\r"),
                        '": ',
                        Self.from_addr(kv.value).__repr__(),
                    )
                    for kv in table.items()
                ]
            )
            return String("{", values, "}")
        else:
            os.abort("type to repr not identified")


comptime AnyTomlType[o: ImmutOrigin] = Variant[
    StringRef[o],
    Integer,
    Float,
    NoneType,
    Boolean,
    OpaqueArray,
    OpaqueTable[o],
]


# @explicit_destroy("You should free this pointer.")
# struct OwnedOpaque[TypeName: StaticString, //, mut: Bool = False](Movable):
#     comptime Ptr = UnsafePointer[NoneType, ExternalOrigin[mut = Self.mut]]
#     var ptr: Self.Ptr
#     var size: Int

#     fn __init__(out self, unsafe_from_ptr: Self.Ptr, size: Int):
#         self.ptr = unsafe_from_ptr
#         self.size = size

#     fn __init__[T: Movable & ImplicitlyDestructible](out self, var take: T):
#         comptime assert get_type_name[T]() == Self.TypeName
#         var ptr = alloc[T](1)
#         ptr.init_pointee_move(take^)
#         self.ptr = ptr.mut_cast[target_mut = Self.mut]().bitcast[NoneType]()
#         self.size = 1

#     fn offset[T: Movable & ImplicitlyDestructible](ref self, i: Int) -> Self:
#         comptime assert (
#             get_type_name[T]() == Self.TypeName
#         ), "The type used should be the same."
#         var shifted = (self.ptr.bitcast[T]() + i).bitcast[NoneType]()
#         return Self(unsafe_from_ptr=shifted, size=1)

#     fn __getitem__[
#         T: Movable & ImplicitlyDestructible
#     ](mut self: OwnedOpaque[mut=True]) -> ref[self] T:
#         comptime assert (
#             get_type_name[T]() == Self.TypeName
#         ), "The type used should be the same."
#         return self.ptr.bitcast[T]()[]

#     fn view[T: Movable & ImplicitlyDestructible](self) -> ref[self] T:
#         comptime assert (
#             get_type_name[T]() == Self.TypeName
#         ), "The type used should be the same."
#         return self.ptr.bitcast[T]()[]

#     fn ref_idx[
#         T: Movable & ImplicitlyDestructible
#     ](ref self: OwnedOpaque[mut=True], idx: Int) -> ref[self] T:
#         comptime assert (
#             get_type_name[T]() == Self.TypeName
#         ), "The type used should be the same."
#         ref loc = (self.ptr.bitcast[T]() + idx)[]
#         return UnsafePointer(to=loc)[]

#     fn free[T: Movable & ImplicitlyDestructible](deinit self):
#         comptime assert (
#             get_type_name[T]() == Self.TypeName
#         ), "The type used should be the same."
#         self.ptr.bitcast[T]().unsafe_mut_cast[target_mut=True]().free()

#     fn init_pointee_move[
#         T: Movable & ImplicitlyDestructible
#     ](self: OwnedOpaque[mut=True], var pointee: T, offset: Int = 0):
#         comptime assert (
#             get_type_name[T]() == Self.TypeName
#         ), "The type used should be the same."
#         (self.ptr.bitcast[T]() + offset).init_pointee_move(pointee^)

#     fn take_pointee[
#         T: Movable & ImplicitlyDestructible
#     ](deinit self: OwnedOpaque[mut=True]) -> T:
#         comptime assert (
#             get_type_name[T]() == Self.TypeName
#         ), "The type used should be the same."
#         return self.ptr.bitcast[T]().take_pointee()

#     fn unsafe_ignore_data(deinit self):
#         pass


# struct Vec[T: Movable & ImplicitlyDestructible, /, *, mut: Bool = False](
#     Movable, Sized
# ):
#     comptime Ptr = OwnedOpaque[
#         TypeName = get_type_name[Self.T](), mut = Self.mut
#     ]
#     var _data: Self.Ptr
#     var _len: Int
#     var capacity: Int

#     # fn __init__(out self, *, capacity: Int):
#     #     self._data = alloc[Self.T](capacity).mut_cast[target_mut = Self.mut]()
#     #     self.capacity = capacity
#     #     self._len = -1

#     fn __init__(
#         out self, *, length: Int, fill: Self.T
#     ) where conforms_to(Self.T, Copyable):
#         var ptr = alloc[Self.T](length).mut_cast[target_mut = Self.mut]()

#         ref _fill = trait_downcast[Copyable](fill)
#         for i in range(length):
#             (ptr + i).bitcast[downcast[Self.T, Copyable]]().unsafe_mut_cast[
#                 target_mut=True
#             ]().init_pointee_copy(_fill)

#         self.capacity = length
#         self._len = length - 1
#         self._data = Self.Ptr(
#             unsafe_from_ptr=ptr.bitcast[NoneType](), size=length
#         )

#     fn unsafe_push(mut self: Vec[Self.T, mut=True], var v: Self.T):
#         """In case there is no capacity, just update the last one."""
#         self._len = min(self._len + 1, self.capacity - 1)
#         var last_position = self._data.offset[Self.T](self._len)
#         last_position.init_pointee_move(v^)
#         # Safety: Will be handled still by the original pointer.
#         last_position^.unsafe_ignore_data()

#     fn unsafe_pop(mut self: Vec[Self.T, mut=True]) -> Self.T:
#         """In case there is no more data, just raise an abort."""
#         var obj_ptr = self._data.offset[Self.T](self._len)
#         self._len -= 1
#         if self._len == -2:
#             obj_ptr^.free[Self.T]()
#             os.abort("No more records to pop.")
#         return obj_ptr^.take_pointee[Self.T]()

#     fn __getitem__(ref self: Vec[mut=True], idx: Int) -> ref[self._data] Self.T:
#         return self._data.ref_idx[Self.T](idx)

#     fn __del__(deinit self):
#         self._data^.free[Self.T]()

#     fn __len__(self) -> Int:
#         return self._len + 1
