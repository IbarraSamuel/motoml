"""Schema customization annotations (`toml_attr`, `CaseStyle`) and compile-time metadata queries."""

from std.builtin.enum_like import EnumLike
from std.builtin.variadics import ParameterList, TypeList
from std.collections.string.string_span import get_static_string
from std.memory import MutPointer


@fieldwise_init
struct CaseStyle(EnumLike, Equatable, TrivialRegisterPassable, Writable):
    """Identifier case conversion convention for `toml_attr.rename_all(...)`."""

    var _value: UInt8

    comptime snake = Self(0)
    comptime kebab = Self(1)
    comptime camel = Self(2)
    comptime pascal = Self(3)
    comptime screaming_snake = Self(4)
    comptime screaming_kebab = Self(5)

    comptime _enum_case_names = ParameterList.of[
        "snake".value,
        "kebab".value,
        "camel".value,
        "pascal".value,
        "screaming_snake".value,
        "screaming_kebab".value,
    ].values
    comptime _enum_case_types = TypeList.splat[6, Tuple[]].values

    @always_inline
    def _get_enum_discriminant(self) -> Int:
        return Int(self._value)

    @always_inline
    def _unsafe_get_enum_payload[
        id: Int
    ](ref self) -> ref[self] TypeList[Trait=AnyType, Self._enum_case_types]()[
        id
    ]:
        comptime assert False, "CaseStyle has no payload"

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def write_to(self, mut w: Some[Writer]):
        match self:
            case .snake:
                w.write("CaseStyle.snake")
            case .kebab:
                w.write("CaseStyle.kebab")
            case .camel:
                w.write("CaseStyle.camel")
            case .pascal:
                w.write("CaseStyle.pascal")
            case .screaming_snake:
                w.write("CaseStyle.screaming_snake")
            case .screaming_kebab:
                w.write("CaseStyle.screaming_kebab")


@always_inline
def _is_ascii_upper(b: Byte) -> Bool:
    return Byte(ord("A")) <= b <= Byte(ord("Z"))


@always_inline
def _is_ascii_lower(b: Byte) -> Bool:
    return Byte(ord("a")) <= b <= Byte(ord("z"))


@always_inline
def _is_ascii_digit(b: Byte) -> Bool:
    return Byte(ord("0")) <= b <= Byte(ord("9"))


@always_inline
def _to_ascii_lower(b: Byte) -> Byte:
    if _is_ascii_upper(b):
        return b + 32
    return b


@always_inline
def _to_ascii_upper(b: Byte) -> Byte:
    if _is_ascii_lower(b):
        return b - 32
    return b


@always_inline
def _append_byte(mut out: String, b: Byte):
    var tmp = b
    out += StringSpan(
        unsafe_from_utf8=Span(unsafe_ptr=Pointer(to=tmp), length=1)
    )


def _convert_case(s: StaticString, style: CaseStyle) -> String:
    """Split an identifier on `_`, `-`, and camelCase boundaries and format in `style`.
    """
    var bytes = s.as_bytes()
    var n = len(bytes)
    if n == 0:
        return String()

    var words = List[Tuple[Int, Int]]()
    var i = 0
    while i < n:
        var b = bytes[i]
        if b == Byte(ord("_")) or b == Byte(ord("-")):
            i += 1
            continue
        var w_start = i
        if _is_ascii_upper(b):
            i += 1
            while i < n and _is_ascii_upper(bytes[i]):
                if i + 1 < n and _is_ascii_lower(bytes[i + 1]):
                    break
                i += 1
            while i < n and (
                _is_ascii_lower(bytes[i]) or _is_ascii_digit(bytes[i])
            ):
                i += 1
        else:
            i += 1
            while i < n and (
                _is_ascii_lower(bytes[i]) or _is_ascii_digit(bytes[i])
            ):
                i += 1
        words.append((w_start, i))

    var out = String()
    var num_words = len(words)
    for wi in range(num_words):
        var start, end = words[wi]
        match style:
            case .snake:
                if wi > 0:
                    _append_byte(out, Byte(ord("_")))
                for k in range(start, end):
                    _append_byte(out, _to_ascii_lower(bytes[k]))
            case .kebab:
                if wi > 0:
                    _append_byte(out, Byte(ord("-")))
                for k in range(start, end):
                    _append_byte(out, _to_ascii_lower(bytes[k]))
            case .screaming_snake:
                if wi > 0:
                    _append_byte(out, Byte(ord("_")))
                for k in range(start, end):
                    _append_byte(out, _to_ascii_upper(bytes[k]))
            case .screaming_kebab:
                if wi > 0:
                    _append_byte(out, Byte(ord("-")))
                for k in range(start, end):
                    _append_byte(out, _to_ascii_upper(bytes[k]))
            case .camel:
                for k in range(start, end):
                    if wi > 0 and k == start:
                        _append_byte(out, _to_ascii_upper(bytes[k]))
                    else:
                        _append_byte(out, _to_ascii_lower(bytes[k]))
            case .pascal:
                for k in range(start, end):
                    if k == start:
                        _append_byte(out, _to_ascii_upper(bytes[k]))
                    else:
                        _append_byte(out, _to_ascii_lower(bytes[k]))
    return out^


def _convert_case_static[s: StaticString, style: CaseStyle]() -> StaticString:
    return get_static_string[_convert_case(s, style)]()


# --- Internal annotation value structs ---


trait _IsDefaultAttr:
    pass


@fieldwise_init
struct _Rename(Deinitable, ImplicitlyCopyable):
    var name: StaticString


@fieldwise_init
struct _RenameAll(Deinitable, ImplicitlyCopyable):
    var style: CaseStyle


@fieldwise_init
struct _Alias(Deinitable, ImplicitlyCopyable):
    var name: StaticString


struct _Default[V: Copyable & Deinitable](Copyable, Deinitable, _IsDefaultAttr):
    var value: Self.V

    def __init__(out self, var value: Self.V):
        self.value = value^


@fieldwise_init
struct _DefaultInit(Deinitable, ImplicitlyCopyable):
    pass


@fieldwise_init
struct _Skip(Deinitable, ImplicitlyCopyable):
    pass


@fieldwise_init
struct _SkipIfEmpty(Deinitable, ImplicitlyCopyable):
    pass


@fieldwise_init
struct _DenyUnknownFields(Deinitable, ImplicitlyCopyable):
    pass


@fieldwise_init
struct _Flatten(Deinitable, ImplicitlyCopyable):
    pass


@fieldwise_init
struct _Tag(Deinitable, ImplicitlyCopyable):
    var key: StaticString


@fieldwise_init
struct _Content(Deinitable, ImplicitlyCopyable):
    var key: StaticString


# --- Public `toml_attr` namespace ---


struct toml_attr:
    """Compile-time schema annotations for `motoml` reflection (`take[T]()` and `to_toml()`).

    Attach to structs, struct fields, `__enum`s, or `__union`s via `@__annotation(...)`:

    ```mojo
    from motoml import toml_attr, parse_toml, to_toml

    @__annotation(toml_attr.kebab_case, toml_attr.deny_unknown_fields)
    struct ServerConfig(Movable):
        var bind_host: String
        @__annotation(toml_attr.default(8080), toml_attr.alias("listen_port"))
        var bind_port: UInt16
        @__annotation(toml_attr.rename("tls-enabled"), toml_attr.default(False))
        var tls: Bool
    ```
    """

    # Struct / enum / union case-conversion shorthands
    comptime snake_case = _RenameAll(CaseStyle.snake)
    comptime kebab_case = _RenameAll(CaseStyle.kebab)
    comptime camel_case = _RenameAll(CaseStyle.camel)
    comptime pascal_case = _RenameAll(CaseStyle.pascal)
    comptime screaming_snake_case = _RenameAll(CaseStyle.screaming_snake)
    comptime screaming_kebab_case = _RenameAll(CaseStyle.screaming_kebab)

    # Unit marker annotations
    comptime default_init = _DefaultInit()
    comptime skip = _Skip()
    comptime skip_if_empty = _SkipIfEmpty()
    comptime deny_unknown_fields = _DenyUnknownFields()
    comptime flatten = _Flatten()

    @staticmethod
    def rename(name: StaticString) -> _Rename:
        """Override the serialized/deserialized TOML key name for a struct field.
        """
        return _Rename(name)

    @staticmethod
    def rename_all(style: CaseStyle) -> _RenameAll:
        """Transform all field names of a struct or case names of an enum/union using `style`.
        """
        return _RenameAll(style)

    @staticmethod
    def alias(name: StaticString) -> _Alias:
        """Accept an alternate TOML key name when deserializing a field if its primary key is absent.
        """
        return _Alias(name)

    @staticmethod
    def default(value: StringLiteral) -> _Default[StaticString]:
        """Provide a string literal default value when a `String` or `StaticString` field is absent.
        """
        return _Default[StaticString](StaticString(value))

    @staticmethod
    def default[V: Copyable & Deinitable](var value: V) -> _Default[V]:
        """Provide a typed default value when a struct field is absent in TOML.
        """
        return _Default[V](value^)

    @staticmethod
    def tag(key: StaticString) -> _Tag:
        """Use internal or adjacent union tagging on a `__union` under table key `key`.
        """
        return _Tag(key)

    @staticmethod
    def content(key: StaticString) -> _Content:
        """Pair with `toml_attr.tag(...)` on a `__union` to place payloads under `key`.
        """
        return _Content(key)


# --- Compile-time metadata queries ---


def _type_rename_all[T: AnyType]() -> Optional[CaseStyle]:
    comptime AT = type_of(reflect[T].annotations()).Ts
    comptime if AT.length == 0:
        return None
    var attrs = reflect[T].annotations()
    var found = Optional[CaseStyle](None)
    comptime for i in range(AT.length):
        comptime if AT[i] == _RenameAll:
            found = rebind[_RenameAll](attrs[i]).style
    return found


def _struct_deny_unknown[T: AnyType]() -> Bool:
    comptime AT = type_of(reflect[T].annotations()).Ts
    var found = False
    comptime for i in range(AT.length):
        comptime if AT[i] == _DenyUnknownFields:
            found = True
    return found


def _union_tag[E: AnyType]() -> Optional[StaticString]:
    comptime AT = type_of(reflect[E].annotations()).Ts
    comptime if AT.length == 0:
        return None
    var attrs = reflect[E].annotations()
    var found = Optional[StaticString](None)
    comptime for i in range(AT.length):
        comptime if AT[i] == _Tag:
            found = rebind[_Tag](attrs[i]).key
    return found


def _union_content[E: AnyType]() -> Optional[StaticString]:
    comptime AT = type_of(reflect[E].annotations()).Ts
    comptime if AT.length == 0:
        return None
    var attrs = reflect[E].annotations()
    var found = Optional[StaticString](None)
    comptime for i in range(AT.length):
        comptime if AT[i] == _Content:
            found = rebind[_Content](attrs[i]).key
    return found


def _field_explicit_rename[T: AnyType, idx: Int]() -> Optional[StaticString]:
    comptime FT = type_of(reflect[T].field_annotations[idx]()).Ts
    comptime if FT.length == 0:
        return None
    var attrs = reflect[T].field_annotations[idx]()
    var found = Optional[StaticString](None)
    comptime for i in range(FT.length):
        comptime if FT[i] == _Rename:
            found = rebind[_Rename](attrs[i]).name
    return found


def _effective_field_name[T: AnyType, idx: Int]() -> StaticString:
    """Compute the effective TOML key name for field `idx` of `T` completely at compile time.
    """
    comptime explicit = _field_explicit_rename[T, idx]()
    comptime if case .Some(renamed) = explicit:
        return renamed
    comptime raw = reflect[T].field_names()[idx]
    comptime style_opt = _type_rename_all[T]()
    comptime if case .Some(style) = style_opt:
        return _convert_case_static[raw, style]()
    return raw


def _effective_case_name[E: EnumLike, idx: Int]() -> StaticString:
    """Compute the effective TOML case name for case `idx` of `E` completely at compile time.
    """
    comptime raw = StaticString(ParameterList[E._enum_case_names]()[idx])
    comptime style_opt = _type_rename_all[E]()
    comptime if case .Some(style) = style_opt:
        return _convert_case_static[raw, style]()
    return raw


def _field_is_skipped[T: AnyType, idx: Int]() -> Bool:
    comptime FT = type_of(reflect[T].field_annotations[idx]()).Ts
    var found = False
    comptime for i in range(FT.length):
        comptime if FT[i] == _Skip:
            found = True
    return found


def _field_is_flattened[T: AnyType, idx: Int]() -> Bool:
    comptime FT = type_of(reflect[T].field_annotations[idx]()).Ts
    var found = False
    comptime for i in range(FT.length):
        comptime if FT[i] == _Flatten:
            found = True
    return found


def _field_skip_if_empty[T: AnyType, idx: Int]() -> Bool:
    comptime FT = type_of(reflect[T].field_annotations[idx]()).Ts
    var found = False
    comptime for i in range(FT.length):
        comptime if FT[i] == _SkipIfEmpty:
            found = True
    return found


def _field_has_default_value[T: AnyType, idx: Int]() -> Bool:
    comptime FT = type_of(reflect[T].field_annotations[idx]()).Ts
    var found = False
    comptime for i in range(FT.length):
        comptime if conforms_to(FT[i], _IsDefaultAttr):
            found = True
    return found


def _field_has_default_init[T: AnyType, idx: Int]() -> Bool:
    comptime FT = type_of(reflect[T].field_annotations[idx]()).Ts
    var found = False
    comptime for i in range(FT.length):
        comptime if FT[i] == _DefaultInit:
            found = True
    return found


def _field_alias_count[T: AnyType, idx: Int]() -> Int:
    comptime FT = type_of(reflect[T].field_annotations[idx]()).Ts
    var count = 0
    comptime for i in range(FT.length):
        comptime if FT[i] == _Alias:
            count += 1
    return count


def _field_alias_at[T: AnyType, idx: Int, target_alias: Int]() -> StaticString:
    var attrs = reflect[T].field_annotations[idx]()
    comptime FT = type_of(attrs).Ts
    var seen = 0
    var result: StaticString = ""
    comptime for i in range(FT.length):
        comptime if FT[i] == _Alias:
            if seen == target_alias:
                result = rebind[_Alias](attrs[i]).name
            seen += 1
    return result


@always_inline
def _write_defaultable_field[
    FieldT: AnyType, origin: MutOrigin, //
](dst: MutPointer[FieldT, origin]) where conforms_to(FieldT, Defaultable):
    dst.unsafe_write(init_with=lambda () -> FieldT: FieldT())


def _write_field_default[
    T: AnyType, idx: Int, FieldT: Movable & Deinitable
](dst: MutPointer[FieldT, _]) raises:
    """Initialize `dst` from field `idx`'s `toml_attr.default(...)` or `toml_attr.default_init`.
    """
    comptime if _field_has_default_value[T, idx]():
        var attrs = reflect[T].field_annotations[idx]()
        comptime FT = type_of(attrs).Ts
        var written = False
        comptime for i in range(FT.length):
            comptime if conforms_to(FT[i], _IsDefaultAttr):
                if not written:
                    comptime AttrT = FT[i]
                    comptime ValT = reflect[AttrT].field_at[0].T
                    ref val_ref = reflect[AttrT].field_ref[0](attrs[i])
                    comptime if ValT == FieldT:
                        comptime assert conforms_to(ValT, Copyable)
                        dst.unsafe_write(rebind_var[FieldT](val_ref.copy()))
                    elif ValT == StaticString and FieldT == String:
                        var s = String(rebind[StaticString](val_ref))
                        dst.unsafe_write(rebind_var[FieldT](s^))
                    elif ValT == Int and FieldT == Int64:
                        dst.unsafe_write(
                            rebind_var[FieldT](Int64(rebind[Int](val_ref)))
                        )
                    elif ValT == Int and FieldT == Int32:
                        var iv = rebind[Int](val_ref)
                        if iv < -2147483648 or iv > 2147483647:
                            raise Error("Default integer out of Int32 range.")
                        dst.unsafe_write(rebind_var[FieldT](Int32(iv)))
                    elif ValT == Int and FieldT == Int16:
                        var iv = rebind[Int](val_ref)
                        if iv < -32768 or iv > 32767:
                            raise Error("Default integer out of Int16 range.")
                        dst.unsafe_write(rebind_var[FieldT](Int16(iv)))
                    elif ValT == Int and FieldT == Int8:
                        var iv = rebind[Int](val_ref)
                        if iv < -128 or iv > 127:
                            raise Error("Default integer out of Int8 range.")
                        dst.unsafe_write(rebind_var[FieldT](Int8(iv)))
                    elif ValT == Int and FieldT == UInt:
                        var iv = rebind[Int](val_ref)
                        if iv < 0:
                            raise Error(
                                "Negative default integer cannot convert to"
                                " UInt."
                            )
                        dst.unsafe_write(rebind_var[FieldT](UInt(iv)))
                    elif ValT == Int and FieldT == UInt64:
                        var iv = rebind[Int](val_ref)
                        if iv < 0:
                            raise Error(
                                "Negative default integer cannot convert to"
                                " UInt64."
                            )
                        dst.unsafe_write(rebind_var[FieldT](UInt64(iv)))
                    elif ValT == Int and FieldT == UInt32:
                        var iv = rebind[Int](val_ref)
                        if iv < 0 or iv > 4294967295:
                            raise Error("Default integer out of UInt32 range.")
                        dst.unsafe_write(rebind_var[FieldT](UInt32(iv)))
                    elif ValT == Int and FieldT == UInt16:
                        var iv = rebind[Int](val_ref)
                        if iv < 0 or iv > 65535:
                            raise Error("Default integer out of UInt16 range.")
                        dst.unsafe_write(rebind_var[FieldT](UInt16(iv)))
                    elif ValT == Int and FieldT == UInt8:
                        var iv = rebind[Int](val_ref)
                        if iv < 0 or iv > 255:
                            raise Error("Default integer out of UInt8 range.")
                        dst.unsafe_write(rebind_var[FieldT](UInt8(iv)))
                    elif ValT == Float64 and FieldT == Float32:
                        dst.unsafe_write(
                            rebind_var[FieldT](
                                Float32(rebind[Float64](val_ref))
                            )
                        )
                    else:
                        comptime assert False, String(
                            t"toml_attr.default value type"
                            t" {reflect[ValT].name()} cannot initialize field"
                            t" '{reflect[T].field_names()[idx]}' of type"
                            t" {reflect[FieldT].name()}."
                        )
                    written = True
    else:
        comptime assert conforms_to(FieldT, Defaultable), String(
            t"Field '{reflect[T].field_names()[idx]}' of {reflect[T].name()}"
            t" requires Defaultable or toml_attr.default(...)."
        )
        _write_defaultable_field(dst)
