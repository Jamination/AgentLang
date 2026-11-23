// Generates the tables of exp, log and pow in std/math.al (__EXP_T, __LOG_T): build and run
// `alc run tests/gen/math_tables.al` and paste its output over the tables there.
// Values are computed in double-double arithmetic (about 104 bits).

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

fn main() {
    // exp: 2^(j/128) = H * (1 + T); entry 2j: the bits of T, 2j + 1: the bits of H - (j << 45)
    put("__EXP_T := [256]u64{")
    for j in 0..128 {
        e := dd_exp(mul(ln2(), dd(f64(j) / 128.0)))
        h := e.hi
        t := e.lo / h
        if j % 2 == 0 {
            put("\n   ")
        }
        put(" 0x", hex(cast[u64](t), 16), ", 0x", hex(cast[u64](h) - (u64(j) << 45), 16), ",")
    }
    put("}\n")
    // log: subinterval i of [0.7056, 1.4112) holds the z whose bits lie in [OFF + i 2^45,
    // OFF + (i + 1) 2^45) (1 lies well inside subinterval 75); invc = j/128 nearest to 1/(its
    // centre) (1 near 1), -log(invc) as hi (a multiple of 2^-43) + lo
    put("__LOG_T := [384]f64{")
    off: u64 = 0x3FE6955500000000
    worst: f64 = 0.0
    for i in 0..128 {
        a := cast[f64](off + (u64(i) << 45))
        b := cast[f64](off + (u64(i + 1) << 45))
        j := i64(256.0 / (a + b) + 0.5)
        invc := f64(j) / 128.0
        // |r| = |z invc - 1| on the subinterval; |log(invc)| must exceed it (one addition then
        // rounds exactly as a Fast2Sum, see __log_t)
        rmax := max(fabs(a * invc - 1.0), fabs(b * invc - 1.0))
        worst = max(worst, rmax)
        l := neg(dd_log(dd(invc)))
        if invc != 1.0 && !(fabs(l.hi) > rmax) {
            print("\nsubinterval", i, ": |log(invc)| below |r|")
        }
        if a < 1.0 && rmax >= 0.0078125 || rmax >= 0.015625 {
            print("\nsubinterval", i, ": r not exactly representable")
        }
        // no cancellation of -log(invc) and r: where invc != 1, |log z| is not much below |r|
        if invc != 1.0 && (a <= 1.0 && b >= 1.0 || min(fabs(log(a)), fabs(log(b))) < 0.004) {
            print("\nsubinterval", i, ": log z near 0 with invc != 1")
        }
        hi := f64(i64(l.hi * 8796093022208.0 + (if l.hi < 0.0 { -0.5 } else { 0.5 }))) / 8796093022208.0
        lo := (l.hi - hi) + l.lo
        if i % 2 == 0 {
            put("\n   ")
        }
        put(" ", invc, ", ", hi, ", ", lo, ",")
    }
    put("}\n// largest |r|: ", worst, "\n")
}
