import os
from collections.dict import _DictIndex
from builtin.rebind import downcast
from sys.intrinsics import likely
from reflection import get_type_name


@explicit_destroy("You should free this pointer.")
struct OwnedOpaque[TypeName: StaticString, //, mut: Bool = False](Movable):
    comptime Ptr = UnsafePointer[NoneType, ExternalOrigin[mut = Self.mut]]
    var ptr: Self.Ptr
    var size: Int

    fn __init__(out self, unsafe_from_ptr: Self.Ptr, size: Int):
        self.ptr = unsafe_from_ptr
        self.size = size

    fn __init__[T: Movable & ImplicitlyDestructible](out self, var take: T):
        comptime assert get_type_name[T]() == Self.TypeName
        var ptr = alloc[T](1)
        ptr.init_pointee_move(take^)
        self.ptr = ptr.mut_cast[target_mut = Self.mut]().bitcast[NoneType]()
        self.size = 1

    fn offset[T: Movable & ImplicitlyDestructible](ref self, i: Int) -> Self:
        comptime assert (
            get_type_name[T]() == Self.TypeName
        ), "The type used should be the same."
        var shifted = (self.ptr.bitcast[T]() + i).bitcast[NoneType]()
        return Self(unsafe_from_ptr=shifted, size=1)

    fn __getitem__[
        T: Movable & ImplicitlyDestructible
    ](mut self: OwnedOpaque[mut=True]) -> ref[self] T:
        comptime assert (
            get_type_name[T]() == Self.TypeName
        ), "The type used should be the same."
        return self.ptr.bitcast[T]()[]

    fn view[T: Movable & ImplicitlyDestructible](self) -> ref[self] T:
        comptime assert (
            get_type_name[T]() == Self.TypeName
        ), "The type used should be the same."
        return self.ptr.bitcast[T]()[]

    fn ref_idx[
        T: Movable & ImplicitlyDestructible
    ](ref self: OwnedOpaque[mut=True], idx: Int) -> ref[self] T:
        comptime assert (
            get_type_name[T]() == Self.TypeName
        ), "The type used should be the same."
        ref loc = (self.ptr.bitcast[T]() + idx)[]
        return UnsafePointer(to=loc)[]

    fn free[T: Movable & ImplicitlyDestructible](deinit self):
        comptime assert (
            get_type_name[T]() == Self.TypeName
        ), "The type used should be the same."
        self.ptr.bitcast[T]().unsafe_mut_cast[target_mut=True]().free()

    fn init_pointee_move[
        T: Movable & ImplicitlyDestructible
    ](self: OwnedOpaque[mut=True], var pointee: T, offset: Int = 0):
        comptime assert (
            get_type_name[T]() == Self.TypeName
        ), "The type used should be the same."
        (self.ptr.bitcast[T]() + offset).init_pointee_move(pointee^)

    fn take_pointee[
        T: Movable & ImplicitlyDestructible
    ](deinit self: OwnedOpaque[mut=True]) -> T:
        comptime assert (
            get_type_name[T]() == Self.TypeName
        ), "The type used should be the same."
        return self.ptr.bitcast[T]().take_pointee()

    fn unsafe_ignore_data(deinit self):
        pass


struct Vec[T: Movable & ImplicitlyDestructible, /, *, mut: Bool = False](
    Movable, Sized
):
    comptime Ptr = OwnedOpaque[
        TypeName = get_type_name[Self.T](), mut = Self.mut
    ]
    var _data: Self.Ptr
    var _len: Int
    var capacity: Int

    # fn __init__(out self, *, capacity: Int):
    #     self._data = alloc[Self.T](capacity).mut_cast[target_mut = Self.mut]()
    #     self.capacity = capacity
    #     self._len = -1

    fn __init__(
        out self, *, length: Int, fill: Self.T
    ) where conforms_to(Self.T, Copyable):
        var ptr = alloc[Self.T](length).mut_cast[target_mut = Self.mut]()

        ref _fill = trait_downcast[Copyable](fill)
        for i in range(length):
            (ptr + i).bitcast[downcast[Self.T, Copyable]]().unsafe_mut_cast[
                target_mut=True
            ]().init_pointee_copy(_fill)

        self.capacity = length
        self._len = length - 1
        self._data = Self.Ptr(
            unsafe_from_ptr=ptr.bitcast[NoneType](), size=length
        )

    fn unsafe_push(mut self: Vec[Self.T, mut=True], var v: Self.T):
        """In case there is no capacity, just update the last one."""
        self._len = min(self._len + 1, self.capacity - 1)
        var last_position = self._data.offset[Self.T](self._len)
        last_position.init_pointee_move(v^)
        # Safety: Will be handled still by the original pointer.
        last_position^.unsafe_ignore_data()

    fn unsafe_pop(mut self: Vec[Self.T, mut=True]) -> Self.T:
        """In case there is no more data, just raise an abort."""
        var obj_ptr = self._data.offset[Self.T](self._len)
        self._len -= 1
        if self._len == -2:
            obj_ptr^.free[Self.T]()
            os.abort("No more records to pop.")
        return obj_ptr^.take_pointee[Self.T]()

    fn __getitem__(ref self: Vec[mut=True], idx: Int) -> ref[self._data] Self.T:
        return self._data.ref_idx[Self.T](idx)

    fn __del__(deinit self):
        self._data^.free[Self.T]()

    fn __len__(self) -> Int:
        return self._len + 1


from hashlib import Hasher, default_hasher


@fieldwise_init
struct DictEntry[
    o: ImmutOrigin,
    V: Movable & ImplicitlyDestructible,
    H: Hasher = default_hasher,
](Movable):
    var hash: UInt64
    var key: StringSlice[Self.o]
    var value: Self.V

    fn __init__(out self, var key: StringSlice[Self.o], var value: Self.V):
        self.hash = hash[HasherType = Self.H](key)
        self.key = key
        self.value = value^

    fn take_value(deinit self) -> Self.V:
        return self.value^


struct SliceMap[
    o: ImmutOrigin,
    V: Movable & ImplicitlyDestructible,
    H: Hasher = default_hasher,
](Movable):
    comptime EMPTY = -1
    comptime REMOVED = -2

    var _len: Int
    var _n_entries: Int
    var _index: _DictIndex
    var _entries: Vec[Optional[DictEntry[Self.o, Self.V, Self.H]], mut=True]

    fn __init__(out self, *, capacity: Int = 8):
        self._len = 0
        self._n_entries = 0
        # self._entries = {capacity=2}
        self._entries = {length = capacity, fill = None}
        self._index = _DictIndex(capacity)

    fn __getitem__(
        ref self, key: StringSlice
    ) -> ref[self._entries[0].value().value] Self.V:
        var hash = hash[HasherType = Self.H](key)
        var slot = hash & UInt64(len(self._entries) - 1)
        var idx = self._index.get_index(len(self._entries), slot)
        return self._entries[idx].unsafe_value().value

    fn setdefault(
        mut self, key: StringSlice[Self.o], var default: Self.V
    ) -> ref[self._entries[0].value().value] Self.V:
        var found, slot, index = self._find_index(
            hash[HasherType = Self.H](key), key
        )
        ref entry = self._entries[index]
        if not found:
            entry = DictEntry[H = Self.H](key, default^)
            self._index.set_index(len(self._entries), slot, index)
            self._len += 1
            self._n_entries += 1
        return entry.unsafe_value().value

    # fn _get_index(self, slot: UInt64) -> Int:
    #     return self._index.get_index(len(self._entries), slot)

    fn _find_index(
        self, hash: UInt64, key: StringSlice[...]
    ) -> Tuple[Bool, UInt64, Int]:
        var slot = hash & UInt64(len(self._entries) - 1)
        var perturb = hash
        while True:
            var index = self._index.get_index(len(self._entries), slot)
            if index == Self.EMPTY:
                return (False, slot, self._n_entries)
            elif index == Self.REMOVED:
                pass
            else:
                ref entry = self._entries[index]
                ref val = entry.unsafe_value()
                if val.hash == hash and likely(val.key == key):
                    return True, slot, index

            self._next_index_slot(slot, perturb)

    fn _next_index_slot(self, mut slot: UInt64, mut perturb: UInt64):
        comptime PERTURB_SHIFT = 5
        perturb >>= PERTURB_SHIFT
        slot = ((5 * slot) + UInt64(Int(perturb + 1))) & UInt64(
            len(self._entries) - 1
        )

    # fn _find_ref(
    #     ref self, key: StringSlice
    # ) -> ref[self._entries[0].value().value] Self.V:
    #     var hash = hash[HasherType = Self.H](key)
    #     var found, _, index = self._find_index(hash, key)

    #     if found:
    #         ref entry = self._entries[index]
    #         debug_assert(entry.__bool__(), "entry in index must be full")
    #         # SAFETY: We just checked that `entry` is present.
    #         return entry.unsafe_value().value

    #     os.abort("KeyError")
