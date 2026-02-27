from time import monotonic


@fieldwise_init
struct Date(TrivialRegisterPassable, Writable):
    var year: Int
    var month: Int
    var day: Int

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var year = Int(v[:4].strip("0"))
        var month = Int(v[5:7].strip("0"))
        var day = Int(v[8:10].strip("0"))

        return {year, month, day}

    fn write_to(self, mut w: Some[Writer]):
        _align[4](self.year, w)
        w.write("-")
        _align[2](self.month, w)
        w.write("-")
        _align[2](self.day, w)


@fieldwise_init
struct Offset(Equatable, TrivialRegisterPassable, Writable):
    var hour: Int
    var minute: Int
    var positive: Bool

    comptime utc = Self(0, 0, True)

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var positive: Bool
        if v[byte=0] == "-":
            positive = False
        elif v[byte=0] == "Z" or v[byte=0] == "+":
            positive = True
        else:
            raise "sign not found for offset"

        var hour = Int(v[1:3].strip("0"))
        var minute = Int(v[4:6].strip("0"))

        return {hour, minute, positive}

    fn write_to(self, mut w: Some[Writer]):
        if self == Offset.utc:
            w.write("Z")
            return

        w.write("+" if self.positive else "-")
        _align[2](self.hour, w)
        w.write("-")
        _align[2](self.minute, w)


@fieldwise_init
struct Time(Equatable, TrivialRegisterPassable, Writable):
    var hour: Int
    var minute: Int
    var second: Float64

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var hour = Int(v[:2].strip("0"))
        var minute = Int(v[3:5].strip("0"))

        if len(v) == 5:
            return {hour, minute, 0.0}

        var second_s = v[6:] if v[byte=6] != StringSlice("0") else v[7:]
        var second = Float64(second_s)

        return {hour, minute, second}

    fn write_to(self, mut w: Some[Writer]):
        _align[2](self.hour, w)
        w.write("-")
        _align[2](self.minute, w)
        w.write("-")
        _align[2](self.second, w)


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
        split = v.find(" ") if split == -1 else split

        if split == -1:
            raise "Datetime is not datetime: `{}`".format(v)
        var date_s = v[:split]
        # print("date is:", date_s)

        var z = v.find("Z", split)
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
        w.write(self.date, "T", self.time)
        if not self.is_local:
            w.write(self.offset)


fn _align[i: Intable & Writable, //, size: Int](n: i, mut w: Some[Writer]):
    var padding = 0
    while size > padding + 1 and (10 ** (size - padding - 1)) > Int(n):
        padding += 1
        w.write("0")

    w.write(n)
