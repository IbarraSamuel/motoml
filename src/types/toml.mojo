from .tempo import Date, DateTime, Time
from std.sys.intrinsics import _type_is_eq_parse_time, _type_is_eq
from std.sys.compile import codegen_unreachable
from std.reflection.traits import AllWritable, AllEquatable
from std.memory import stack_allocation, alloc


@fieldwise_init
struct NaN(Equatable, TrivialRegisterPassable, Writable):
    pass


struct Toml(Copyable, Equatable, Movable, Writable):
    comptime String = String
    comptime Integer = Int
    comptime Float = Float64
    comptime NaN = NaN
    comptime Boolean = Bool
    comptime Date = Date
    comptime Time = Time
    comptime DateTime = DateTime
    comptime Array = List[Toml]
    comptime Table = Dict[String, Toml]

    comptime AllTypes = TypeList.of[
        Trait=Movable,
        Self.String,
        Self.Integer,
        Self.Float,
        Self.NaN,
        Self.Boolean,
        Self.Date,
        Self.Time,
        Self.DateTime,
        Self.Array,
        Self.Table,
    ]()

    var _inner: OpaquePointer[MutUntrackedOrigin]
    var _id: Int

    @staticmethod
    def _get_type_idx[T: Movable]() -> Int where Self.AllTypes.contains[T]():
        comptime for idx in range(Self.AllTypes.size):
            comptime if _type_is_eq[Self.AllTypes[idx], T]():
                return idx
        return -1

    def get_type_name(self) -> StaticString:
        comptime for i in range(Self.AllTypes.size):
            comptime T = Self.AllTypes[i]
            comptime assert Self.AllTypes.contains[T]()
            if self.isa[T]():
                return reflect[T].name()

        return "ERROR: NOT FOUND"

    # def __moveinit__(deinit self) -> Self:
    #     comptime for i in range(Self.AllTypes.size):
    #         comptime T = Self.AllTypes[i]
    #         comptime assert Self.AllTypes.contains[T]()
    #         if self.isa[T]():
    #             var inner_v = self._inner.bitcast[T]().take_pointee()
    #             return Self(inner_v^)

    #     return Self(Self.NaN())

    # def copy(self) -> Self:
    #     comptime for i in range(Self.AllTypes.size):
    #         comptime T = Self.AllTypes[i]
    #         comptime assert Self.AllTypes.contains[T]()
    #         comptime assert conforms_to(T, Copyable)
    #         if self.isa[T]():
    #             var val_copy = rebind_var[T](self._inner.bitcast[T]()[].copy())
    #             comptime assert Self.AllTypes.contains[type_of(val_copy)]()
    #             return {val_copy^}

    #     return {Self.NaN()}

    def __init__[
        T: Movable, //
    ](out self, var value: T) where Self.AllTypes.contains[T]():
        var ptr: UnsafePointer[T, MutUntrackedOrigin]
        if _type_is_eq_parse_time[T, Self.Table]():
            ptr = stack_allocation[1, type_of(value)]()
        else:
            ptr = alloc[T](1)

        ptr.init_pointee_move(value^)
        self._inner = ptr.bitcast[NoneType]()
        self._id = self._get_type_idx[T]()

    def isa[T: Movable](self) -> Bool where Self.AllTypes.contains[T]():
        return self._id == self._get_type_idx[T]()

    def __getitem_param__[
        T: Movable
    ](ref self) raises -> ref[self] T where Self.AllTypes.contains[T]():
        if not self.isa[T]():
            raise "The type you are trying to access is not correct."
        return self._inner.bitcast[T]()[]

    def take[
        T: Movable
    ](var self) raises -> T where Self.AllTypes.contains[T]():
        if not self.isa[T]():
            raise "The type you are trying to access is not correct."
        return self^.unsafe_take[T]()

    def unsafe_take[
        T: Movable
    ](deinit self) -> T where Self.AllTypes.contains[T]():
        assert self.isa[T]()
        return self._inner.bitcast[T]().take_pointee()

    def write_to(self, mut w: Some[Writer]):
        comptime for i in range(Self.AllTypes.size):
            comptime T = Self.AllTypes[i]
            comptime assert Self.AllTypes.contains[T]()
            comptime assert conforms_to(T, Writable)

            if self.isa[T]():
                comptime if _type_is_eq[T, Self.Array]():
                    w.write("[")
                    for i, v in enumerate(self._inner.bitcast[Self.Array]()[]):
                        if i != 0:
                            w.write(", ")
                        w.write(v)
                    w.write("]")
                elif _type_is_eq[T, Self.Table]():
                    w.write("{")
                    for i, v in enumerate(
                        self._inner.bitcast[Self.Table]()[].items()
                    ):
                        var rp = t'"{v.key}": {v.value}'
                        if i != 0:
                            w.write(", ")
                        w.write(rp)
                    w.write("}")
                else:
                    w.write(self._inner.bitcast[T]()[])
                return

    def __eq__(self, other: Toml) -> Bool:
        comptime for i in range(Self.AllTypes.size):
            comptime T = Self.AllTypes[i]
            comptime assert Self.AllTypes.contains[T]()
            comptime assert other.AllTypes.contains[T]()
            comptime assert conforms_to(T, Equatable)
            if self.isa[T]() and other.isa[T]():
                try:
                    return self[T] == other[T]
                except:
                    return False
        return False

    def to_json(self, mut w: Some[Writer]) raises:
        if self.isa[Self.String]():
            ref s = self[Self.String]
            return w.write('{"type": "string", "value": "', s, '"}')
        if self.isa[Self.Integer]():
            var intg = self[Self.Integer]
            return w.write('{"type": "integer", "value": "', intg, '"}')
        if self.isa[Self.Float]():
            var fl = self[Self.Float]
            return w.write('{"type": "float", "value": "', fl, '"}')
        if self.isa[NaN]():
            return w.write('{"type": "float", "value": "nan"}')
        if self.isa[Self.Boolean]():
            var value = "true" if self[Self.Boolean] else "false"
            return w.write('{"type": "bool", "value": "', value, '"}')
        if self.isa[Self.DateTime]():
            var dt = self[Self.DateTime]
            var nm = "datetime-local" if dt.is_local else "datetime"
            return w.write('{"type": "', nm, '", "value": "', dt, '"}')
        if self.isa[Self.Date]():
            var date = self[Self.Date]
            return w.write('{"type": "date-local", "value": "', date, '"}')
        if self.isa[Self.Time]():
            var time = self[Self.Time]
            return w.write('{"type": "time-local", "value": "', time, '"}')

        if self.isa[Self.Array]():
            ref array = self[Self.Array]
            w.write("[")
            for i, v in enumerate(array):
                if i != 0:
                    w.write(", ")

                v.to_json(w)
            w.write("]")
            return

        if self.isa[Self.Table]():
            ref table = self[Self.Table]
            w.write("{")
            for i, kv in enumerate(table.items()):
                if i != 0:
                    w.write(", ")

                w.write(t'"{kv.key}": ')
                kv.value.to_json(w)
            w.write("}")
            return

    # def __del__(deinit self):
    #     comptime for i in range(Self.AllTypes.size):
    #         comptime T = Self.AllTypes[i]
    #         comptime assert Self.AllTypes.contains[T]()
    #         comptime assert conforms_to(T, ImplicitlyDeletable)
    #         if self.isa[T]():
    #             self._inner.bitcast[T]().destroy_pointee()
    #             return
