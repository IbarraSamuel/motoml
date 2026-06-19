from std.utils import Variant
from std.sys.intrinsics import _type_is_eq_parse_time


@explicit_destroy("You should destroy, free, or take the pointer.")
@fieldwise_init
struct LinearPtr[is_empty: Bool, //, T: Movable & ImplicitlyDeletable](Movable):
    var ptr: UnsafePointer[Self.T, MutUntrackedOrigin]

    def __init__(out self: LinearPtr[is_empty=False, Self.T], var v: Self.T):
        self.ptr = alloc[Self.T](1)
        self.ptr.init_pointee_move(v^)

    def __init__(out self: LinearPtr[is_empty=True, Self.T]):
        self.ptr = alloc[Self.T](1)

    def store(
        deinit self, var v: Self.T
    ) -> LinearPtr[is_empty=False, Self.T] where Self.is_empty:
        self.ptr.init_pointee_move(v^)
        return {self.ptr}

    def take(deinit self) -> Self.T where not Self.is_empty:
        return self.ptr.take_pointee()

    def bitcast[
        t: Movable & ImplicitlyDeletable
    ](deinit self) -> LinearPtr[is_empty=False, t] where not Self.is_empty:
        return {self.ptr.bitcast[t]()}

    def unsafe_ref(ref self) -> ref[self] Self.T where Self.is_empty:
        return self.ptr[]

    def unsafe_as_initialized(
        deinit self,
    ) -> LinearPtr[is_empty=False, Self.T] where Self.is_empty:
        return {self.ptr}

    def __getitem__(ref self) -> ref[self] Self.T where not Self.is_empty:
        return self.ptr[]

    def destroy(
        deinit self,
    ) where not Self.is_empty:
        comptime assert not _type_is_eq_parse_time[Self.T, NoneType]()
        self.ptr.destroy_pointee()

    def free(deinit self) where Self.is_empty:
        comptime assert not _type_is_eq_parse_time[Self.T, NoneType]()
        self.ptr.free()


@explicit_destroy("The Result must be consumed.")
struct Result[T: Movable](
    Boolable,
    Equatable where conforms_to(T, Equatable),
    Movable,
    Writable,
):
    var inner: Variant[Self.T, Error]

    @implicit
    def __init__(out self, var value: Self.T):
        self.inner = value^

    @implicit
    def __init__(out self, var error: Error):
        self.inner = error^

    def __bool__(self) -> Bool:
        return self.inner.isa[Self.T]()

    def __eq__(self, other: Self) -> Bool where conforms_to(Self.T, Equatable):
        return (
            self.inner.isa[Self.T]()
            and other.inner.isa[Self.T]()
            and self.ref_value() == other.ref_value()
        )

    def ref_value(self) -> ref[self.inner] Self.T:
        return self.inner[Self.T]

    def ref_error(self) -> ref[self.inner] Error:
        return self.inner[Error]

    # -- Destroy methods --

    def destroy(deinit self):
        """Destroy the result, and not use the value inside."""
        self.inner^.__del__()

    @always_inline
    def unsafe_take_value(deinit self) -> Self.T:
        """Take the value. You must check that there is a value. If not, you will get UB.
        """
        return self.inner^.unsafe_take[Self.T]()

    @always_inline
    def unsafe_take_error(deinit self) -> Error:
        """Take the error. You must check that there is an error. If not, you will get UB.
        """
        return self.inner^.unsafe_take[Error]()

    def take_error(deinit self) raises -> Error:
        """Take the error or raises otherwise."""
        if self:
            raise "Result has a value T, not an error."
        return self^.unsafe_take_error()

    def take_value(deinit self) raises -> Self.T:
        """Take the value or raises otherwise."""
        if not self:
            raise "Result type has an error, not a value T."
        return self^.unsafe_take_value()

    def as_optional(deinit self) -> Optional[Self.T]:
        """Convert to an Optional type."""
        if not self:
            return None
        return self^.unsafe_take_value()

    def or_else[
        t: Movable & ImplicitlyDeletable, //
    ](deinit self: Result[t], var default: t) -> t:
        """Take the value or return a default value."""
        if not self:
            return default^
        return self^.unsafe_take_value()

    def and_then[
        O: Movable, //
    ](var self, func: def(var v: Self.T) thin -> O) -> Result[O]:
        if self:
            return func(self^.unsafe_take_value())
        else:
            return self^.unsafe_take_error()
