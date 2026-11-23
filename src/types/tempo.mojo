"""RFC 3339 / TOML 1.1 temporal types (`Date`, `Time`, `Offset`, `DateTime`)
and their zero-allocation validators, decoders, and formatters."""

from std.collections import Array, Span
from ..result import ScalarResult

comptime _DIGIT_PAIRS: StaticString = (
    "0001020304050607080910111213141516171819"
    "2021222324252627282930313233343536373839"
    "4041424344454647484950515253545556575859"
    "6061626364656667686970717273747576777879"
    "8081828384858687888990919293949596979899"
)


@always_inline
def _put_2d(v: Int, dst: MutPointer[Byte, _], offset: Int):
    var dp = _DIGIT_PAIRS.unsafe_ptr().unsafe_offset(v * 2)
    dst[unsafe_offset=offset] = dp[unsafe_offset=0]
    dst[unsafe_offset=offset + 1] = dp[unsafe_offset=1]


@always_inline
def _put_4d(v: Int, dst: MutPointer[Byte, _], offset: Int):
    var hi = v // 100
    var lo = v - hi * 100
    _put_2d(hi, dst, offset)
    _put_2d(lo, dst, offset + 2)


@always_inline
def _format_date_buf(d: Date, dst: MutPointer[Byte, _], offset: Int) -> Int:
    _put_4d(d.year, dst, offset)
    dst[unsafe_offset=offset + 4] = Byte(ord("-"))
    _put_2d(d.month, dst, offset + 5)
    dst[unsafe_offset=offset + 7] = Byte(ord("-"))
    _put_2d(d.day, dst, offset + 8)
    return offset + 10


@always_inline
def _format_time_buf(t: Time, dst: MutPointer[Byte, _], offset: Int) -> Int:
    _put_2d(t.hour, dst, offset)
    dst[unsafe_offset=offset + 2] = Byte(ord(":"))
    _put_2d(t.minute, dst, offset + 3)
    dst[unsafe_offset=offset + 5] = Byte(ord(":"))
    _put_2d(t.second, dst, offset + 6)
    var pos = offset + 8
    if t.nanosecond > 0:
        dst[unsafe_offset=pos] = Byte(ord("."))
        pos += 1
        var ns = t.nanosecond
        # Write 9 fractional digits then strip trailing '0's
        var d89 = ns % 100
        ns //= 100
        var d67 = ns % 100
        ns //= 100
        var d45 = ns % 100
        ns //= 100
        var d23 = ns % 100
        var d1 = ns // 100
        dst[unsafe_offset=pos] = Byte(ord("0") + d1)
        _put_2d(d23, dst, pos + 1)
        _put_2d(d45, dst, pos + 3)
        _put_2d(d67, dst, pos + 5)
        _put_2d(d89, dst, pos + 7)
        var end = pos + 9
        while end > pos + 1 and dst[unsafe_offset=end - 1] == Byte(ord("0")):
            end -= 1
        pos = end
    return pos


@always_inline
def _format_offset_buf(
    off: Offset, dst: MutPointer[Byte, _], offset: Int
) -> Int:
    if off == Offset.utc:
        dst[unsafe_offset=offset] = Byte(ord("Z"))
        return offset + 1
    dst[unsafe_offset=offset] = Byte(ord("+")) if off.positive else Byte(
        ord("-")
    )
    _put_2d(off.hour, dst, offset + 1)
    dst[unsafe_offset=offset + 3] = Byte(ord(":"))
    _put_2d(off.minute, dst, offset + 4)
    return offset + 6


@always_inline
def _format_datetime_buf(
    dt: DateTime, dst: MutPointer[Byte, _], offset: Int
) -> Int:
    var pos = _format_date_buf(dt.date, dst, offset)
    dst[unsafe_offset=pos] = Byte(ord("T"))
    pos = _format_time_buf(dt.time, dst, pos + 1)
    if not dt.is_local:
        pos = _format_offset_buf(dt.offset, dst, pos)
    return pos


@always_inline
def _u2digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    return Int(ptr[unsafe_offset=offset] - Byte(ord("0"))) * 10 + Int(
        ptr[unsafe_offset=offset + 1] - Byte(ord("0"))
    )


@always_inline
def _u4digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    return (
        Int(ptr[unsafe_offset=offset] - Byte(ord("0"))) * 1000
        + Int(ptr[unsafe_offset=offset + 1] - Byte(ord("0"))) * 100
        + Int(ptr[unsafe_offset=offset + 2] - Byte(ord("0"))) * 10
        + Int(ptr[unsafe_offset=offset + 3] - Byte(ord("0")))
    )


@always_inline
def _parse_2digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    var b0 = ptr[unsafe_offset=offset]
    var b1 = ptr[unsafe_offset=offset + 1]
    if not (Byte(ord("0")) <= b0 <= Byte(ord("9"))) or not (
        Byte(ord("0")) <= b1 <= Byte(ord("9"))
    ):
        return -1
    return Int(b0 - Byte(ord("0"))) * 10 + Int(b1 - Byte(ord("0")))


@always_inline
def _parse_4digits(ptr: Pointer[Byte, _], offset: Int) -> Int:
    var b0 = ptr[unsafe_offset=offset]
    var b1 = ptr[unsafe_offset=offset + 1]
    var b2 = ptr[unsafe_offset=offset + 2]
    var b3 = ptr[unsafe_offset=offset + 3]
    if (
        not (Byte(ord("0")) <= b0 <= Byte(ord("9")))
        or not (Byte(ord("0")) <= b1 <= Byte(ord("9")))
        or not (Byte(ord("0")) <= b2 <= Byte(ord("9")))
        or not (Byte(ord("0")) <= b3 <= Byte(ord("9")))
    ):
        return -1
    return (
        Int(b0 - Byte(ord("0"))) * 1000
        + Int(b1 - Byte(ord("0"))) * 100
        + Int(b2 - Byte(ord("0"))) * 10
        + Int(b3 - Byte(ord("0")))
    )


@always_inline
def validate_date(bytes: Span[Byte, _]) -> Bool:
    """Validate an RFC 3339 local date (`YYYY-MM-DD`)."""
    if len(bytes) != 10:
        return False
    var ptr = bytes.unsafe_ptr()
    if ptr[unsafe_offset=4] != Byte(ord("-")) or ptr[unsafe_offset=7] != Byte(
        ord("-")
    ):
        return False
    var year = _parse_4digits(ptr, 0)
    var month = _parse_2digits(ptr, 5)
    var day = _parse_2digits(ptr, 8)
    if year < 0 or month < 1 or month > 12 or day < 1:
        return False

    var days_in_month = 31
    if month == 4 or month == 6 or month == 9 or month == 11:
        days_in_month = 30
    elif month == 2:
        var leap = (year % 4 == 0) and (year % 100 != 0 or year % 400 == 0)
        days_in_month = 29 if leap else 28
    return day <= days_in_month


@always_inline
def validate_time(bytes: Span[Byte, _]) -> Bool:
    """Validate an RFC 3339 / TOML 1.1 local time (`HH:MM[:SS[.fraction]]`)."""
    var n = len(bytes)
    if n != 5 and n < 8:
        return False
    var ptr = bytes.unsafe_ptr()
    if ptr[unsafe_offset=2] != Byte(ord(":")):
        return False
    var hour = _parse_2digits(ptr, 0)
    var minute = _parse_2digits(ptr, 3)
    if hour < 0 or hour > 23 or minute < 0 or minute > 59:
        return False
    if n == 5:
        return True
    if ptr[unsafe_offset=5] != Byte(ord(":")):
        return False
    var sec_int = _parse_2digits(ptr, 6)
    if sec_int < 0 or sec_int > 60:
        return False
    if n == 8:
        return True
    if ptr[unsafe_offset=8] != Byte(ord(".")) or n == 9:
        return False
    for i in range(9, n):
        var b = ptr[unsafe_offset=i]
        if not (Byte(ord("0")) <= b <= Byte(ord("9"))):
            return False
        if sec_int == 60 and b > Byte(ord("0")):
            return False
    return True


@always_inline
def validate_datetime(bytes: Span[Byte, _]) -> Bool:
    """Validate an RFC 3339 / TOML 1.1 date-time."""
    var n = len(bytes)
    if n < 16:
        return False
    var ptr = bytes.unsafe_ptr()
    var sep = ptr[unsafe_offset=10]
    if (
        sep != Byte(ord("T"))
        and sep != Byte(ord("t"))
        and sep != Byte(ord(" "))
    ):
        return False
    if not validate_date(bytes[:10]):
        return False

    var last = ptr[unsafe_offset=n - 1]
    if last == Byte(ord("Z")) or last == Byte(ord("z")):
        return validate_time(bytes[11 : n - 1])

    var t_split = n
    for i in range(16, n):
        var b = ptr[unsafe_offset=i]
        if b == Byte(ord("+")) or b == Byte(ord("-")):
            t_split = i
            break
        elif b == Byte(ord("Z")) or b == Byte(ord("z")):
            return False

    if t_split == n:
        return validate_time(bytes[11:n])

    if n - t_split != 6 or ptr[unsafe_offset=t_split + 3] != Byte(ord(":")):
        return False
    var off_h = _parse_2digits(ptr, t_split + 1)
    var off_m = _parse_2digits(ptr, t_split + 4)
    if off_h < 0 or off_h > 23 or off_m < 0 or off_m > 59:
        return False
    return validate_time(bytes[11:t_split])


@always_inline
def decode_date_unchecked(bytes: Span[Byte, _]) -> Date:
    """Decode a pre-validated RFC 3339 local date."""
    var ptr = bytes.unsafe_ptr()
    return Date(
        year=_u4digits(ptr, 0),
        month=_u2digits(ptr, 5),
        day=_u2digits(ptr, 8),
    )


@always_inline
def decode_date(bytes: Span[Byte, _]) -> ScalarResult[Date]:
    """Validate and decode an RFC 3339 local date."""
    if not validate_date(bytes):
        return ScalarResult[Date](Date(year=0, month=0, day=0), False)
    return ScalarResult[Date](decode_date_unchecked(bytes), True)


@always_inline
def decode_time_unchecked(bytes: Span[Byte, _]) -> Time:
    """Decode a pre-validated RFC 3339 / TOML 1.1 local time with nanosecond precision.
    """
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var hour = _u2digits(ptr, 0)
    var minute = _u2digits(ptr, 3)
    if n == 5:
        return Time(hour=hour, minute=minute, second=0, nanosecond=0)
    var second = _u2digits(ptr, 6)
    if n == 8:
        return Time(hour=hour, minute=minute, second=second, nanosecond=0)
    var frac_end = min(n, 9 + 9)
    var ns = 0
    var scale = 100_000_000
    for i in range(9, frac_end):
        ns += Int(ptr[unsafe_offset=i] - Byte(ord("0"))) * scale
        scale //= 10
    return Time(hour=hour, minute=minute, second=second, nanosecond=ns)


@always_inline
def decode_time(bytes: Span[Byte, _]) -> ScalarResult[Time]:
    """Validate and decode an RFC 3339 / TOML 1.1 local time."""
    if not validate_time(bytes):
        return ScalarResult[Time](Time(hour=0, minute=0), False)
    return ScalarResult[Time](decode_time_unchecked(bytes), True)


@always_inline
def decode_datetime_unchecked(bytes: Span[Byte, _]) -> DateTime:
    """Decode a pre-validated RFC 3339 / TOML 1.1 date-time."""
    var n = len(bytes)
    var ptr = bytes.unsafe_ptr()
    var date = decode_date_unchecked(bytes[:10])
    var last = ptr[unsafe_offset=n - 1]
    if last == Byte(ord("Z")) or last == Byte(ord("z")):
        return DateTime(
            date, decode_time_unchecked(bytes[11 : n - 1]), Offset.utc, False
        )
    var t_split = n
    for i in range(16, n):
        var b = ptr[unsafe_offset=i]
        if b == Byte(ord("+")) or b == Byte(ord("-")):
            t_split = i
            break
    if t_split == n:
        return DateTime(
            date, decode_time_unchecked(bytes[11:n]), Offset.utc, True
        )
    var off_pos = ptr[unsafe_offset=t_split] == Byte(ord("+"))
    var off_h = _u2digits(ptr, t_split + 1)
    var off_m = _u2digits(ptr, t_split + 4)
    return DateTime(
        date,
        decode_time_unchecked(bytes[11:t_split]),
        Offset(hour=off_h, minute=off_m, positive=off_pos),
        False,
    )


@always_inline
def decode_datetime(bytes: Span[Byte, _]) -> ScalarResult[DateTime]:
    """Validate and decode an RFC 3339 / TOML 1.1 date-time."""
    if not validate_datetime(bytes):
        return ScalarResult[DateTime](
            DateTime(
                Date(year=0, month=0, day=0),
                Time(hour=0, minute=0),
                Offset.utc,
                True,
            ),
            False,
        )
    return ScalarResult[DateTime](decode_datetime_unchecked(bytes), True)


struct Date(Equatable, TrivialRegisterPassable, Writable):
    """Calendar date (`YYYY-MM-DD`)."""

    var year: Int
    var month: Int
    var day: Int

    @always_inline
    def __init__(out self, *, year: Int, month: Int, day: Int):
        self.year = year
        self.month = month
        self.day = day

    @staticmethod
    def from_string(v: StringSpan) raises -> Self:
        var res = decode_date(v.as_bytes())
        if not res._ok:
            raise Error(t"Invalid TOML date: `{v}`")
        return res._val

    def write_to(self, mut w: Some[Writer]):
        var buf = Array[Byte, 16](uninitialized=True)
        var n = _format_date_buf(self, buf.unsafe_ptr(), 0)
        w.write_string(
            StringSpan(
                unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n)
            )
        )


struct Offset(Defaultable, Equatable, TrivialRegisterPassable, Writable):
    """UTC timezone offset (`Z`, `+HH:MM`, or `-HH:MM`)."""

    var positive: Bool
    var hour: Int
    var minute: Int

    comptime utc = Self(hour=0, minute=0, positive=True)

    @always_inline
    def __init__(out self):
        self.positive = True
        self.hour = 0
        self.minute = 0

    @always_inline
    def __init__(out self, *, hour: Int, minute: Int, positive: Bool):
        self.positive = positive
        self.hour = hour
        self.minute = minute

    @staticmethod
    def from_string(v: StringSpan) raises -> Self:
        var bytes = v.as_bytes()
        var n = len(bytes)
        if n == 1:
            var b0 = bytes[0]
            if b0 == Byte(ord("Z")) or b0 == Byte(ord("z")):
                return Offset.utc
            raise Error(t"Invalid TOML offset: `{v}`")
        if n != 6 or bytes[3] != Byte(ord(":")):
            raise Error(t"Invalid TOML offset: `{v}`")
        var b0 = bytes[0]
        var positive: Bool
        if b0 == Byte(ord("+")):
            positive = True
        elif b0 == Byte(ord("-")):
            positive = False
        else:
            raise Error(t"Invalid TOML offset sign: `{v}`")
        var ptr = bytes.unsafe_ptr()
        var hour = _parse_2digits(ptr, 1)
        var minute = _parse_2digits(ptr, 4)
        if hour < 0 or hour > 23 or minute < 0 or minute > 59:
            raise Error(t"TOML offset out of range: `{v}`")
        return Offset(hour=hour, minute=minute, positive=positive)

    def write_to(self, mut w: Some[Writer]):
        var buf = Array[Byte, 8](uninitialized=True)
        var n = _format_offset_buf(self, buf.unsafe_ptr(), 0)
        w.write_string(
            StringSpan(
                unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n)
            )
        )


struct Time(Equatable, TrivialRegisterPassable, Writable):
    """Local wall-clock time (`HH:MM:SS[.nanosecond]`) with exact nanosecond precision.
    """

    var hour: Int
    var minute: Int
    var second: Int
    var nanosecond: Int

    @always_inline
    def __init__(
        out self,
        *,
        hour: Int,
        minute: Int,
        second: Int = 0,
        nanosecond: Int = 0,
    ):
        self.hour = hour
        self.minute = minute
        self.second = second
        self.nanosecond = nanosecond

    @staticmethod
    def from_string(v: StringSpan) raises -> Self:
        var res = decode_time(v.as_bytes())
        if not res._ok:
            raise Error(t"Invalid TOML time: `{v}`")
        return res._val

    def write_to(self, mut w: Some[Writer]):
        var buf = Array[Byte, 24](uninitialized=True)
        var n = _format_time_buf(self, buf.unsafe_ptr(), 0)
        w.write_string(
            StringSpan(
                unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n)
            )
        )


@fieldwise_init
struct DateTime(Equatable, TrivialRegisterPassable, Writable):
    """RFC 3339 / TOML 1.1 offset or local date-time."""

    var date: Date
    var time: Time
    var offset: Offset
    var is_local: Bool

    @staticmethod
    def from_string(v: StringSpan) raises -> Self:
        var res = decode_datetime(v.as_bytes())
        if not res._ok:
            raise Error(t"Invalid TOML datetime: `{v}`")
        return res._val

    def write_to(self, mut w: Some[Writer]):
        var buf = Array[Byte, 40](uninitialized=True)
        var n = _format_datetime_buf(self, buf.unsafe_ptr(), 0)
        w.write_string(
            StringSpan(
                unsafe_from_utf8=Span(unsafe_ptr=buf.unsafe_ptr(), length=n)
            )
        )
