// at most 64 regions can be entered at the same time
main :: () {
    rs := alloc[Region](65)
    for i in 0..65 {
        if i == 64 {
            print("entered", i)
        }
        enter(&rs[i])
    }
    print("not reached")
}
