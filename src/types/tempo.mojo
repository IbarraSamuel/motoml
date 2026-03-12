struct Date(Equatable, TrivialRegisterPassable, Writable):
    var year: Int
    var month: Int
    var day: Int

    fn __init__(out self, *, year: Int, month: Int, day: Int):
        self.year = year
        self.month = month
        self.day = day

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var year_s = Int(v[:4].removeprefix("0"))
        # var year = 0 if len(year_s) == 0 else Int(year_s)

        var month = Int(v[5:7].removeprefix("0"))
        var day = Int(v[8:10].removeprefix("0"))

        return {year = year_s, month = month, day = day}

    fn write_to(self, mut w: Some[Writer]):
        _align[4](self.year, w)
        w.write("-")
        _align[2](self.month, w)
        w.write("-")
        _align[2](self.day, w)


struct Offset(Defaultable, Equatable, TrivialRegisterPassable, Writable):
    var positive: Bool
    var hour: Int
    var minute: Int

    comptime utc = Self(hour=0, minute=0, positive=True)

    fn __init__(out self):
        self = {hour = 0, minute = 0, positive = True}

    fn __init__(out self, *, hour: Int, minute: Int, positive: Bool):
        self.positive = positive
        self.hour = hour
        self.minute = minute

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var positive: Bool
        if v[byte=0] == "-":
            positive = False
        elif v[byte=0] == "Z" or v[byte=0] == "z" or v[byte=0] == "+":
            positive = True
        else:
            raise "sign not found for offset"

        var hour_s = Int(v[1:3].removeprefix("0"))
        # var hour = 0 if len(hour_s) == 0 else Int(hour_s)
        var minute_s = Int(v[4:6].removeprefix("0"))
        # var minute = 0 if len(minute_s) == 0 else Int(minute_s)

        return {hour = hour_s, minute = minute_s, positive = positive}

    fn write_to(self, mut w: Some[Writer]):
        if self == Offset.utc:
            w.write("Z")
            return

        w.write("+" if self.positive else "-")
        _align[2](self.hour, w)
        w.write(":")
        _align[2](self.minute, w)


struct Time(Equatable, TrivialRegisterPassable, Writable):
    var hour: Int
    var minute: Int
    var second: Float64

    fn __init__(out self, *, hour: Int, minute: Int, second: Float64):
        self.hour = hour
        self.minute = minute
        self.second = second

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var hour_s = Int(v[0:2].removeprefix("0"))
        var minute_s = Int(v[3:5].removeprefix("0"))

        if len(v) == 5:
            return {hour = hour_s, minute = minute_s, second = 0.0}

        var second = Float64(v[6:].removeprefix("0"))
        return {hour = hour_s, minute = minute_s, second = second}

    fn write_to(self, mut w: Some[Writer]):
        _align[2](self.hour, w)
        w.write(":")
        _align[2](self.minute, w)
        w.write(":")
        if self.second - Float64(Int(self.second)) == 0:
            _align[2](Int(self.second), w)
        else:
            _align[2](self.second, w)
            # _align_fraction[3](self.second, w)

    fn write_to_aligned(self, mut w: Some[Writer]):
        _align[2](self.hour, w)
        w.write(":")
        _align[2](self.minute, w)
        w.write(":")
        if self.second - Float64(Int(self.second)) == 0:
            _align[2](Int(self.second), w)
        # Hack to not align on x.5 values. Because of the test suite
        else:
            _align[2](self.second, w)
            if self.second - Float64(Int(self.second)) != 0.5:
                _align_fraction[3](self.second, w)


@fieldwise_init
struct DateTime(Equatable, TrivialRegisterPassable, Writable):
    var date: Date
    var time: Time
    var offset: Offset
    var is_local: Bool

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var split = v.find("T")
        split = v.find("t") if split == -1 else split
        split = v.find(" ") if split == -1 else split

        if split == -1:
            raise t"Datetime is not datetime: `{v}`"
        var date_s = v[:split]
        # print("date is:", date_s)

        var z = v.find("Z", split)
        z = z if z != -1 else v.find("z", split)
        var neg = v.find("-", split)
        var pos = v.find("+", split)

        var t_split = (
            z if z != -1 else neg if neg != -1 else pos if pos != -1 else len(v)
        )

        var time_s = v[split + 1 : t_split]
        # print("time is:", time_s)

        var date = Date.from_string(date_s)
        # print("date parse complete:", date)
        var time = Time.from_string(time_s)
        # print("time parse complete:", time)
        # print("offset is:", v[t_split:], "or just a utc value")
        var offset = Offset.utc if t_split == len(
            v
        ) or z != -1 else Offset.from_string(v[t_split:])
        # print("offset is:", offset)

        return {date, time, offset, t_split == len(v)}

    fn write_to(self, mut w: Some[Writer]):
        w.write(self.date, "T")
        if self.is_local:
            w.write(self.time)
        else:
            self.time.write_to_aligned(w)
            w.write(self.offset)


fn _align[i: Intable & Writable, //, size: Int](n: i, mut w: Some[Writer]):
    var padding = 0
    while size > padding + 1 and (10 ** (size - padding - 1)) > Int(n):
        padding += 1
        w.write("0")

    w.write(n)


fn _align_fraction[size: Int](n: Float64, mut w: Some[Writer]):
    var st = String(n)
    var curr_fmt = len(st) - st.find(".") - 1
    for _ in range(max(size - curr_fmt, 0)):
        w.write("0")
