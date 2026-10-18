from .tempo import Date, DateTime, Time

from std.os import abort
from std.memory.alloc import unsafe_alloc
from std.memory.owned_pointer import OwnedPointer
from std.memory import forget_deinit
from std.hash import hasher


# CUSTOM ITERATOR TO AVOID COPYABLE -- USING POINTERS
struct ListPtrIterator[origin: ImmOrigin](Copyable, Iterable, Iterator):
    comptime Element = Pointer[Toml, Self.origin]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self
    var index: Int
    var list: Pointer[List[Toml], Self.origin]

    def __init__(out self, ref[Self.origin] list: List[Toml]):
        self.index = 0
        self.list = Pointer(to=list)

    def __iter__(ref self) -> Self.IteratorType[Self.origin]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        while 0 <= self.index < len(self.list[]):
            var idx = self.index
            self.index += 1
            return (
                Pointer(to=self.list[][idx])
                .unsafe_mut_cast[False]()
                .unsafe_origin_cast[Self.origin]()
            )
        raise StopIteration()


# CUSTOM ITERATOR TO AVOID COPYABLE -- USING POINTERS
struct TablePtrKVIterator[origin: ImmOrigin](Copyable, Iterable, Iterator):
    comptime Element = Tuple[String, Pointer[Toml, Self.origin]]
    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = Self
    var index: Int
    var seen: Int
    var table: Pointer[Dict[String, Toml], Self.origin]

    def __init__(out self, ref[Self.origin] table: Dict[String, Toml]):
        self.index = 0
        self.seen = 0
        self.table = Pointer(to=table)

    def __iter__(ref self) -> Self.IteratorType[Self.origin]:
        return self.copy()

    def __next__(mut self) raises StopIteration -> Self.Element:
        var is_occupied = lambda (ctrl: UInt8) -> Bool: ctrl < 0x80
        if self.seen >= len(self.table[]):
            raise StopIteration()

        while 0 <= self.index < len(self.table[]._order):
            var idx = self.index
            self.index += 1

            var slot = Int(self.table[]._order[idx])
            if is_occupied(self.table[]._table._ctrl[unsafe_offset=slot]):
                self.seen += 1
                var p = self.table[]._table._slots.unsafe_offset(slot)
                return (
                    p[].key,
                    Pointer(to=p[].value)
                    .unsafe_mut_cast[False]()
                    .unsafe_origin_cast[Self.origin](),
                )

        raise StopIteration()


__extension Dict:
    def iter(self: Dict[String, Toml]) -> TablePtrKVIterator[origin_of(self)]:
        return TablePtrKVIterator(self)


__extension List:
    def iter(self: List[Toml]) -> ListPtrIterator[origin_of(self)]:
        return ListPtrIterator(self)


struct TomlType:
    comptime NaN = Toml.NaN
    comptime String = String
    comptime Integer = Int
    comptime Float = Float64
    comptime Boolean = Bool
    comptime Date = Date
    comptime Time = Time
    comptime DateTime = DateTime
    comptime Array = List[Toml]
    comptime Table = Dict[Self.String, Toml]


__enum Toml(Copyable, Equatable, Movable, Writable):
    comptime Types = TomlType
    case NaN
    case String(TomlType.String)
    case Integer(TomlType.Integer)
    case Float(TomlType.Float)
    case Boolean(TomlType.Boolean)
    case Date(TomlType.Date)
    case Time(TomlType.Time)
    case DateTime(TomlType.DateTime)
    case Array(TomlType.Array)
    case Table(TomlType.Table)

    def __init__(out self, *, copy: Self):
        match copy:
            case .Table(t):
                var _tb = Dict[String, Toml]()
                for k, v in t.iter():
                    _tb[k] = v[].copy()
                return Toml.Table(_tb^)
            case .Array(a):
                return Toml.Array([elem[].copy() for elem in a.iter()])
            case .Boolean(b):
                return Toml.Boolean(b)
            case .Integer(i):
                return Toml.Integer(i)
            case .Float(f):
                return Toml.Float(f)
            case .String(s):
                return Toml.String(s)
            case .Date(d):
                return Toml.Date(d)
            case .Time(t):
                return Toml.Time(t)
            case .DateTime(dt):
                return Toml.DateTime(dt)
            case .NaN:
                return materialize[Toml.NaN]()

    def __deinit__(deinit self):
        pass

    def unsafe_take[
        T: Movable
    ](var self) -> T where TypeList[Self._enum_case_types].contains[T]():
        comptime for i in range(TypeList[Self._enum_case_types].length):
            comptime if TypeList[Self._enum_case_types]()[i] == T:
                if self._get_enum_discriminant() != i:
                    abort("Provided Type doesn't match Enum Type.")
                var ptr = self.__get_enum_storage().payload_ptr[i]()
                comptime assert conforms_to(ptr.T, Movable)
                var elem = ptr.unsafe_take_pointee()
                forget_deinit(self^)
                return rebind_var[T](elem^)

        abort("Type not found in enum payloads.")

    def __eq__(self, other: Self) -> Bool:
        if self._get_enum_discriminant() != other._get_enum_discriminant():
            return False
        match self:
            case .NaN:
                return True
            case .String(s):
                return s == other[String]
            case .Integer(i):
                return i == other[Int]
            case .Float(f):
                return f == other[Float64]
            case .Boolean(b):
                return b == other[Bool]
            case .Date(d):
                return d == other[Date]
            case .Time(t):
                return t == other[Time]
            case .DateTime(dt):
                return dt == other[DateTime]
            case .Table(tb):
                ref other_tb = other[Dict[String, Toml]]
                if len(tb) != len(other_tb):
                    return False
                for k, v in tb.iter():
                    var found, slot_idx = other_tb._table.find_slot(
                        hash[type_of(tb).H](k), k
                    )
                    if not found:
                        return False
                    if (
                        v[]
                        != other_tb._table._slots[unsafe_offset=slot_idx].value
                    ):
                        return False

                return True

            case .Array(arr):
                ref other_arr = other[List[Toml]]
                if len(arr) != len(other_arr):
                    return False

                var index = 0
                for element in arr.iter():
                    if element[] != other_arr[index]:
                        return False
                    index += 1
                return True

    def __getitem_param__[
        T: AnyType
    ](ref self) -> ref[self] T where TypeList[Self._enum_case_types].contains[
        T
    ]():
        comptime for i in range(TypeList[Self._enum_case_types].length):
            comptime if TypeList[Self._enum_case_types]()[i] == T:
                if self._get_enum_discriminant() != i:
                    abort("Type provided doesn't match Enum Type.")
                return rebind[T](self._unsafe_get_enum_payload[i]())

        abort("Type not found in enum payloads.")

    def to_json(self, mut w: Some[Writer]):
        match self:
            case .String(s):
                return w.write('{"type": "string", "value": "', s, '"}')
            case .Integer(intg):
                return w.write('{"type": "integer", "value": "', intg, '"}')
            case .Float(fl):
                return w.write('{"type": "float", "value": "', fl, '"}')
            case .NaN:
                return w.write('{"type": "float", "value": "nan"}')
            case .Boolean(value):
                return w.write(
                    '{"type": "bool", "value": "',
                    "true" if value else "false",
                    '"}',
                )
            case .DateTime(dt):
                var nm = "datetime-local" if dt.is_local else "datetime"
                return w.write('{"type": "', nm, '", "value": "', dt, '"}')
            case .Date(date):
                return w.write('{"type": "date-local", "value": "', date, '"}')
            case .Time(time):
                return w.write('{"type": "time-local", "value": "', time, '"}')

            case .Array(array):
                w.write("[")
                for idx, elem in enumerate(array.iter()):
                    if idx != 0:
                        w.write(", ")
                    elem[].to_json(w)
                w.write("]")

            case .Table(table):
                w.write("{")
                for idx, (k, v) in enumerate(table.iter()):
                    if idx != 0:
                        w.write(", ")
                    w.write(t'"{k}": ')
                    v[].to_json(w)
                w.write("}")

    def write_to(self, mut w: Some[Writer]):
        w.write("Toml(")
        match self:
            case .Table(tb):
                w.write("{")
                for idx, (k, v) in enumerate(tb.iter()):
                    if idx != 0:
                        w.write(", ")
                    w.write(t'"{k}": {v[]}')
                w.write("}")
            case .Array(arr):
                w.write("[")
                for idx, elem in enumerate(arr.iter()):
                    if idx != 0:
                        w.write(", ")
                    elem[].to_json(w)
                w.write("]")
            case .NaN:
                w.write("nan")
            case .String(s):
                w.write("'", s, "'")
            case .Integer(i):
                w.write(i)
            case .Float(f):
                w.write(f)
            case .Date(d):
                w.write(d)
            case .DateTime(dt):
                w.write(dt)
            case .Time(t):
                w.write(t)
            case .Boolean(b):
                w.write("true" if b else "false")
        w.write(")")


# @fieldwise_init
# struct NaN(Equatable, TrivialRegisterPassable, Writable):
#     pass


# struct OldToml(Copyable, Equatable, Movable, Writable):
#     comptime String = String
#     comptime Integer = Int
#     comptime Float = Float64
#     comptime NaN = NaN
#     comptime Boolean = Bool
#     comptime Date = Date
#     comptime Time = Time
#     comptime DateTime = DateTime
#     comptime Array = List[OldToml]
#     comptime Table = Dict[String, OldToml]

#     comptime AllTypes = TypeList.of[
#         Trait=Movable,
#         Self.String,
#         Self.Integer,
#         Self.Float,
#         Self.NaN,
#         Self.Boolean,
#         Self.Date,
#         Self.Time,
#         Self.DateTime,
#         Self.Array,
#         Self.Table,
#     ]()

#     var _inner: Pointer[NoneType, MutUntrackedOrigin]
#     var _id: Int

#     @staticmethod
#     def _get_type_idx[T: Movable]() -> Int where Self.AllTypes.contains[T]():
#         comptime for idx in range(Self.AllTypes.length):
#             comptime if Self.AllTypes[idx] == T:
#                 return idx
#         return -1

#     def get_type_name(self) -> StaticString:
#         comptime for i in range(Self.AllTypes.length):
#             comptime T = Self.AllTypes[i]
#             comptime assert Self.AllTypes.contains[T]()
#             if self.isa[T]():
#                 return reflect[T].name()

#         return "ERROR: NOT FOUND"

#     def __init__(out self, *, copy: Self):
#         comptime for i in range(Self.AllTypes.length):
#             comptime T = Self.AllTypes[i]
#             comptime assert conforms_to(T, Copyable)
#             comptime assert Self.AllTypes.contains[T]()
#             if copy.isa[T]():
#                 var val_copy: T = copy.unsafe_ref[T]().copy()
#                 comptime assert Self.AllTypes.contains[type_of(val_copy)]()
#                 return {val_copy^}

#         abort("Not able to find type.")

#     def __init__[
#         T: Movable, //
#     ](out self, var value: T) where Self.AllTypes.contains[T]():
#         # var ptr = stack_allocation[1, T]()
#         var ptr = unsafe_alloc[T](1)
#         ptr.unsafe_write(value^)
#         self._inner = ptr.unsafe_bitcast[NoneType]()
#         self._id = self._get_type_idx[T]()

#     def isa[T: Movable](self) -> Bool where Self.AllTypes.contains[T]():
#         return self._id == self._get_type_idx[T]()

#     def __getitem_param__[
#         T: Movable
#     ](ref self) raises -> ref[self] T where Self.AllTypes.contains[T]():
#         if not self.isa[T]():
#             raise "The type you are trying to access is not correct."
#         return self.unsafe_ref[T]()

#     def unsafe_ref[
#         T: Movable
#     ](ref self) -> ref[self] T where Self.AllTypes.contains[T]():
#         assert self.isa[T]()
#         return self._inner.unsafe_bitcast[T]()[]

#     def take[
#         T: Movable
#     ](var self) raises -> T where Self.AllTypes.contains[T]():
#         if not self.isa[T]():
#             raise "The type you are trying to access is not correct."
#         return self^.unsafe_take[T]()

#     def unsafe_take[
#         T: Movable
#     ](deinit self, out o: T) where Self.AllTypes.contains[T]():
#         assert self.isa[T]()
#         o = self._inner.unsafe_bitcast[T]().unsafe_take_pointee()
#         self._inner.unsafe_free()

#     def write_to(self, mut w: Some[Writer]):
#         comptime for i in range(Self.AllTypes.length):
#             comptime T = Self.AllTypes[i]
#             comptime assert Self.AllTypes.contains[T]()
#             comptime assert conforms_to(T, Writable)

#             if self.isa[T]():
#                 comptime if T == Self.Array:
#                     w.write("[")
#                     for i, v in enumerate(self.unsafe_ref[Self.Array]()):
#                         if i != 0:
#                             w.write(", ")
#                         w.write(v)
#                     w.write("]")
#                 elif T == Self.Table:
#                     w.write("{")
#                     for i, v in enumerate(
#                         self.unsafe_ref[Self.Table]().items()
#                     ):
#                         var rp = t'"{v.key}": {v.value}'
#                         if i != 0:
#                             w.write(", ")
#                         w.write(rp)
#                     w.write("}")
#                 else:
#                     w.write(self.unsafe_ref[T]())
#                 return

#     def __eq__(self, other: Self) -> Bool:
#         comptime for i in range(Self.AllTypes.length):
#             comptime T = Self.AllTypes[i]
#             comptime assert Self.AllTypes.contains[T]()
#             comptime assert other.AllTypes.contains[T]()
#             comptime assert conforms_to(T, Equatable)
#             if self.isa[T]() and other.isa[T]():
#                 try:
#                     return self[T] == other[T]
#                 except:
#                     return False
#         return False

#     def to_json(self, mut w: Some[Writer]) raises:
#         if self.isa[Self.String]():
#             ref s = self[Self.String]
#             return w.write('{"type": "string", "value": "', s, '"}')
#         if self.isa[Self.Integer]():
#             var intg = self[Self.Integer]
#             return w.write('{"type": "integer", "value": "', intg, '"}')
#         if self.isa[Self.Float]():
#             var fl = self[Self.Float]
#             return w.write('{"type": "float", "value": "', fl, '"}')
#         if self.isa[NaN]():
#             return w.write('{"type": "float", "value": "nan"}')
#         if self.isa[Self.Boolean]():
#             var value = "true" if self[Self.Boolean] else "false"
#             return w.write('{"type": "bool", "value": "', value, '"}')
#         if self.isa[Self.DateTime]():
#             var dt = self[Self.DateTime]
#             var nm = "datetime-local" if dt.is_local else "datetime"
#             return w.write('{"type": "', nm, '", "value": "', dt, '"}')
#         if self.isa[Self.Date]():
#             var date = self[Self.Date]
#             return w.write('{"type": "date-local", "value": "', date, '"}')
#         if self.isa[Self.Time]():
#             var time = self[Self.Time]
#             return w.write('{"type": "time-local", "value": "', time, '"}')

#         if self.isa[Self.Array]():
#             ref array = self[Self.Array]
#             w.write("[")
#             for i, v in enumerate(array):
#                 if i != 0:
#                     w.write(", ")

#                 v.to_json(w)
#             w.write("]")
#             return

#         if self.isa[Self.Table]():
#             ref table = self[Self.Table]
#             w.write("{")
#             for i, kv in enumerate(table.items()):
#                 if i != 0:
#                     w.write(", ")

#                 w.write(t'"{kv.key}": ')
#                 kv.value.to_json(w)
#             w.write("}")
#             return

#     def __deinit__(deinit self):
#         comptime for i in range(Self.AllTypes.length):
#             comptime T = Self.AllTypes[i]
#             comptime assert Self.AllTypes.contains[T]()
#             comptime assert conforms_to(T, Deinitable)
#             if self.isa[T]():
#                 var typed = self._inner.unsafe_bitcast[T]()
#                 typed.unsafe_deinit_pointee()
#                 typed.unsafe_free()
#                 return
#         else:
#             abort("Unable to dealloc")
