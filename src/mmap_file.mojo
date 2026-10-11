"""Read-only, memory-mapped file access.

Returned views borrow the mapping. Keep the `MappedFile` alive and do not close
it while using those views. The mapped file must not be truncated while it is
mapped.
"""

from std.collections import Span
from std.ffi import c_int, c_size_t, external_call
from std.memory import OptionalPointer, Pointer
from std.os import PathLike as StdPathLike, SEEK_END
from std.sys._libc_errno import get_errno

comptime PROT_READ = 0x1
comptime MAP_PRIVATE = 0x2


struct MappedFile(Movable, Sized):
    """An owned, read-only mapping of an entire file."""

    var address: Int
    var length: Int

    def __init__(out self):
        self.address = 0
        self.length = 0

    def __init__[PathLike: StdPathLike](out self, path: PathLike) raises:
        self.address = 0
        self.length = 0

        var file = open(path, "r")
        self.length = Int(file.seek(0, SEEK_END))
        if self.length == 0:
            return

        var fd = file._get_raw_fd()
        var null_address: OptionalPointer[NoneType, MutUntrackedOrigin] = None
        var address = external_call["mmap", Int](
            null_address,
            c_size_t(self.length),
            c_int(PROT_READ),
            c_int(MAP_PRIVATE),
            c_int(fd),
            Int64(0),
        )
        if address == -1:
            raise Error("Failed to memory-map file: " + String(get_errno()))
        self.address = address
        # Keep the file handle alive until mmap has consumed its descriptor.
        if file._get_raw_fd() != fd:
            raise Error("File descriptor changed while mapping file.")

    def __deinit__(deinit self):
        try:
            self.close()
        except:
            pass

    def __len__(self) -> Int:
        return self.length

    def bytes(self) -> Span[Byte, origin_of(self)]:
        """Return a zero-copy view of the mapped bytes."""
        if self.length == 0:
            return Span[Byte, origin_of(self)]()
        var pointer = Pointer[Byte, ImmUntrackedOrigin](
            unsafe_from_address=self.address
        ).unsafe_origin_cast[origin_of(self)]()
        return Span[Byte, origin_of(self)](
            unsafe_ptr=pointer, length=self.length
        )

    def unsafe_view(self) -> StringSlice[origin_of(self)]:
        """Return mapped bytes as a string view without validating UTF-8.

        The caller must ensure the bytes are valid UTF-8 before using string
        operations. TOML callers should pass this view to the TOML parser,
        which validates encoding before parsing.
        """
        return StringSlice(unsafe_from_utf8=self.bytes())

    def close(mut self) raises:
        """Unmap this file. Calling this more than once is safe."""
        if self.address == 0:
            return

        var result = external_call["munmap", c_int](
            Pointer[Byte, MutUntrackedOrigin](unsafe_from_address=self.address),
            c_size_t(self.length),
        )
        if result < 0:
            raise Error("Failed to unmap file: " + String(get_errno()))

        self.address = 0
        self.length = 0
