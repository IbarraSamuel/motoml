struct S(Defaultable, Movable):
    pass


__enum E:
    case I(S)


def main():
    var e = E.I(S())

    match e^:
        case .I(var s):
            var _ = s^
