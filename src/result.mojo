from std.utils import Variant


struct Result[T: Movable, E: Movable & Writable & ImplicitlyDeletable = Error](
    Boolable,
    Equatable where conforms_to(T, Equatable),
    ImplicitlyDeletable where False,
    Movable,
    Writable,
):
    var inner: Variant[Self.T, Self.E]

    @implicit
    def __init__(out self, var value: Self.T):
        self.inner = value^

    @implicit
    def __init__(out self, var error: Self.E):
        self.inner = error^

    def __bool__(self) -> Bool:
        return self.inner.isa[Self.T]()

    def __eq__(self, other: Self) -> Bool where conforms_to(Self.T, Equatable):
        return (
            Bool(self)
            and Bool(other)
            and self.unsafe_ref_value() == other.unsafe_ref_value()
        )

    @__unsafe_nested_origins_read_only
    def __getitem__(
        ref self,
    ) raises -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.T:
        if not self:
            raise "Result type doesn't hold a value."
        return self.unsafe_ref_value()

    # @always_inline
    @__unsafe_nested_origins_read_only
    def unsafe_ref_value(
        ref self,
    ) -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.T:
        assert Bool(self), "Result type doesn't hold a value."
        return self.inner[Self.T]

    @__unsafe_nested_origins_read_only
    def ref_error(
        ref self,
    ) raises -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.E:
        if self:
            raise "Result Type doesn't have an Error value."
        return self.unsafe_ref_error()

    # @always_inline
    @__unsafe_nested_origins_read_only
    def unsafe_ref_error(
        ref self,
    ) -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.E:
        assert not self, "Result type doesn't hold an error."
        return self.inner[Self.E]

    # -- Destroy methods --

    def forget(deinit self):
        pass

    def unsafe_take[
        t: Movable
    ](deinit self, out value: t) where TypeList.of[
        Trait=Movable, Self.T, Self.E
    ].contains[t]():
        assert Bool(self), "No value found in the Result Type."
        value = self.inner^.take[t]()

    @always_inline
    def unsafe_take_value(deinit self) -> Self.T:
        """Take the value. You must check that there is a value. If not, you will get UB.
        """
        # TODO: MOVE TO UNSAFE IN FUTURE
        return self^.unsafe_take[Self.T]()

    @always_inline
    def unsafe_take_error(deinit self) -> Self.E:
        """Take the error. You must check that there is an error. If not, you will get UB.
        """
        # TODO: MOVE TO UNSAFE IN FUTURE
        return self^.unsafe_take[Self.E]()

    def take_error(var self) raises -> Self.E:
        """Take the error or raises otherwise."""
        if self:
            comptime assert conforms_to(Self.T, ImplicitlyDeletable)
            _ = self^.unsafe_take_value()
            raise "Result has a value T, not an error."
        return self^.unsafe_take_error()

    def take_value(var self) raises -> Self.T:
        """Take the value or raises otherwise."""
        if not self:
            _ = self^.unsafe_take_error()
            raise "Result type has an error, not a value T."
        return self^.unsafe_take_value()

    def as_optional(var self) -> Optional[Self.T]:
        """Convert to an Optional type."""
        if not self:
            _ = self^.unsafe_take_error()
            return None
        return self^.unsafe_take_value()

    def or_else(var self, var default: Self.T) -> Self.T:
        """Take the value or return a default value."""
        if not self:
            _ = self^.unsafe_take_error()
            return default^
        comptime assert conforms_to(Self.T, ImplicitlyDeletable)
        _ = default^
        return self^.unsafe_take_value()

    def and_then[
        O: Movable, e: Writable & Movable & ImplicitlyDeletable, //
    ](var self, func: def(var Self.T) thin -> Result[O, e]) -> Result[O, Error]:
        if not self:
            return Error(self^.unsafe_take_error())
        var new_result = func(self^.unsafe_take_value())
        if not new_result:
            return Error(new_result^.unsafe_take_error())
        return new_result^.unsafe_take_value()

    def map[
        O: Movable, //
    ](var self, func: def(var Self.T) thin -> O) -> Result[O, Self.E]:
        if not self:
            return self^.unsafe_take_error()
        return func(self^.unsafe_take_value())
