"""Linear `Result` union and register-passable `ScalarResult` helper."""

from std.memory import forget_deinit
from std.os import abort


@fieldwise_init
struct ScalarResult[T: TrivialRegisterPassable](
    Copyable, ImplicitlyCopyable, Movable, TrivialRegisterPassable
):
    """Lightweight register-passable result wrapper for scalar decoders."""

    var _val: Self.T
    var _ok: Bool

    @always_inline
    def __init__(out self, val: Self.T):
        self._val = val
        self._ok = True

    @always_inline
    def take(self) raises -> Self.T:
        if not self._ok:
            raise Error("Invalid scalar value.")
        return self._val

    @always_inline
    def unsafe_take_value(self) -> Self.T:
        if not self._ok:
            abort("Unable to take a Value on an Err ScalarResult.")
        return self._val

    @always_inline
    def or_else(self, default: Self.T) -> Self.T:
        return self._val if self._ok else default

    @always_inline
    def as_optional(self) -> Optional[Self.T]:
        if self._ok:
            return self._val
        return None


__union Result[T: Movable, E: Movable & Writable & Deinitable = Error](
    not Deinitable
):
    """Explicitly consumed result type returned by non-raising APIs."""

    case Err(Self.E)
    case Ok(Self.T)

    @always_inline
    def is_ok(self) -> Bool:
        if case .Ok(_) = self:
            return True
        return False

    @always_inline
    def is_err(self) -> Bool:
        if case .Err(_) = self:
            return True
        return False

    @always_inline
    def forget(deinit self) where conforms_to(Self.T, Deinitable):
        pass

    @always_inline
    def unsafe_take_value(deinit self, out o: Self.T):
        """Take the `Ok` payload. Caller must verify the variant is `.Ok`."""
        o = Pointer(
            to=self._unsafe_get_enum_payload[1]()[0]
        ).unsafe_take_pointee()
        forget_deinit(self^)

    @always_inline
    def unsafe_take_error(deinit self, out o: Self.E):
        """Take the `Err` payload. Caller must verify the variant is `.Err`."""
        o = Pointer(
            to=self._unsafe_get_enum_payload[0]()[0]
        ).unsafe_take_pointee()
        forget_deinit(self^)

    @always_inline
    def unwrap_value(deinit self) -> Self.T:
        """Take the `Ok` payload or abort if `.Err`."""
        if case .Err(_) = self:
            abort("Unable to take a Value on an Err Result.")
        return self^.unsafe_take_value()

    @always_inline
    def unwrap_error(deinit self) -> Self.E:
        """Take the `Err` payload or abort if `.Ok`."""
        if case .Ok(_) = self:
            abort("Unable to take an Error on an Ok Result.")
        return self^.unsafe_take_error()

    @always_inline
    def take_error(
        deinit self,
    ) raises -> Self.E where conforms_to(Self.T, Deinitable):
        """Take the `Err` payload or raise if `.Ok`."""
        if case .Ok(_) = self:
            self^.forget()
            raise Error("Result holds an Ok value, not an Err.")
        return self^.unsafe_take_error()

    @always_inline
    def take(deinit self) raises -> Self.T:
        """Take the `Ok` payload or raise the contained `Err`."""
        if case .Err(_) = self:
            raise self^.unsafe_take_error()
        return self^.unsafe_take_value()

    @always_inline
    def as_optional(deinit self) -> Optional[Self.T]:
        """Convert to `Optional`, discarding any `Err` payload."""
        if case .Err(_) = self:
            _ = self^.unsafe_take_error()
            return None
        return self^.unsafe_take_value()

    @always_inline
    def or_else(
        deinit self, var default: Self.T
    ) -> Self.T where conforms_to(Self.T, Deinitable):
        """Take the `Ok` payload or return `default` on `.Err`."""
        if case .Err(_) = self:
            self^.forget()
            return default^
        return self^.unsafe_take_value()

    def and_then[
        O: Movable, //
    ](var self, func: def(var Self.T) thin -> Result[O, Self.E]) -> Result[
        O, Self.E
    ]:
        if case .Err(_) = self:
            return .Err(self^.unsafe_take_error())
        var new_result = func(self^.unsafe_take_value())
        if case .Err(_) = new_result:
            return .Err(new_result^.unsafe_take_error())
        return .Ok(new_result^.unsafe_take_value())

    def map[
        O: Movable, //
    ](var self, func: def(var Self.T) thin -> O) -> Result[O, Self.E]:
        if case .Err(_) = self:
            return .Err(self^.unsafe_take_error())
        return .Ok(func(self^.unsafe_take_value()))

    def map[
        O: Movable, //
    ](var self, func: def(var Self.T) raises thin -> O) raises -> Result[
        O, Self.E
    ]:
        if case .Err(_) = self:
            return .Err(self^.unsafe_take_error())
        return .Ok(func(self^.unsafe_take_value()))
