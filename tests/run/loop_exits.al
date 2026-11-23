// Stepped loops (`by s`: src/opt/loop.al, loop_stepped_exits drops the half of the exit test
// that the entry test already decides) near the ends of the integer range, inclusive and
// exclusive, signed and unsigned; and counted loops without effects (loop deletion) next to
// ones whose results are used.
noinline fn stepped(a: i64, b: i64) -> (i64, i64, i64) {
    n := 0
    s := 0
    last := 0
    for i in a..b by 1000 {
        n += 1
        s += i
        last = i
    }
    (n, s, last)
}

noinline fn stepped_incl(a: i64, b: i64) -> (i64, i64) {
    n := 0
    last := 0
    for i in a..=b by 7 {
        n += 1
        last = i
    }
    (n, last)
}

noinline fn stepped_u(a: u64, b: u64) -> (i64, u64) {
    n := 0
    last: u64 = 0
    for i in a..b by 100 {
        n += 1
        last = i
    }
    (n, last)
}

noinline fn stepped_i32(a: i32, b: i32) -> (i64, i32) {
    n := 0
    last: i32 = 0
    for i in a..b by 3 {
        n += 1
        last = i
    }
    (n, last)
}

noinline fn stepped_sum(a: []u32, n: i64) -> u64 {
    check: u64 = 0
    for i in 0..n by 1000 {
        check = check * 31 + u64(a[i])
    }
    check
}

// no effect: deleted
noinline fn spin(n: i64) -> i64 {
    k := 0
    for i in 0..n {
        x := i * 3 + 1
        if x == 7 {
            k = 1
        }
    }
    return 5
}

noinline fn spin_nested(n: i64) -> i64 {
    for i in 0..n {
        for j in 0..i {
        }
    }
    return 6
}

// the result is used: kept
noinline fn counted(n: i64) -> i64 {
    k := 0
    for i in 0..n {
        x := i * 3 + 1
        if x % 7 == 3 {
            k += 1
        }
    }
    return k
}

fn main() {
    max := 0x7FFF_FFFF_FFFF_FFFF
    min := -max - 1
    for r in [](i64, i64){(0, 0), (0, 1), (0, 999), (0, 1000), (0, 1001), (0, 5000), (5, 5003), (-3000, 10), (10, -3000), (max - 5000, max), (max - 1000, max), (min, min + 2500), (min + 10, min + 5000), (max - 1, max)} {
        a, b := r
        n, s, last := stepped(a, b)
        print("stepped", a, b, n, s, last)
        n2, last2 := stepped_incl(a, if b > max - 100 { b } else { b + 1 })
        print("incl", n2, last2)
    }
    n3, l3 := stepped_incl(max - 20, max)
    print("incl max", n3, l3)
    for r in [](u64, u64){(0, 0), (0, 1), (0, 100), (0, 101), (0xFFFF_FFFF_FFFF_FF00, 0xFFFF_FFFF_FFFF_FFFF), (5, 1)} {
        a, b := r
        n, last := stepped_u(a, b)
        print("stepped_u", a, b, n, last)
    }
    for r in [](i32, i32){(0, 10), (2147483600, 2147483647), (-2147483648, -2147483640), (3, 3)} {
        a, b := r
        n, last := stepped_i32(a, b)
        print("stepped_i32", a, b, n, last)
    }
    arr := alloc[u32](5000)
    for i in 0..5000 {
        arr[i] = u32(i * 2654435761)
    }
    print("stepped_sum", stepped_sum(arr, 5000), stepped_sum(arr, 1), stepped_sum(arr, 0), stepped_sum(arr, 4001))
    print("spin", spin(1000000), spin(-5), spin_nested(2000))
    print("counted", counted(1000), counted(0))
}
