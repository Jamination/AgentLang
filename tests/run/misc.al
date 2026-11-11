N :: 5
SCALE : f64 : 2.5
NAME :: "al"
MASK : u32 : 0xFF00
counter: i64
table: [N]i64
primes := [5]i64{2, 3, 5, 7, 11}
ratio := 0.5
greeting := "hi"

bump :: () -> i64 {
    counter += 1; counter
}
apply :: (f: (i64) -> i64, x: i64) -> i64 { f(x) }
dbl :: (x: i64) -> i64 { x * 2 }
cleanup_demo :: () -> i64 {
    defer { print("deferred 1") }
    defer { print("deferred 2") }
    print("body")
    return 7
}
main :: () {
    print(N, SCALE, NAME, MASK, N * 2, SCALE * 2.0)
    bump(); bump()
    print(counter, bump())
    for i in 0..N {
        table[i] = primes[i] * N
    }
    print(table, primes[4], ratio, greeting)
    print(apply(dbl, 21))
    fs: [2](i64) -> i64
    fs[0] = dbl
    fs[1] = bump_by
    print(fs[0](5), fs[1](5))
    print(cleanup_demo())
    s := "abc"
    print(s == "abc", s != "abd", s == "ab", len(s))
    x: u8 = 'A'
    putc(x + 1); putc('\n')
    print('a', "tab\there", "q\"q")
    {
        defer { print("scope exit") }
        print("in scope")
    }
    for i in 0..2 {
        defer { print("iter end", i) }
        if i == 0 {
            continue
        }
        print("iter", i)
    }
    print(1 + 2.5, 7 / 2.0, 1 < 2.5)
    print(f64(u64(18446744073709551615)), f64(u64(9223372036854775808)), f64(u64(12)))
}
bump_by :: (x: i64) -> i64 { x + 100 }
