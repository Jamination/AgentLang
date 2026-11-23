// Loops whose back edge the x86 back end leaves without a copy: a reduction written over its
// phi's register (s = s + x, x + s, s += [mem], floats too), and the step of an induction
// variable moved after the loop's compare (inclusive and descending ranges, src/x86/mod.al
// sink_steps). Also the cases that must keep their shape: the old value used after the step,
// the new value used inside the block, the phi used twice, a step whose flags are read.

noinline fn sum_load(a: []i64) -> i64 {
    s := 0
    for i in 0..len(a) {
        s += a[i]
    }
    return s
}

noinline fn sum_rev(a: []i64) -> i64 {
    s := 0
    for i in 0..len(a) {
        s = a[i] * 3 + s
    }
    return s
}

noinline fn sum_bytes(b: []u8) -> u64 {
    s: u64 = 0
    for i in 0..len(b) {
        s += u64(b[i])
    }
    return s
}

noinline fn sum_i32(a: []i32) -> i32 {
    s: i32 = 7
    for x in a {
        s = (x ^ 5) + s
    }
    return s
}

noinline fn dot(a: []f64, b: []f64) -> f64 {
    s: f64 = 0.0
    for i in 0..len(a) {
        s = a[i] * b[i] + s
    }
    return s
}

// the phi is used twice: no rewrite
noinline fn twice(a: []i64) -> i64 {
    s := 1
    t := 0
    for i in 0..len(a) {
        t += s & 255
        s = s + a[i]
    }
    return s * 1000 + t
}

noinline fn incl(a: []i64, m: i64) -> i64 {
    s := 0
    for j in 1..=m {
        s += a[j] ^ j
    }
    return s
}

noinline fn knap(best: []i64, wk: i64, vk: i64, cap: i64) {
    for w in cap..=wk by -1 {
        cand := best[w - wk] + vk
        if cand > best[w] {
            best[w] = cand
        }
    }
}

// the step and the old value both live past the compare
noinline fn both(a: []i64, m: i64) -> i64 {
    s := 0
    j := 0
    last := 0
    while j <= m {
        last = j
        j += 2
        s += a[last] - j
    }
    return s * 100 + last + j
}

// down to i64 min and up to i64 max: the compare decides on the old value
noinline fn edges() -> i64 {
    n := 0
    for i in -9223372036854775805..=-9223372036854775807 by -1 {
        n += i & 3
    }
    for i in 9223372036854775804..=9223372036854775807 {
        n += i & 7
    }
    return n
}

// a step whose overflow is checked (the flags of the add are read)
noinline fn checked_steps(k: i32) -> i32 {
    c: i32 = 0
    x: i32 = k
    while x < 2147483600 {
        x = x + 7
        c += 1
    }
    return c
}

fn main() {
    n := 1000
    a := alloc[i64](n + 1)
    b := alloc[u8](n)
    c := alloc[i32](n)
    f := alloc[f64](n)
    g := alloc[f64](n)
    for i in 0..n {
        a[i] = i * 37 % 101 - 50
        b[i] = u8(i * 13)
        c[i] = i32(i * 7 - 3000)
        f[i] = f64(i) * 0.5
        g[i] = 1.0 / f64(i + 1)
    }
    a[n] = 9
    print(sum_load(a), sum_rev(a), sum_bytes(b), sum_i32(c), i64(dot(f, g) * 1000.0))
    print(twice(a), incl(a, n), incl(a, 0), incl(a, 1))
    best := alloc[i64](201)
    for k in 1..40 {
        knap(best, k % 13 + 1, k * 7 % 23, 200)
    }
    print(best[200], best[100], best[13])
    knap(best, 200, 5, 200)
    knap(best, 201, 5, 200)
    print(best[0], best[200], both(a, 20), both(a, 0), edges(), checked_steps(2147483000))
}
