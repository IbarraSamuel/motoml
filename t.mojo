from itertools import take_while, drop_while


fn main():
    var range_iterator = range(0, 9)

    var skip_before_4 = drop_while[cmp[4, neg=True]](range_iterator)
    var get_up_to_6 = take_while[cmp[6, neg=True]](skip_before_4)

    for i in get_up_to_6:
        print(i)

    # for i in range_iterator:
    #     print("at iter:", i)
    #     var inner_iter = range_iterator
    #     find_no[2](inner_iter)
    #     find_no[4](inner_iter)


fn cmp[no: Int, *, neg: Bool = False](val: Int) -> Bool:
    @parameter
    if neg:
        return val != no
    return val == no


fn find_no[m: MutOrigin, //, no: Int](ref[m] v: Some[Iterable]):
    var steps = 0
    for var elem in v:
        steps += 1
        var ell = trait_downcast_var[Movable & ImplicitlyDestructible](elem^)
        if rebind[Int](ell) == no:
            print("to find", no, "-- steps needed:", steps)
            return
