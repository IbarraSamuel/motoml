"""Internal struct reflection cleanup helpers."""

from std.memory import Allocation, Pointer, dealloc


def _destroy_partial_struct[
    T: Movable
](var allocation: Allocation[T], initialized_fields: Int):
    """Destroy the first `initialized_fields` fields of a partially built struct.
    """
    comptime Tr = reflect[T]
    comptime field_types = Tr.field_types()
    comptime field_count = Tr.field_count()
    var struct_ptr = allocation.unsafe_ptr()

    comptime for fi in reversed(range(field_count)):
        comptime TYPE = field_types[fi]
        comptime assert conforms_to(TYPE, Deinitable)
        if initialized_fields > fi:
            ref field = Tr.field_ref[fi](struct_ptr[])
            Pointer(to=field).unsafe_deinit_pointee()

    dealloc(allocation^)
