// Scalar promotion in LICM (src/opt/licm.al, licm_promote): a location a loop loads and stores
// through one invariant address lives in a register during the loop and is stored back on
// every way out. The values seen after the loop, by calls after it and through other
// pointers, must be those of the plain loop; locations that another access in the loop may
// alias, and loops with calls, stay as they are.
g_count: i64
g_small: u8
g_arr: [8]i32

struct Acc {
    n: i64
    total: u64
    hist: [4]u32
}

noinline fn read_count() -> i64 {
    return g_count
}

noinline fn count_up(n: i64) {
    for i in 0..n {
        g_count += i
    }
}

noinline fn count_if(a: []i64, t: i64) {
    for x in a {
        if x > t {
            g_count += 1
        }
    }
}

noinline fn wrap_u8(n: i64) {
    for i in 0..n {
        g_small += u8(i | 1)
    }
}

noinline fn field(acc: *Acc, a: []u64) {
    for x in a {
        acc.total += x
        acc.n += 1
    }
}

noinline fn bucket(acc: *Acc, a: []u64, k: i64) {
    for x in a {
        acc.hist[k] += u32(x & 7)
    }
}

noinline fn global_slot(k: i64, n: i64) {
    for i in 0..n {
        g_arr[k] = g_arr[k] * 3 + i32(i)
    }
}

// two pointers that may be the same: no promotion
noinline fn two_ptrs(p: *i64, q: *i64, n: i64) {
    for i in 0..n {
        *p += i
        *q += 1
    }
}

// a read through another pointer in the loop
noinline fn read_other(p: *i64, q: *i64, n: i64) -> i64 {
    s := 0
    for i in 0..n {
        *p += 2
        s += *q
    }
    s
}

// leaves early: the value must be stored back on that way out too
noinline fn until(a: []i64, stop: i64) -> i64 {
    for i in 0..len(a) {
        g_count += a[i]
        if g_count > stop {
            return i
        }
    }
    return -1
}

// a call in the loop sees the location
noinline fn with_call(n: i64) -> i64 {
    s := 0
    for i in 0..n {
        g_count += 1
        s += read_count()
    }
    s
}

// nested: the inner loop's location is read by the outer loop
noinline fn nested(n: i64) -> i64 {
    s := 0
    for i in 0..n {
        for j in 0..i {
            g_count += j
        }
        s += g_count
    }
    s
}

// stores only on some iterations: the location is not written when the loop writes nothing
noinline fn maybe_store(a: []i64) {
    for x in a {
        if x == 12345 {
            g_count = x
        }
    }
}

fn main() {
    for n in []i64{0, 1, 2, 3, 4, 5, 7, 8, 9, 100} {
        g_count = 10
        count_up(n)
        print("count_up", n, g_count, read_count())
    }
    a := alloc[i64](50)
    for i in 0..50 {
        a[i] = (i * 37) % 50
    }
    g_count = 0
    count_if(a, 25)
    count_if(a[..0], 25)
    count_if(a[..7], 0)
    print("count_if", g_count)
    g_small = 250
    wrap_u8(9)
    print("wrap_u8", g_small)
    acc := Acc{}
    u := alloc[u64](20)
    for i in 0..20 {
        u[i] = u64(i * i)
    }
    field(&acc, u)
    field(&acc, u[..3])
    bucket(&acc, u, 2)
    bucket(&acc, u[5..], 3)
    print("field", acc.n, acc.total, acc.hist[0], acc.hist[2], acc.hist[3])
    global_slot(5, 10)
    global_slot(1, 0)
    print("global_slot", g_arr[5], g_arr[1], g_arr[4])
    x := 1
    y := 100
    two_ptrs(&x, &y, 10)
    print("two_ptrs", x, y)
    two_ptrs(&x, &x, 10)
    print("two_ptrs same", x)
    print("read_other", read_other(&x, &y, 5), x, y, read_other(&x, &x, 5), x)
    g_count = 0
    print("until", until(a, 100), g_count, until(a[..3], 1000000), g_count)
    g_count = 0
    print("with_call", with_call(6), g_count)
    g_count = 0
    print("nested", nested(7), g_count)
    g_count = 77
    maybe_store(a)
    print("maybe_store", g_count)
    a[3] = 12345
    maybe_store(a)
    print("maybe_store", g_count)
}
