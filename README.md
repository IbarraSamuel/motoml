# motoml
TOML reader for mojo.

`parse_toml_file(path)` parses a file using a read-only memory mapping, avoiding
the full-file allocation and copy of `FileHandle.read()`. For direct access,
`MappedFile(path)` exposes zero-copy `bytes()` and `unsafe_view()` methods;
`unsafe_view()` does not validate UTF-8, so pass it to the TOML parser before
using string operations. Keep the mapping alive while using either view and do
not truncate the file while it is mapped. Use `FileHandle.read()` instead when
an owned copy is needed or the input is not a regular seekable file.

# TODO:
