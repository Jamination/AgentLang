// Values live across calls in the registers a call preserves (Windows: rbx, rbp, rsi, rdi,
// r12-r15 and xmm6-xmm15; Linux: no xmm register). Each callee writes many registers of both
// kinds itself (a long chain of floats, bulk copies with rep movsb, which uses rsi and rdi), so
// a register it did not save and restore changes the caller's values.

struct Big { a: [40]i64 }

// uses every xmm register it can: 16 sums live at once
noinline fn churn_f(x: f64) -> f64 {
    s0 := x
    s1 := x + 1.0
    s2 := x + 2.0
    s3 := x + 3.0
    s4 := x + 4.0
    s5 := x + 5.0
    s6 := x + 6.0
    s7 := x + 7.0
    s8 := x + 8.0
    s9 := x + 9.0
    s10 := x + 10.0
    s11 := x + 11.0
    s12 := x + 12.0
    s13 := x + 13.0
    s14 := x + 14.0
    s15 := x + 15.0
    for i in 0..3 {
        s0 = s0 * 0.5 + s15
        s1 = s1 * 0.5 + s0
        s2 = s2 * 0.5 + s1
        s3 = s3 * 0.5 + s2
        s4 = s4 * 0.5 + s3
        s5 = s5 * 0.5 + s4
        s6 = s6 * 0.5 + s5
        s7 = s7 * 0.5 + s6
        s8 = s8 * 0.5 + s7
        s9 = s9 * 0.5 + s8
        s10 = s10 * 0.5 + s9
        s11 = s11 * 0.5 + s10
        s12 = s12 * 0.5 + s11
        s13 = s13 * 0.5 + s12
        s14 = s14 * 0.5 + s13
        s15 = s15 * 0.5 + s14
    }
    return s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7 + s8 + s9 + s10 + s11 + s12 + s13 + s14 + s15
}

// many integers at once, and a bulk copy (rsi, rdi, rcx)
noinline fn churn_i(b: *Big, k: i64) -> i64 {
    c := *b
    t0 := k * 3
    t1 := k * 5 + 1
    t2 := k * 7 + 2
    t3 := k * 11 + 3
    t4 := k * 13 + 4
    t5 := k * 17 + 5
    t6 := k * 19 + 6
    t7 := k * 23 + 7
    t8 := k * 29 + 8
    t9 := k * 31 + 9
    t10 := k * 37 + 10
    t11 := k * 41 + 11
    t12 := k * 43 + 12
    t13 := k * 47 + 13
    for i in 0..c.a.len {
        c.a[i] += t0 ^ t1 ^ t2 ^ t3 ^ t4 ^ t5 ^ t6 ^ t7 ^ t8 ^ t9 ^ t10 ^ t11 ^ t12 ^ t13 ^ i
        t0, t1, t2, t3, t4, t5, t6 = (t1 + t13, t2, t3, t4, t5, t6, t7)
        t7, t8, t9, t10, t11, t12, t13 = (t8, t9, t10, t11, t12, t13, t0)
    }
    *b = c
    return c.a[k % 40]
}

noinline fn mix(x: f64, y: i64) -> f64 {
    return x * 1.25 + f64(y % 7)
}

// floats and integers that live across calls of all kinds
noinline fn across(n: i64, f: fn(f64, i64) -> f64) -> f64 {
    b: Big
    for i in 0..40 {
        b.a[i] = i * i
    }
    a0: f64 = 0.5
    a1: f64 = 1.5
    a2: f64 = 2.5
    a3: f64 = 3.5
    a4: f64 = 4.5
    a5: f64 = 5.5
    a6: f64 = 6.5
    a7: f64 = 7.5
    a8: f64 = 8.5
    a9: f64 = 9.5
    i0 := 1
    i1 := 2
    i2 := 3
    i3 := 4
    i4 := 5
    i5 := 6
    i6 := 7
    i7 := 8
    for k in 0..n {
        x := churn_f(f64(k))
        a0 += x * 0.001
        a1 = a1 * 0.999 + a0
        a2 = a2 * 0.998 + a1
        a3 = a3 * 0.997 + a2
        a4 = a4 * 0.996 + a3
        y := churn_i(&b, k + i0)
        i0 = i0 + (y & 7)
        i1 = i1 ^ (y >> 3)
        i2 += i1 & 255
        i3 = i3 * 3 % 1000003
        z := f(a4, i2)
        a5 = a5 * 0.995 + z * 0.0001
        a6 = a6 * 0.994 + a5
        a7 = a7 * 0.993 + a6
        a8 = a8 * 0.992 + a7
        a9 = a9 * 0.991 + a8
        i4 += i3 & 15
        i5 ^= i4
        i6 += i5 % 13
        i7 = i7 * 7 % 1009
    }
    print(i0, i1, i2, i3, i4, i5, i6, i7)
    return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9
}

// recursion: each level keeps floats across the call of the next
noinline fn rec(d: i64, x: f64) -> f64 {
    if d == 0 {
        return churn_f(x)
    }
    u := x * 1.5
    v := x + 0.25
    w := x * x * 0.001
    r := rec(d - 1, v)
    return u + v + w + r * 0.5
}

fn main() {
    r := across(200, mix)
    print(i64(r * 1000.0))
    print(i64(rec(12, 0.75) * 1000.0))
}
