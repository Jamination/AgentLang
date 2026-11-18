// log10, ldexp and frexp in f64 and f32: known values, the edge cases of C (0, negative,
// infinity, NaN, subnormals), exact powers of ten, and log10 against a reference: the f64
// result through log2 in double-double, the f32 result through the f64 one (within 1 ulp,
// counting the exactly rounded results).

fn bits(x: f64) -> str { hex(cast[u64](x), 16) }
fn bits(x: f32) -> str { hex(u64(cast[u32](x)), 8) }

fn same(a: f64, b: f64) -> bool { cast[u64](a) == cast[u64](b) || a != a && b != b }
fn same(a: f32, b: f32) -> bool { cast[u32](a) == cast[u32](b) || a != a && b != b }

failures := 0

fn check(name: str, ok: bool) {
    if !ok {
        print("FAIL", name)
        failures += 1
    }
}

// the distance in ulps between two finite f64 of the same sign
fn ulps(a: f64, b: f64) -> i64 { abs(cast[i64](a) - cast[i64](b)) }
fn ulps(a: f32, b: f32) -> i64 { abs(i64(cast[i32](a)) - i64(cast[i32](b))) }

// a * b as p + err exactly (Dekker)
fn two_prod(a: f64, b: f64) -> (f64, f64) {
    p := a * b
    ah, al := split(a)
    bh, bl := split(b)
    (p, ((ah * bh - p) + ah * bl + al * bh) + al * bl)
}

fn split(a: f64) -> (f64, f64) {
    c := 134217729.0 * a
    h := c - (c - a)
    (h, a - h)
}

fn main() -> i64 {
    min_sub64 := cast[f64](u64(1))
    min_sub32 := cast[f32](u32(1))

    // ---- log10: edge cases
    check("log10 0", log10(f64(0.0)) == -INF && log10(-f64(0.0)) == -INF && log10(f32(0.0)) == -INF && log10(-f32(0.0)) == -INF)
    nan64 := log10(f64(-1.0))
    nan32 := log10(f32(-1.0))
    check("log10 negative", nan64 != nan64 && nan32 != nan32 && log10(-f64(INF)) != log10(-f64(INF)))
    check("log10 inf", log10(f64(INF)) == INF && log10(f32(INF)) == INF)
    check("log10 nan", log10(f64(NAN)) != log10(f64(NAN)) && log10(f32(NAN)) != log10(f32(NAN)))
    check("log10 1", same(log10(f64(1.0)), 0.0) && same(log10(f32(1.0)), 0.0))
    check("log10 subnormal", log10(min_sub64) == -323.3062153431158 && ulps(log10(min_sub32), f32(log10(f64(min_sub32)))) <= 1)
    check("log10 largest", log10(f64(1.7976931348623157e308)) == 308.25471555991675 && log10(f32(3.4028235e38)) == 38.53184)
    // exact powers of ten
    p: f64 = 1.0
    for k in 0..23 {
        check(fmt("log10 1e", k), log10(p) == f64(k) && log10(1.0 / p) == -f64(k) || k > 22)
        p *= 10.0
    }
    q: f32 = 1.0
    for k in 0..11 {
        check(fmt("log10f 1e", k), log10(q) == f32(k))
        q *= 10.0
    }
    print("log10:", log10(f64(2.0)), log10(f64(0.5)), log10(f64(1234.5678)), log10(f32(2.0)), log10(f32(0.001)), log10(f32(7.0)))

    // ---- log10 against references, over a spread of inputs
    worst64 := 0
    exact64 := 0
    n64 := 0
    worst32 := 0
    exact32 := 0
    n := 0
    x: f64 = 1e-300
    while x < 1e300 {
        // the reference: log2(x) / log2(10) in double-double (__log_dd gives ln x to ~70 bits)
        hi, lo := __log_dd(x)
        p, err := two_prod(hi, 0.4342944819032518)
        r := p + (err + lo * 0.4342944819032518 + hi * 1.098319650216765e-17)
        worst64 = max(worst64, ulps(log10(x), r))
        if log10(x) == r { exact64 += 1 }
        n64 += 1
        x *= 1.7171717
    }
    y: f32 = 1e-38
    while y < 3e38 {
        want := f32(log10(f64(y)))
        got := log10(y)
        d := ulps(got, want)
        worst32 = max(worst32, d)
        if d == 0 {
            exact32 += 1
        }
        n += 1
        y *= 1.0137
    }
    print("log10 f64:", n64, "inputs,", exact64, "as the reference, at most", worst64, "ulp off; f32:", n, "inputs,", exact32, "as the reference, at most", worst32, "ulp off")
    check("log10 f64 within 1 ulp", worst64 <= 1)
    check("log10 f32 within 1 ulp", worst32 <= 1)
    check("log10 f32 mostly exact", exact32 * 100 >= n * 99)

    // ---- ldexp
    check("ldexp basics", ldexp(f64(1.0), 10) == 1024.0 && ldexp(f64(3.0), -1) == 1.5 && ldexp(f32(1.0), 10) == 1024.0 && ldexp(f32(-3.0), -1) == -1.5)
    check("ldexp zero inf nan", same(ldexp(-f64(0.0), 5), -f64(0.0)) && ldexp(f64(INF), -5000) == INF && ldexp(f64(NAN), 3) != ldexp(f64(NAN), 3)
        && same(ldexp(-f32(0.0), 5), -f32(0.0)) && ldexp(-f32(INF), -500) == -INF)
    check("ldexp overflow", ldexp(f64(1.0), 1024) == INF && ldexp(f64(-1.0), 5000) == -INF && ldexp(f32(1.0), 128) == INF
        && ldexp(f64(0.5), 1024) == 8.98846567431158e307 && ldexp(f32(0.5), 128) == 1.7014118346046923e38)
    check("ldexp to subnormal", ldexp(f64(1.0), -1074) == min_sub64 && ldexp(f64(1.0), -1075) == 0.0 && ldexp(f64(1.5), -1075) == min_sub64
        && ldexp(f32(1.0), -149) == min_sub32 && ldexp(f32(1.0), -150) == 0.0 && ldexp(f32(1.5), -150) == min_sub32)
    // rounded once: 1 + 2^-52 scaled into the subnormals would round twice through 2^-1022
    check("ldexp rounds once", ldexp(f64(1.0000000000000002), -1074) == min_sub64 && ldexp(f64(1.5000000000000002), -1074) == ldexp(f64(2.0), -1074)
        && ldexp(f32(1.0000001), -149) == min_sub32 && ldexp(f32(1.5000001), -149) == ldexp(f32(2.0), -149))
    check("ldexp from subnormal", ldexp(min_sub64, 1074) == 1.0 && ldexp(min_sub64, 2000) == ldexp(f64(1.0), 926) && ldexp(min_sub32, 149) == 1.0)
    check("ldexp far", ldexp(f64(1e300), -3000) == 0.0 && ldexp(f64(1e-300), 3000) == INF && ldexp(f64(1e300), -2000) == 8.709809816217217e-303 && ldexp(f64(1.0), -0x7FFF_FFFF_FFFF) == 0.0 && ldexp(f32(1.0), 0x7FFF_FFFF_FFFF) == INF)
    print("ldexp:", ldexp(f64(1.0), -1074), ldexp(f64(1.0), 1023), ldexp(f32(1.0), -149), ldexp(f32(1.0), 127), ldexp(f64(7.0), 3), ldexp(f32(7.0), -3))

    // ---- frexp
    m, e := frexp(f64(8.0))
    check("frexp 8", m == 0.5 && e == 4)
    m, e = frexp(f64(-0.75))
    check("frexp -0.75", m == -0.75 && e == 0)
    m, e = frexp(min_sub64)
    check("frexp subnormal", m == 0.5 && e == -1073)
    m, e = frexp(f64(1.7976931348623157e308))
    check("frexp largest", m == 0.9999999999999999 && e == 1024)
    m, e = frexp(-f64(0.0))
    check("frexp zero", same(m, -f64(0.0)) && e == 0)
    m, e = frexp(f64(INF))
    check("frexp inf", m == INF && e == 0)
    m, e = frexp(f64(NAN))
    check("frexp nan", m != m && e == 0)
    m32, e32 := frexp(f32(8.0))
    check("frexpf 8", m32 == 0.5 && e32 == 4)
    m32, e32 = frexp(min_sub32)
    check("frexpf subnormal", m32 == 0.5 && e32 == -148)
    m32, e32 = frexp(f32(-3.4028235e38))
    check("frexpf largest", m32 == -0.99999994 && e32 == 128)
    m32, e32 = frexp(-f32(INF))
    check("frexpf inf", m32 == -INF && e32 == 0)
    m32, e32 = frexp(f32(0.0))
    check("frexpf zero", same(m32, f32(0.0)) && e32 == 0)
    // frexp and ldexp are inverse
    z: f64 = 3.0e-320
    while z < 1e300 {
        fm, fe := frexp(z)
        check(fmt("frexp ", z), ldexp(fm, fe) == z && fabs(fm) >= 0.5 && fabs(fm) < 1.0)
        z *= 123.456
    }
    print("frexp:", frexp(f64(10.0)), frexp(f32(-0.1)), frexp(min_sub64))
    print("failures:", failures)
    if failures == 0 { 0 } else { 1 }
}
