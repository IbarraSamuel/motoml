from time import monotonic


@fieldwise_init
struct Date(TrivialRegisterPassable):
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


@fieldwise_init
struct Offset(TrivialRegisterPassable):
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


@fieldwise_init
struct Time(TrivialRegisterPassable):
    var hour: Int
    var minute: Int
    var second: Float64

    var offset: Offset

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var hour = Int(v[:2].strip("0"))
        var minute = Int(v[3:5].strip("0"))
        var second_and_offset = v[6:].strip("0")

        var z = second_and_offset.find("Z")
        var neg = second_and_offset.find("-")
        var pos = second_and_offset.find("+")

        var split = (
            z if z != -1 else neg if neg != -1 else pos if pos != -1 else len(v)
        )

        var second = atof(second_and_offset[:z])
        var offset = Offset.utc if split == len(v) else Offset.from_string(
            second_and_offset[z:]
        )

        return {hour, minute, second, offset}


@fieldwise_init
struct DateTime[Offset: UInt](TrivialRegisterPassable):
    var date: Date
    var time: Time

    @always_inline
    @staticmethod
    fn from_string(v: StringSlice) raises -> Self:
        var split = v.find("T")
        var date_s = v[:split]
        var time_s = v[split + 1 :]

        var date = Date.from_string(date_s)
        var time = Time.from_string(time_s)

        return {date, time}
