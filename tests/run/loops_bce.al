// loops whose bounds checks are hoisted or folded must still compute the right thing
fn sum_fwd(a []i64) i64 {
    s := 0
    for i in 0..len(a) {
        s += a[i]
    }
    s
}
fn sum_rev(a []i64) i64 {
    s := 0
    for i in len(a) - 1..=0 by -1 {
        s = s * 3 + a[i]
    }
    s
}
fn sum_off(a []i64, k i64) i64 {
    s := 0
    for i in 0..len(a) - k {
        s += a[i + k] - a[i]
    }
    s
}
fn mirror(a []i64) {
    n := len(a)
    for i in 0..n / 2 {
        t := a[i]
        a[i] = a[n - 1 - i]
        a[n - 1 - i] = t
    }
}
fn sum2d(m []i64, rows i64, cols i64) i64 {
    s := 0
    for r in 0..rows {
        for c in 0..cols {
            s += m[r * cols + c] * (r + 1)
        }
    }
    s
}
fn stride(a []i64) i64 {
    s := 0
    for i in 0..16 by 4 {
        s += a[i] + a[i + 1] * 2 + a[i + 2] * 3 + a[i + 3] * 4
    }
    s
}
fn sum32(a []i64, n i32) i64 {
    s := 0
    for i in 0..n {
        s += a[i] + a[n - 1 - i]
    }
    s
}
fn fib_shift() i64 {
    a := 0
    b := 1
    c := 1
    for i in 0..30 {
        t := a + b + c
        a = b
        b = c
        c = t
    }
    a + b + c
}
fn main() {
    a := alloc[i64](16)
    for i in 0..16 {
        a[i] = i * i + 1
    }
    print(sum_fwd(a), sum_rev(a[0..5]), sum_off(a, 3), stride(a), sum32(a, 16))
    mirror(a)
    print(a[0], a[15], a[7], a[8])
    print(sum2d(a, 4, 4), sum2d(a[0..6], 2, 3), sum_fwd(a[3..3]), sum_rev(a[2..3]))
    print(fib_shift())
    var w [8]u32
    for i in 0..8 {
        w[i] = u32(i) * 0x01010101
    }
    var acc u32 = 0
    for i in 2..8 {
        acc = acc ^ ((w[i - 2] >> 3) | (w[i - 1] << 29)) + w[i]
    }
    print(acc)
}
