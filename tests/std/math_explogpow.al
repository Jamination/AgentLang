// exp, log and pow in f64 (std/math.al, table-driven): error against double-double references
// over the whole range (bound 0.52 ulp: correct rounding is 0.5), and the edge cases of C as bits
// (0, -0, infinities, NaN, subnormal arguments and results, overflow, negative bases).

struct DD { hi: f64, lo: f64 }

fn two_sum(a: f64, b: f64) -> DD {
    s := a + b
    bb := s - a
    return DD{hi: s, lo: (a - (s - bb)) + (b - bb)}
}

fn split(a: f64) -> (f64, f64) {
    c := 134217729.0 * a
    h := c - (c - a)
    return (h, a - h)
}

fn two_prod(a: f64, b: f64) -> DD {
    p := a * b
    ah, al := split(a)
    bh, bl := split(b)
    return DD{hi: p, lo: ((ah * bh - p) + ah * bl + al * bh) + al * bl}
}

fn dd(a: f64) -> DD {
    return DD{hi: a, lo: 0.0}
}

fn add(x: DD, y: DD) -> DD {
    s := two_sum(x.hi, y.hi)
    t := two_sum(x.lo, y.lo)
    lo := s.lo + t.hi
    u := two_sum(s.hi, lo)
    return two_sum(u.hi, u.lo + t.lo)
}

fn neg(x: DD) -> DD {
    return DD{hi: -x.hi, lo: -x.lo}
}

fn mul(x: DD, y: DD) -> DD {
    p := two_prod(x.hi, y.hi)
    return two_sum(p.hi, p.lo + (x.hi * y.lo + x.lo * y.hi))
}

fn div(x: DD, y: DD) -> DD {
    q1 := x.hi / y.hi
    r := add(x, neg(mul(dd(q1), y)))
    q2 := r.hi / y.hi
    r = add(r, neg(mul(dd(q2), y)))
    q3 := r.hi / y.hi
    return add(two_sum(q1, q2), dd(q3))
}

// ln 2 in double-double
fn ln2() -> DD {
    return DD{hi: 0.6931471805599453, lo: 2.3190468138462996e-17}
}

// e^y for |y| < 1: the Taylor series
fn dd_exp(y: DD) -> DD {
    s := dd(1.0)
    t := dd(1.0)
    for n in 1..40 {
        t = div(mul(t, y), dd(f64(n)))
        s = add(s, t)
    }
    return s
}

// log(v) for v near 1: 2 atanh((v - 1) / (v + 1))
fn dd_log(v: DD) -> DD {
    u := div(add(v, dd(-1.0)), add(v, dd(1.0)))
    u2 := mul(u, u)
    s := dd(0.0)
    p := u
    k := 1
    while k < 120 {
        s = add(s, div(p, dd(f64(k))))
        p = mul(p, u2)
        k += 2
    }
    return add(s, s)
}

// ---------- references in double-double ----------

// e^a for a double-double a (|a| < 746)
fn ref_exp(a: DD) -> DD {
    k := floor(a.hi / 0.6931471805599453 + 0.5)
    r := mul(add(a, neg(mul(ln2(), dd(k)))), dd(0.0625))
    e := dd_exp(r)
    for _ in 0..4 {
        e = mul(e, e)
    }
    // times 2^k, in two steps (no overflow on the way)
    kk := i64(k)
    h := kk / 2
    s1 := cast[f64](u64(h + 1023) << 52)
    s2 := cast[f64](u64(kk - h + 1023) << 52)
    return DD{hi: e.hi * s1 * s2, lo: e.lo * s1 * s2}
}

fn ref_log(x: f64) -> DD {
    k := 0
    m := x
    while m > 1.4142135623730951 {
        m *= 0.5
        k += 1
    }
    while m < 0.7071067811865476 {
        m *= 2.0
        k -= 1
    }
    return add(dd_log(dd(m)), mul(ln2(), dd(f64(k))))
}

// |got - want| in ulp of want (normal results)
fn ulps(got: f64, want: DD) -> f64 {
    e := i64((cast[u64](want.hi) >> 52) & 0x7FF)
    ulp := cast[f64](u64(max(e - 52, 1)) << 52)
    return fabs(((got - want.hi) - want.lo) / ulp)
}

inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn uniform(seed: *u64) -> f64 {
    *seed = lcg(*seed)
    return f64(*seed >> 11) / 9007199254740992.0
}

fn bits(x: f64) -> str { hex(cast[u64](x), 16) }

// (f64 arguments: a bare literal would be f32)
fn fexp(x: f64) -> f64 { exp(x) }
fn flog(x: f64) -> f64 { log(x) }
fn fpow(x: f64, y: f64) -> f64 { pow(x, y) }

fn show(name: str, xs: []f64) {
    put(name)
    for x in xs {
        put(" ", bits(x))
    }
    put("\n")
}

fn main() {
    seed: u64 = 2024
    we: f64 = 0.0
    wl: f64 = 0.0
    wl1: f64 = 0.0
    wp: f64 = 0.0
    wp1: f64 = 0.0
    for t in 0..12000 {
        // exp over its whole range of normal results and near 0
        u := uniform(&seed)
        x := if t % 3 == 0 { (u - 0.5) * 1414.0 } else if t % 3 == 1 { (u - 0.5) * 4.0 } else { (u - 0.5) * 1e-6 }
        we = max(we, ulps(exp(x), ref_exp(dd(x))))
        // log over all binades (subnormals too), near 1 and in [0.5, 2)
        v := uniform(&seed)
        lx := if t % 4 == 0 { cast[f64](1 + (seed >> 1) % 0x7FEFFFFFFFFFFFFF) } else if t % 4 == 1 { 1.0 + (v - 0.5) * 0.02 } else if t % 4 == 2 { 0.5 + v * 1.5 } else { 1.0 + (v - 0.5) * 1e-9 }
        e := ulps(log(lx), ref_log(lx))
        wl = max(wl, e)
        if t % 4 == 1 || t % 4 == 3 {
            wl1 = max(wl1, e)
        }
        // pow with y log x up to +-700, also for x near 1 (large y)
        w := uniform(&seed)
        px := if t % 2 == 0 { 0.001 + v * 1000.0 } else { 1.0 + (v - 0.5) * 0.001 }
        l := ref_log(px)
        py := if t % 4 == 1 { (w - 0.5) * 20.0 } else { (w - 0.5) * 1400.0 / fabs(l.hi) }
        pe := ulps(pow(px, py), ref_exp(mul(l, dd(py))))
        wp = max(wp, pe)
        if t % 2 == 1 {
            wp1 = max(wp1, pe)
        }
    }
    // (correct rounding would be 0.5; the bounds of the C library are about 0.52)
    print("exp within 0.52 ulp:", we < 0.52)
    print("log within 0.52 ulp:", wl < 0.52, "near 1:", wl1 < 0.52)
    print("pow within 0.52 ulp:", wp < 0.52, "x near 1:", wp1 < 0.52)

    // edge cases, as bits

    zero: f64 = 0.0
    nzero := -zero
    nan := zero / zero
    inf := 1.0 / zero
    show("exp", []f64{fexp(zero), fexp(nzero), fexp(1.0), fexp(-1.0), fexp(707.99), fexp(708.0), fexp(709.78), fexp(709.79), fexp(-707.99), fexp(-708.0), fexp(-708.5), fexp(-744.0), fexp(-745.13), fexp(-745.14), fexp(1e-300), fexp(-1e-300), fexp(5e-324), fexp(nan), fexp(inf), fexp(-inf)})
    show("log", []f64{flog(1.0), flog(zero), flog(nzero), flog(-1.0), flog(-inf), flog(inf), flog(nan), flog(5e-324), flog(2.2250738585072014e-308), flog(2.225073858507201e-308), flog(1.7976931348623157e308), flog(2.0), flog(0.5), flog(1.0000000000000002), flog(0.9999999999999999), flog(2.718281828459045)})
    show("pow", []f64{fpow(2.0, 0.5), fpow(2.0, 2.0), fpow(-3.0, 2.0), fpow(-2.0, 3.0), fpow(-2.0, -3.0), fpow(-8.0, 1.0 / 3.0), fpow(-2.0, 0.5), fpow(zero, -1.0), fpow(nzero, -1.0), fpow(nzero, -2.0), fpow(nzero, 0.5), fpow(nzero, 3.0), fpow(-inf, 0.5), fpow(-inf, 3.0), fpow(-inf, -3.0), fpow(inf, -0.5)})
    show("pow", []f64{fpow(1.0, nan), fpow(nan, zero), fpow(nan, 1.0), fpow(1.0, inf), fpow(-1.0, inf), fpow(0.5, inf), fpow(0.5, -inf), fpow(2.0, inf), fpow(2.0, -inf), fpow(1.5, 1e308), fpow(0.5, 1e308), fpow(1.5, -1e308), fpow(-1.5, 1e308), fpow(-0.5, 1e308)})
    show("pow", []f64{fpow(10.0, 308.0), fpow(10.0, 309.0), fpow(10.0, -307.0), fpow(10.0, -323.0), fpow(10.0, -324.0), fpow(5e-324, 0.5), fpow(5e-324, 1.0), fpow(5e-324, -0.5), fpow(2.0, -1074.0), fpow(2.0, -1075.0), fpow(2.0, 1023.0), fpow(2.0, 1024.0), fpow(0.5, 1074.0), fpow(1.0000000001, 1e12), fpow(0.9999999999, -1e12), fpow(1e300, 1.01), fpow(7.0, 0.5), fpow(3.0, -1.0)})
}
