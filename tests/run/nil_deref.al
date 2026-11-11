N :: struct { v: i64, next: *N }
last :: (n: *N) -> i64 {
    while n.next != nil {
        n = n.next
    }
    n.v
}
main :: () {
    a := &N{1, &N{2, nil}}
    print(last(a))
    p: *N = nil
    print(last(p))
}
