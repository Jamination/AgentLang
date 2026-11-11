// a hoisted bounds check still stops the program
fill :: (a: []i64, n: i64) {
    for i in 0..n {
        a[i] = i
    }
}
main :: () {
    a := alloc[i64](10)
    fill(a, 10)
    print(a[9])
    fill(a, 11)
    print("unreachable")
}
