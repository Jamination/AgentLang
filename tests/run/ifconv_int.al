// if-conversion of integer values: selects of constant pairs as arithmetic on the flag
// (c ? 1 : 0, c ? 0 : 1, c ? -1 : 0, c ? 3 : 5, ...), x op y against x (x + (c ? y : 0)),
// multiplies in the arms, three selects, and stores to one address in both arms (one store of
// a selected value). Arms that could trap or read memory must stay branches.
noinline fn one(a: i64, b: i64) -> i64 { if a < b { 1 } else { 0 } }
noinline fn zero(a: i64, b: i64) -> i64 { if a < b { 0 } else { 1 } }
noinline fn mone(a: i64, b: i64) -> i64 { if a < b { -1 } else { 0 } }
noinline fn pair(a: i64, b: i64) -> i64 { if a == b { 3 } else { 5 } }
noinline fn pair8(a: i64, b: i64) -> i64 { if a > b { 12 } else { 4 } }
noinline fn negk(a: i64, b: i64) -> i64 { if a > b { -8 } else { 0 } }
noinline fn small(a: i32, b: i32) -> i32 { if a <= b { 7 } else { 6 } }
noinline fn byte(a: u8, b: u8) -> u8 { if a < b { 1 } else { 0 } }
noinline fn wide(a: i64, b: i64) -> i64 { if a < b { 0x7FFF_FFFF_FFFF_FFFF } else { -0x8000_0000_0000_0000 } }
noinline fn fcmp(x: f64, y: f64) -> i64 { if x < y { 1 } else { 0 } }
noinline fn fcmp_not(x: f64, y: f64, s: i64) -> i64 { if x < y { s } else { s + 1 } }
noinline fn flag(c: bool, s: i64) -> i64 { if c { s + 4 } else { s } }
noinline fn flag_not(c: bool, s: i64) -> i64 { if c { s } else { s - 2 } }

noinline fn count(a: []i64, t: i64) -> i64 {
    n := 0
    for x in a {
        if x > t { n += 1 }
    }
    n
}

noinline fn count_not(a: []i64, t: i64) -> i64 {
    n := 0
    for x in a {
        if x > t {} else { n += 1 }
    }
    n
}

noinline fn acc(a: []i64) -> i64 {
    s := 0
    for i, x in a {
        if x & 1 == 0 { s += x * i }
    }
    s
}

noinline fn bits(a: []i64) -> i64 {
    s := 0
    for x in a {
        if x & 2 != 0 { s ^= x } else { s |= x & 7 }
        if x < 0 { s -= x }
    }
    s
}

noinline fn collatz(n0: i64) -> i64 {
    n := n0
    steps := 0
    while n != 1 {
        n = if n & 1 == 0 { n >> 1 } else { 3 * n + 1 }
        steps += 1
    }
    steps
}

noinline fn three(a: []i64) -> i64 {
    x := 0
    y := 0
    z := 0
    for v in a {
        if v > 2 { x += 1; y += v; z = v } else { y -= 1; z = -v }
        x ^= z & 1
    }
    x * 1000000 + y * 1000 + z
}

// merge of two sorted runs: each arm stores to tmp[k]
noinline fn merge(a: []i64, tmp: []i64, mid: i64) {
    i := 0
    j := mid
    k := 0
    while i < mid && j < len(a) {
        if a[j] < a[i] {
            tmp[k] = a[j]
            j += 1
        } else {
            tmp[k] = a[i]
            i += 1
        }
        k += 1
    }
    while i < mid { tmp[k] = a[i]; i += 1; k += 1 }
    while j < len(a) { tmp[k] = a[j]; j += 1; k += 1 }
}

noinline fn store_same(p: []i64, c: i64) {
    if c > 0 { p[1] = c * 2 } else { p[1] = c - 9 }
}

noinline fn store_f(p: []f64, x: f64) {
    if x < 0.0 { p[0] = -x } else { p[0] = x + 0.5 }
}

// must stay branches: different addresses, a store in one arm only, a division, a load
noinline fn store_two(p: []i64, c: i64) {
    if c > 0 { p[0] = c } else { p[1] = c }
}

noinline fn store_one(p: []i64, c: i64) {
    if c > 0 { p[2] = c }
}

noinline fn div_arm(n: i64, d: i64) -> i64 {
    q := -1
    if d != 0 { q = n / d }
    q
}

noinline fn load_arm(p: []i64, i: i64) -> i64 {
    v := 0
    if i < len(p) { v = p[i] }
    v
}

noinline fn ptr_arm(p: *i64) -> i64 {
    v := 7
    if p != nil { v = *p + 1 }
    v
}

fn main() {
    xs := [5]i64{-3, 0, 1, 2, 100}
    for a in xs {
        for b in xs {
            put(one(a, b), zero(a, b), mone(a, b), pair(a, b), pair8(a, b), negk(a, b), " ")
            put(small(i32(a), i32(b)), byte(u8(a & 255), u8(b & 255)), wide(a, b), " ")
            put(fcmp(f64(a), f64(b)), fcmp_not(f64(a), f64(b), a), flag(a < b, b), flag_not(a < b, b), "\n")
        }
    }
    nan: f64 = 0.0 / 0.0
    print(fcmp(nan, 1.0), fcmp(1.0, nan), fcmp_not(nan, 1.0, 10), fcmp_not(-0.0, 0.0, 10))
    v := alloc[i64](64)
    seed: u64 = 12345
    for i in 0..64 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        v[i] = i64(seed >> 40) % 2001 - 1000
    }
    print(count(v, 0), count(v, -500), count_not(v, 250), acc(v), bits(v), three(v))
    print(collatz(27), collatz(97), collatz(871))
    // two sorted halves
    w := alloc[i64](64)
    for i in 0..32 { w[i] = i * 3 - 40 }
    for i in 0..32 { w[32 + i] = i * 5 - 70 }
    t := alloc[i64](64)
    merge(w, t, 32)
    s := 0
    for i in 0..64 {
        s = s * 31 + t[i]
        if i > 0 && t[i - 1] > t[i] { print("unsorted at", i) }
    }
    print(s)
    p := alloc[i64](4)
    store_same(p, 5)
    put(p[1], " ")
    store_same(p, -5)
    put(p[1], " ")
    store_two(p, 3)
    store_two(p, -4)
    store_one(p, -1)
    store_one(p, 6)
    print(p[0], p[1], p[2], p[3])
    q := alloc[f64](1)
    store_f(q, -0.0)
    put(cast[u64](q[0]), " ")
    store_f(q, -2.0)
    put(q[0], " ")
    store_f(q, 2.0)
    print(q[0])
    print(div_arm(7, 0), div_arm(7, 2), div_arm(-9, 4))
    print(load_arm(p, 2), load_arm(p, 4), load_arm(p, 1000000000))
    x: i64 = 41
    print(ptr_arm(&x), ptr_arm(nil))
}
