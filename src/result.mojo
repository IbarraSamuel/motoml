from std.utils import Variant
from std.os import abort
from std.memory import forget_deinit


__enum Result[T: Movable, E: Movable & Writable & Deinitable = Error](
    not Deinitable
):
    case Err(Self.E)
    case Ok(Self.T)

    def forget(deinit self) where conforms_to(Self.T, Deinitable):
        pass

    # def unsafe_take[
    #     t: Movable
    # ](deinit self, out value: t) where TypeList.of[
    #     Trait=Movable, Self.T, Self.E
    # ].contains[t]():
    #     match self:
    #         case .Ok(value):
    #             return
    #         case .Err(err):
    #             ...

    #     comptime if t == Self.T:
    #         if case .Ok(value) = self:
    #             return rebind_var[](value
    #     else:
    #         if case .Err(err) = self:
    #             return err

    #     os.abort
    #     assert self.inner.isa[t](), "No value found in the Result Type."
    #     value = self.inner^.unwrap[t]()

    @always_inline
    def unsafe_take_value(deinit self) -> Self.T:
        """Take the value. You must check that there is a value. If not, you will get UB.
        """
        # TODO: MOVE TO UNSAFE IN FUTURE
        if case .Err = self:
            abort("Unable to take a Value on an Err type.")

        var value = self.__enum_storage.payload_ptr[1]().unsafe_take_pointee()
        forget_deinit(self^)
        return value^

    @always_inline
    def unsafe_take_error(deinit self) -> Self.E:
        """Take the error. You must check that there is an error. If not, you will get UB.
        """
        # TODO: MOVE TO UNSAFE IN FUTURE
        if case .Ok = self:
            abort("Unable to take a Value on an Err type.")

        var err = self.__enum_storage.payload_ptr[0]().unsafe_take_pointee()
        forget_deinit(self^)
        return err^

    def take_error(
        var self,
    ) raises -> Self.E where conforms_to(Self.T, Deinitable):
        """Take the error or raises otherwise."""
        if case .Ok = self:
            self^.forget()
            raise "Result has a value T, not an error."
        return self^.unsafe_take_error()

    def take(var self) raises -> Self.T:
        if case .Err = self:
            raise self^.unsafe_take_error()
        return self^.unsafe_take_value()

    def as_optional(var self) -> Optional[Self.T]:
        """Convert to an Optional type."""
        if case .Err = self:
            _ = self^.unsafe_take_error()
            return None
        return self^.unsafe_take_value()

    def or_else(
        var self, var default: Self.T
    ) -> Self.T where conforms_to(Self.T, Deinitable):
        """Take the value or return a default value."""
        if case .Err = self:
            _ = self^.unsafe_take_error()
            return default^
        _ = default^
        return self^.unsafe_take_value()

    def and_then[
        O: Movable, //
    ](var self, func: def(var Self.T) thin -> Result[O, Self.E]) -> Result[
        O, Self.E
    ]:
        if case .Err = self:
            return .Err(self^.unsafe_take_error())
        var new_result = func(self^.unsafe_take_value())
        if case .Err = new_result:
            return .Err(new_result^.unsafe_take_error())
        return .Ok(new_result^.unsafe_take_value())

    def map[
        O: Movable, //
    ](var self, func: def(var Self.T) thin -> O) -> Result[O, Self.E]:
        if case .Err = self:
            return .Err(self^.unsafe_take_error())
        return .Ok(func(self^.unsafe_take_value()))


# struct Result[T: Movable, E: Movable & Writable & Deinitable = Error](
#     Deinitable where False,
#     EnumLike,
#     Equatable where conforms_to(T, Equatable),
#     Movable,
#     Writable,
# ):
#     var inner: Variant[Self.T, Self.E]
#     comptime _enum_case_names = ParameterList.of["Ok".value, "Err".value].values
#     comptime _enum_case_types = TypeList.of[Self.T, Self.E].values

#     def _get_enum_discriminant(self) -> Int:
#         return Int(not self.inner.isa[Self.T]())

#     def _unsafe_get_enum_payload[
#         id: Int
#     ](ref self) -> ref[self] TypeList[Trait=AnyType, Self._enum_case_types]()[
#         id
#     ]:
#         return Pointer(
#             to=self.inner[TypeList[Trait=AnyType, Self._enum_case_types]()[id]]
#         ).unsafe_origin_cast[origin_of(self)]()[]

#     # def variants(
#     #     deinit self,
#     # ) -> ResultVariants[Self.T, Self.E] where conforms_to(
#     #     Self.T, Movable & Deinitable
#     # ):
#     #     return ResultVariants[Self.T, Self.E](self.inner^)

#     @implicit
#     def __init__(out self, var value: Self.T):
#         self.inner = value^

#     @implicit
#     def __init__(out self, var error: Self.E):
#         self.inner = error^

#     # def __getitem__(
#     #     self,
#     # ) raises -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.T:
#     #     if case .Err = self:
#     #         raise "Result type doesn't hold a value."
#     #     return self.unsafe_ref_value()

#     # def unsafe_ref_value(
#     #     self,
#     # ) -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.T:
#     #     assert self.inner.isa[Self.T](), "Result type doesn't hold a value."
#     #     return self.inner[Self.T]

#     # def ref_error(
#     #     self,
#     # ) raises -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.E:
#     #     if case .Ok = self:
#     #         raise "Result Type doesn't have an Error value."
#     #     return self.unsafe_ref_error()

#     # def unsafe_ref_error(
#     #     self,
#     # ) -> ref[origin_of(self.inner)._get_owned_interior["value"]] Self.E:
#     #     assert self.inner.isa[Self.E](), "Result type doesn't hold an error."
#     #     return self.inner[Self.E]

#     # -- Destroy methods --

#     def forget(deinit self) where conforms_to(Self.T, Deinitable):
#         pass

#     def unsafe_take[
#         t: Movable
#     ](deinit self, out value: t) where TypeList.of[
#         Trait=Movable, Self.T, Self.E
#     ].contains[t]():
#         assert self.inner.isa[t](), "No value found in the Result Type."
#         value = self.inner^.unwrap[t]()

#     @always_inline
#     def unsafe_take_value(deinit self) -> Self.T:
#         """Take the value. You must check that there is a value. If not, you will get UB.
#         """
#         # TODO: MOVE TO UNSAFE IN FUTURE
#         return self^.unsafe_take[Self.T]()

#     @always_inline
#     def unsafe_take_error(deinit self) -> Self.E:
#         """Take the error. You must check that there is an error. If not, you will get UB.
#         """
#         # TODO: MOVE TO UNSAFE IN FUTURE
#         return self^.unsafe_take[Self.E]()

#     def take_error(
#         var self,
#     ) raises -> Self.E where conforms_to(Self.T, Deinitable):
#         """Take the error or raises otherwise."""
#         if case .Ok = self:
#             _ = self^.unsafe_take_value()
#             raise "Result has a value T, not an error."
#         return self^.unsafe_take_error()

#     def take_value(var self) raises -> Self.T:
#         if case .Err = self:
#             raise self^.unsafe_take_error()
#         return self^.unsafe_take_value()

#     def as_optional(var self) -> Optional[Self.T]:
#         """Convert to an Optional type."""
#         if case .Err = self:
#             _ = self^.unsafe_take_error()
#             return None
#         return self^.unsafe_take_value()

#     def or_else(
#         var self, var default: Self.T
#     ) -> Self.T where conforms_to(Self.T, Deinitable):
#         """Take the value or return a default value."""
#         if case .Err = self:
#             _ = self^.unsafe_take_error()
#             return default^
#         _ = default^
#         return self^.unsafe_take_value()

#     def and_then[
#         O: Movable, e: Writable & Movable & Deinitable, //
#     ](var self, func: def(var Self.T) thin -> Result[O, e]) -> Result[O, Error]:
#         if case .Err = self:
#             return Error(self^.unsafe_take_error())
#         var new_result = func(self^.unsafe_take_value())
#         if case .Err = new_result:
#             return Error(new_result^.unsafe_take_error())
#         return new_result^.unsafe_take_value()

#     def map[
#         O: Movable, //
#     ](var self, func: def(var Self.T) thin -> O) -> Result[O, Self.E]:
#         if case .Err = self:
#             return self^.unsafe_take_error()
#         return func(self^.unsafe_take_value())
