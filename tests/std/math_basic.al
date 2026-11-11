// scalar helpers of the math library: exact rounding, interpolation, angles, integer helpers
fails: i64

fn ok(name: str, c: bool) {
    if !c {
        fails += 1
        print("FAILED:", name)
    }
}

fn main() {
    // rounding of f32 is exact, including halves, negatives, large values and specials
    xs := [14]f32{0.0, 0.5, -0.5, 1.5, -1.5, 2.4999998, -2.5000002, 0.99999994, -0.99999994, 8388607.5, -8388607.5, 16777216.0, 1e30, -7.0}
    fl := [14]f32{0.0, 0.0, -1.0, 1.0, -2.0, 2.0, -3.0, 0.0, -1.0, 8388607.0, -8388608.0, 16777216.0, 1e30, -7.0}
    ce := [14]f32{0.0, 1.0, 0.0, 2.0, -1.0, 3.0, -2.0, 1.0, 0.0, 8388608.0, -8388607.0, 16777216.0, 1e30, -7.0}
    ro := [14]f32{0.0, 1.0, -1.0, 2.0, -2.0, 2.0, -3.0, 1.0, -1.0, 8388608.0, -8388608.0, 16777216.0, 1e30, -7.0}
    tr := [14]f32{0.0, 0.0, 0.0, 1.0, -1.0, 2.0, -2.0, 0.0, 0.0, 8388607.0, -8388607.0, 16777216.0, 1e30, -7.0}
    for i, x in xs {
        ok(fmt("floor ", x), floor(x) == fl[i])
        ok(fmt("ceil ", x), ceil(x) == ce[i])
        ok(fmt("round ", x), round(x) == ro[i])
        ok(fmt("trunc ", x), trunc(x) == tr[i])
    }
    inf: f32 = INF
    nan: f32 = NAN
    ok("floor inf", floor(inf) == inf && ceil(-inf) == -inf && round(inf) == inf && trunc(-inf) == -inf)
    ok("floor nan", floor(nan) != floor(nan) && round(nan) != round(nan))
    ok("round f64", round(2.5) == 3.0 && round(-2.5) == -3.0 && round(0.49999999999999994) == 0.0 && trunc(-3.7) == -3.0 && floor(-3.2) == -4.0 && ceil(3.2) == 4.0)
    q: f32 = 2.75
    ok("fract", fract(q) == 0.75 && fract(-q) == 0.25 && fract(3.0 + 0.125) == 0.125)
    ok("sign", sign(q) == 1.0 && sign(-q) == -1.0 && sign(q - q) == 0.0 && sign(-4.5) == -1.0)
    ok("clamp", clamp(q, 0.0, 1.0) == 1.0 && clamp(-q, 0.0, 1.0) == 0.0 && clamp(7, 1, 5) == 5 && clamp(-7, 1, 5) == 1 && clamp(0.25, 0.0, 1.0) == 0.25)
    ok("saturate", saturate(q) == 1.0 && saturate(-q) == 0.0 && saturate(q / 4.0) == 0.6875)
    a: f32 = 10.0
    b: f32 = 20.0
    ok("lerp", lerp(a, b, 0.0) == 10.0 && lerp(a, b, 1.0) == 20.0 && lerp(a, b, 0.25) == 12.5 && lerp(1.0, 3.0, 0.5) == 2.0)
    ok("inv_lerp", inv_lerp(a, b, 15.0) == 0.5 && inv_lerp(a, b, 10.0) == 0.0 && inv_lerp(0.0, 4.0, 1.0) == 0.25)
    ok("remap", remap(q, 2.0, 3.0, 100.0, 200.0) == 175.0 && remap(5.0, 0.0, 10.0, -1.0, 1.0) == 0.0)
    ok("smoothstep", smoothstep(a, b, 5.0) == 0.0 && smoothstep(a, b, 25.0) == 1.0 && smoothstep(a, b, 15.0) == 0.5 && approx_eq(smoothstep(a, b, 12.5), 0.15625))
    ok("step", step(a, 9.0) == 0.0 && step(a, 10.0) == 1.0 && step(a, 11.0) == 1.0)
    d: f32 = 180.0
    ok("radians", approx_eq(radians(d), PI) && approx_eq(degrees(radians(d)), 180.0) && approx_eq(degrees(HALF_PI), 90.0) && approx_eq(radians(360.0), TAU))
    w: f32 = 7.0
    ok("wrap_angle", approx_eq(wrap_angle(w), 7.0 - TAU) && approx_eq(wrap_angle(-w), TAU - 7.0) && wrap_angle(q) == q && approx_eq(wrap_angle(100.0), 100.0 - 16.0 * TAU))
    ok("wrap_angle range", fabs(wrap_angle(w * 1000.0)) <= 3.1415927 && fabs(wrap_angle(-12345.678)) <= PI)
    ok("approx_eq", approx_eq(q, q + 0.0000001) && !approx_eq(q, q + 0.001) && approx_eq(q, q + 0.05, 0.1) && approx_eq(1000000.0, 1000000.5) && !approx_eq(0.0, 0.00001))
    ok("is_pow2", is_pow2(1) && is_pow2(64) && !is_pow2(0) && !is_pow2(48) && !is_pow2(-8) && is_pow2(1 << 40))
    ok("next_pow2", next_pow2(0) == 1 && next_pow2(1) == 1 && next_pow2(5) == 8 && next_pow2(64) == 64 && next_pow2(65) == 128 && next_pow2(-3) == 1)
    ok("align_up", align_up(0, 16) == 0 && align_up(1, 16) == 16 && align_up(16, 16) == 16 && align_up(17, 8) == 24)
    s, c := sin_cos(q)
    ok("sin_cos f32", s == sin(q) && c == cos(q))
    s2, c2 := sin_cos(1.25)
    ok("sin_cos f64", s2 == sin(1.25) && c2 == cos(1.25) && approx_eq(s2 * s2 + c2 * c2, 1.0))
    ok("constants", approx_eq(sin(PI / 6.0), 0.5) && approx_eq(exp(1.0), E) && approx_eq(log(E), 1.0) && approx_eq(TAU, 2.0 * PI) && approx_eq(DEG2RAD * RAD2DEG, 1.0))
    h: f32 = HALF_PI
    ok("f32 constants", approx_eq(sin(h), 1.0) && fabs(cos(h)) < 0.000001 && approx_eq(atan2(q, q), PI / 4.0) && approx_eq(pow(q, 2.0), 7.5625) && approx_eq(log2(q * 4.0), 3.4594316))
    print("math_basic failures:", fails)
}
