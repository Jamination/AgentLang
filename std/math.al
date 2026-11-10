// std.math: math for games. Core module: available in every program without `use`.
//
// f32 first: every scalar function exists for f32 and f64 and is chosen by the argument type
// (`sin(x)` with an f32 `x` is the single-precision routine; a bare literal such as `sin(1.0)`
// is f64 unless an f32 is expected). Vector, quaternion and matrix functions work on the
// built-in `vec2 vec3 vec4 quat mat4`.
//
// Conventions: angles are radians. Coordinates are right-handed, view space looks down -Z,
// matrices are column-major and multiply column vectors (`m * v`, `proj * view * model`),
// clip-space depth runs 0..1. Nothing in this module allocates or keeps state.
//
// The transcendental functions are implemented here, without libm. f64: within about 1 ulp
// (pow, tan, atan2: 2 ulp). f32: within 1 ulp (atan2: 2 ulp); sin/cos/exp/log/atan/asin/acos
// run single-precision kernels (trig argument reduction and tan/pow go through f64).
// Zero, negative, huge, infinite and NaN arguments follow IEEE 754 / C99.

const PI = 3.14159265358979323846
const TAU = 6.28318530717958647692
const HALF_PI = 1.57079632679489661923
const E = 2.71828182845904523536
const DEG2RAD = 0.017453292519943295769
const RAD2DEG = 57.295779513082320877
// default tolerance of approx_eq
const EPSILON = 1e-6
const INF = 1e999
const NAN = 0.0 / 0.0

// ---------- rounding ----------

// x rounded toward zero
fn trunc(x f32) f32 {
    if !(fabs(x) < 8388608.0) {
        return x
    }
    f32(i32(x))
}

// x rounded toward zero
fn trunc(x f64) f64 {
    if !(fabs(x) < 4503599627370496.0) {
        return x
    }
    f64(i64(x))
}

// largest whole number <= x
fn floor(x f32) f32 {
    t := trunc(x)
    if t > x { t - 1.0 } else { t }
}

// smallest whole number >= x
fn ceil(x f32) f32 {
    t := trunc(x)
    if t < x { t + 1.0 } else { t }
}

// x rounded to the nearest whole number, halves away from zero
fn round(x f32) f32 {
    t := trunc(x)
    d := x - t
    if d >= 0.5 { t + 1.0 } else if d <= -0.5 { t - 1.0 } else { t }
}

// x rounded to the nearest whole number, halves away from zero
fn round(x f64) f64 {
    t := trunc(x)
    d := x - t
    if d >= 0.5 { t + 1.0 } else if d <= -0.5 { t - 1.0 } else { t }
}

// x - floor(x), in [0, 1]
fn fract(x f32) f32 {
    x - floor(x)
}

// x - floor(x), in [0, 1]
fn fract(x f64) f64 {
    x - floor(x)
}

// ---------- scalar helpers ----------

// -1, 0 or 1 with the sign of x
fn sign(x f32) f32 {
    if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { x }
}

// -1, 0 or 1 with the sign of x
fn sign(x f64) f64 {
    if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { x }
}

// x limited to [lo, hi]
fn clamp(x f32, lo f32, hi f32) f32 {
    fmin(fmax(x, lo), hi)
}

// x limited to [lo, hi]
fn clamp(x f64, lo f64, hi f64) f64 {
    fmin(fmax(x, lo), hi)
}

// x limited to [lo, hi]
fn clamp(x i64, lo i64, hi i64) i64 {
    if x < lo { lo } else if x > hi { hi } else { x }
}

// x limited to [0, 1]
fn saturate(x f32) f32 {
    fmin(fmax(x, 0.0), 1.0)
}

// x limited to [0, 1]
fn saturate(x f64) f64 {
    fmin(fmax(x, 0.0), 1.0)
}

// a at t = 0, b at t = 1, linear in between (t is not clamped)
fn lerp(a f32, b f32, t f32) f32 {
    a + (b - a) * t
}

// a at t = 0, b at t = 1, linear in between (t is not clamped)
fn lerp(a f64, b f64, t f64) f64 {
    a + (b - a) * t
}

// the t for which lerp(a, b, t) == v
fn inv_lerp(a f32, b f32, v f32) f32 {
    (v - a) / (b - a)
}

// the t for which lerp(a, b, t) == v
fn inv_lerp(a f64, b f64, v f64) f64 {
    (v - a) / (b - a)
}

// x moved from the range [in_lo, in_hi] to [out_lo, out_hi] (not clamped)
fn remap(x f32, in_lo f32, in_hi f32, out_lo f32, out_hi f32) f32 {
    out_lo + (x - in_lo) * (out_hi - out_lo) / (in_hi - in_lo)
}

// x moved from the range [in_lo, in_hi] to [out_lo, out_hi] (not clamped)
fn remap(x f64, in_lo f64, in_hi f64, out_lo f64, out_hi f64) f64 {
    out_lo + (x - in_lo) * (out_hi - out_lo) / (in_hi - in_lo)
}

// 0 below edge0, 1 above edge1, smooth (3t^2 - 2t^3) in between
fn smoothstep(edge0 f32, edge1 f32, x f32) f32 {
    t := saturate((x - edge0) / (edge1 - edge0))
    t * t * (3.0 - 2.0 * t)
}

// 0 below edge0, 1 above edge1, smooth (3t^2 - 2t^3) in between
fn smoothstep(edge0 f64, edge1 f64, x f64) f64 {
    t := saturate((x - edge0) / (edge1 - edge0))
    t * t * (3.0 - 2.0 * t)
}

// 0 if x < edge, else 1
fn step(edge f32, x f32) f32 {
    if x < edge { 0.0 } else { 1.0 }
}

// 0 if x < edge, else 1
fn step(edge f64, x f64) f64 {
    if x < edge { 0.0 } else { 1.0 }
}

// degrees to radians
fn radians(deg f32) f32 {
    deg * DEG2RAD
}

// degrees to radians
fn radians(deg f64) f64 {
    deg * DEG2RAD
}

// radians to degrees
fn degrees(rad f32) f32 {
    rad * RAD2DEG
}

// radians to degrees
fn degrees(rad f64) f64 {
    rad * RAD2DEG
}

// the angle a brought into [-PI, PI] by adding a multiple of TAU; angles already inside are returned unchanged
fn wrap_angle(a f32) f32 {
    a - TAU * floor((a + PI) / TAU)
}

// the angle a brought into [-PI, PI] by adding a multiple of TAU; angles already inside are returned unchanged
fn wrap_angle(a f64) f64 {
    a - TAU * floor((a + PI) / TAU)
}

// |a - b| <= EPSILON * max(1, |a|, |b|)
fn approx_eq(a f32, b f32) bool {
    fabs(a - b) <= EPSILON * fmax(1.0, fmax(fabs(a), fabs(b)))
}

// |a - b| <= EPSILON * max(1, |a|, |b|)
fn approx_eq(a f64, b f64) bool {
    fabs(a - b) <= EPSILON * fmax(1.0, fmax(fabs(a), fabs(b)))
}

// |a - b| <= eps
fn approx_eq(a f32, b f32, eps f32) bool {
    fabs(a - b) <= eps
}

// |a - b| <= eps
fn approx_eq(a f64, b f64, eps f64) bool {
    fabs(a - b) <= eps
}

// is x a power of two (1, 2, 4, ...)?
fn is_pow2(x i64) bool {
    x > 0 && x & (x - 1) == 0
}

// smallest power of two >= x (1 for x <= 1); x must not exceed 2^62
fn next_pow2(x i64) i64 {
    if x <= 1 {
        return 1
    }
    1 << (64 - i64(clz(x - 1)))
}

// x rounded up to a multiple of align, which must be a power of two
fn align_up(x i64, align i64) i64 {
    (x + align - 1) & ~(align - 1)
}

// ---------- f64 kernels ----------

const __PIO4 = 0.7853981633974483
const __INV_PIO2 = 0.6366197723675814
// pi/2 in 33-bit pieces (n * piece is exact for n < 2^20) and the tail after each
const __PIO2_1 = 1.5707963267341256
const __PIO2_1T = 6.077100506506192e-11
const __PIO2_2 = 6.077100506303966e-11
const __PIO2_2T = 2.0222662487959506e-21
const __PIO2_3 = 2.0222662487111665e-21
const __PIO2_3T = 8.4784276603689e-32
// pi/2 in 27-bit pieces
const __PIO2_A = 1.570796325802803
const __PIO2_B = 9.920935739593517e-10
const __PIO2_C = 5.721188726109832e-18
const __PIO2_HI = 1.5707963267948966
const __PIO2_LO = 6.123233995736766e-17
const __PI_LO = 1.2246467991473532e-16
// ln 2: 32 bits (k * hi is exact) and the rest
const __LN2_HI = 0.6931471803691238
const __LN2_LO = 1.9082149292705877e-10
const __INV_LN2 = 1.4426950408889634
const __IVLN2_HI = 1.4426946640014648
const __IVLN2_LO = 3.768874985636099e-07
// 2/3, and split into 27 bits + rest
const __CP = 0.6666666666666666
const __CP_H = 0.6666666641831398
const __CP_L = 2.483526865641276e-09
// atan(0.5), atan(1), atan(1.5), atan(inf) and what rounding them lost
var __ATAN_HI = [4]f64{0.4636476090008061, 0.7853981633974483, 0.982793723247329, 1.5707963267948966}
var __ATAN_LO = [4]f64{2.2698777452961687e-17, 3.061616997868383e-17, 1.3903311031230998e-17, 6.123233995736766e-17}
// the binary digits of 2/pi; word 0 holds the (zero) digits left of the point
var __TWO_OVER_PI = [20]u64{
    0x0000000000000000, 0xA2F9836E4E441529, 0xFC2757D1F534DDC0, 0xDB6295993C439041,
    0xFE5163ABDEBBC561, 0xB7246E3A424DD2E0, 0x06492EEA09D1921C, 0xFE1DEB1CB129A73E,
    0xE88235F52EBB4484, 0xE99C7026B45F7E41, 0x3991D639835339F4, 0x9C845F8BBDF9283B,
    0x1FF897FFDE05980F, 0xEF2F118B5A0A6D1F, 0x6D367ECF27CB09B7, 0x4F463F669E5FEA2D,
    0x7527BAC7EBE5F17B, 0x3D0739F78A5292EA, 0x6BFB5FB11F8D5D08, 0x56033046FC7B6BAB}

// Polynomial coefficients: weighted minimax fits (Remez), each coefficient rounded in turn.
// sin(x) = x + x^3 * S(x^2), cos(x) = 1 - x^2/2 + x^4 * C(x^2) on |x| <= pi/4
const __S1 = -0.1666666666666663
const __S2 = 0.00833333333332184
const __S3 = -0.0001984126982935853
const __S4 = 2.7557313538516135e-06
const __S5 = -2.5050734389685003e-08
const __S6 = 1.5895433320308664e-10
const __C1 = 0.041666666666666595
const __C2 = -0.001388888888887332
const __C3 = 2.480158728897899e-05
const __C4 = -2.755731420827496e-07
const __C5 = 2.087570397724136e-09
const __C6 = -1.1358665991733492e-11
// atan(x) = x + x^3 * AT(x^2) on |x| <= 7/16
const __AT1 = -0.3333333333333292
const __AT2 = 0.19999999999873752
const __AT3 = -0.14285714272267236
const __AT4 = 0.11111110395279333
const __AT5 = -0.09090886880408829
const __AT6 = 0.0769187230949943
const __AT7 = -0.06661034759264373
const __AT8 = 0.05833327807696977
const __AT9 = -0.049759293742917814
const __AT10 = 0.03651061024238453
const __AT11 = -0.01626583284553897
// asin(x) = x + x^3 * P(x^2) / Q(x^2) on |x| <= 1/2
const __ASP1 = 0.1666666666666666
const __ASP2 = -0.3267454420501004
const __ASP3 = 0.20288901827397887
const __ASP4 = -0.04065065492845929
const __ASP5 = 0.0008135001313251829
const __ASP6 = 3.6252883250344145e-05
const __ASQ1 = -2.4104726523006743
const __ASQ2 = 2.0341896603264984
const __ASQ3 = -0.6959186259385266
const __ASQ4 = 0.07834827700176485
// r * (e^r + 1) / (e^r - 1) = 2 + r^2 * EP(r^2) on |r| <= ln(2)/2
const __EP1 = 0.16666666666666555
const __EP2 = -0.002777777777669617
const __EP3 = 6.613756250019724e-05
const __EP4 = -1.6533837004080303e-06
const __EP5 = 4.136040517913001e-08
// 3 * atanh(s) / s = 3 + s^2 + s^4 * LG(s^2) on |s| <= 0.1716
const __LG1 = 0.6000000000000341
const __LG2 = 0.42857142855137703
const __LG3 = 0.3333333378212167
const __LG4 = 0.27272676343163443
const __LG5 = 0.23080146034642535
const __LG6 = 0.19884982858732675
const __LG7 = 0.1979684027464579

// 2^e for -1022 <= e <= 1023
inline fn __pow2(e i64) f64 {
    cast[f64](u64(e + 1023) << 52)
}

// x with the low 32 bits of its representation cleared (21 significant bits remain)
inline fn __trunc32(x f64) f64 {
    cast[f64](cast[u64](x) & 0xFFFFFFFF00000000)
}

// high 64 bits of the 128-bit product a * b
fn __mulhi(a u64, b u64) u64 {
    a0 := a & 0xFFFFFFFF
    a1 := a >> 32
    b0 := b & 0xFFFFFFFF
    b1 := b >> 32
    t := a1 * b0 + ((a0 * b0) >> 32)
    u := a0 * b1 + (t & 0xFFFFFFFF)
    a1 * b1 + (t >> 32) + (u >> 32)
}

// Payne-Hanek reduction for finite |x| >= 2^20: x = n * pi/2 + (hi + lo), |hi| <= pi/4;
// returns (n mod 4, hi, lo). Exact integer arithmetic on the 192 digits of 2/pi that matter.
fn __rem_pio2_big(x f64) (i64, f64, f64) {
    bits := cast[u64](x) & 0x7FFFFFFFFFFFFFFF
    e := i64(bits >> 52) - 1075
    m := (bits & 0x000FFFFFFFFFFFFF) | 0x0010000000000000
    // |x| = m * 2^e; digits of 2/pi worth 4 or more times m only add multiples of 2*pi
    o := e + 62
    w := o >> 6
    s := u64(o & 63)
    w2 := __TWO_OVER_PI[w]
    w1 := __TWO_OVER_PI[w + 1]
    w0 := __TWO_OVER_PI[w + 2]
    if s != 0 {
        w2 = w2 << s | w1 >> (64 - s)
        w1 = w1 << s | w0 >> (64 - s)
        w0 = w0 << s | __TWO_OVER_PI[w + 3] >> (64 - s)
    }
    // p = m * (w2:w1:w0) mod 2^192 = (|x| * 2/pi mod 4) * 2^190
    p0 := m * w0
    p1 := __mulhi(m, w0) + m * w1
    p2 := __mulhi(m, w1) + m * w2
    if p1 < m * w1 {
        p2 += 1
    }
    q := i64(p2 >> 62)
    // the fraction, as 192 bits after the binary point
    f2 := p2 << 2 | p1 >> 62
    f1 := p1 << 2 | p0 >> 62
    f0 := p0 << 2
    neg := x < 0.0
    if f2 >> 63 != 0 {
        // above one half: round n up, the remainder is negative
        q += 1
        neg = !neg
        f2 = ~f2
        f1 = ~f1
        f0 = 0 - f0
        if f0 == 0 {
            f1 += 1
            if f1 == 0 {
                f2 += 1
            }
        }
    }
    sh := u64(0)
    if f2 == 0 {
        f2 = f1
        f1 = f0
        sh = 64
    }
    if f2 == 0 {
        return (q & 3, 0.0, 0.0)
    }
    z := u64(clz(f2))
    if z != 0 {
        f2 = f2 << z | f1 >> (64 - z)
        f1 = f1 << z
    }
    // top 26 + 26 + 53 bits of the fraction, times pi/2 in 27-bit pieces: every product is exact
    sc := __pow2(-26 - i64(sh + z))
    d0 := f64(i64(f2 >> 38)) * sc
    d1 := f64(i64((f2 >> 12) & 0x3FFFFFF)) * (sc * 1.4901161193847656e-08)
    d2 := f64(i64((f2 & 0xFFF) << 41 | f1 >> 23)) * (sc * 1.6543612251060553e-24)
    hi := d0 * __PIO2_A
    t := (d0 * __PIO2_B + d1 * __PIO2_A) + (d0 * __PIO2_C + d1 * __PIO2_B + d2 * __PIO2_A)
    y := hi + t
    lo := t - (y - hi)
    if x < 0.0 {
        q = -q
    }
    if neg {
        return (q & 3, -y, -lo)
    }
    (q & 3, y, lo)
}

// x = n * pi/2 + (hi + lo) with |hi| <= pi/4, for finite x; returns (n, hi, lo), n exact mod 4
fn __rem_pio2(x f64) (i64, f64, f64) {
    if fabs(x) >= 1048576.0 {
        return __rem_pio2_big(x)
    }
    n := (x * __INV_PIO2 + 6755399441055744.0) - 6755399441055744.0
    r := x - n * __PIO2_1
    w := n * __PIO2_1T
    y := r - w
    if fabs(y) < fabs(x) * 3.0517578125e-05 {
        // many leading bits cancelled: bring in the next 33 bits of pi/2
        t := r
        w = n * __PIO2_2
        r = t - w
        w = n * __PIO2_2T - ((t - r) - w)
        y = r - w
        if fabs(y) < fabs(x) * 3.552713678800501e-15 {
            t = r
            w = n * __PIO2_3
            r = t - w
            w = n * __PIO2_3T - ((t - r) - w)
            y = r - w
        }
    }
    (i64(n), y, (r - y) - w)
}

// sin(x + y) for |x| <= pi/4, y the tail of x
fn __sin_k(x f64, y f64) f64 {
    z := x * x
    v := z * x
    r := __S2 + z * (__S3 + z * (__S4 + z * (__S5 + z * __S6)))
    x - ((z * (0.5 * y - v * r) - y) - v * __S1)
}

// cos(x + y) for |x| <= pi/4, y the tail of x
fn __cos_k(x f64, y f64) f64 {
    z := x * x
    hz := 0.5 * z
    w := 1.0 - hz
    r := z * (__C1 + z * (__C2 + z * (__C3 + z * (__C4 + z * (__C5 + z * __C6)))))
    w + (((1.0 - w) - hz) + (z * r - x * y))
}

// (asin(x) - x) / x^3 as a function of z = x^2 <= 1/4, times z
fn __asin_r(z f64) f64 {
    p := z * (__ASP1 + z * (__ASP2 + z * (__ASP3 + z * (__ASP4 + z * (__ASP5 + z * __ASP6)))))
    q := 1.0 + z * (__ASQ1 + z * (__ASQ2 + z * (__ASQ3 + z * __ASQ4)))
    p / q
}

// (atan(x) - x) / x as a function of z = x^2
fn __atan_r(z f64) f64 {
    z * (__AT1 + z * (__AT2 + z * (__AT3 + z * (__AT4 + z * (__AT5 + z * (__AT6 + z * (__AT7 + z * (__AT8 + z * (__AT9 + z * (__AT10 + z * __AT11))))))))))
}

// finite x > 0 as 2^k * (1 + f) with sqrt(2)/2 <= 1 + f < sqrt(2); returns (k, f)
fn __log_split(x f64) (i64, f64) {
    bits := cast[u64](x)
    k := 0
    if bits < 0x0010000000000000 {
        bits = cast[u64](x * 18014398509481984.0)
        k = -54
    }
    bits += 0x00095F6200000000
    k += i64(bits >> 52) - 1023
    bits = (bits & 0x000FFFFFFFFFFFFF) + 0x3FE6A09E00000000
    (k, cast[f64](bits) - 1.0)
}

inline fn __lg(z f64) f64 {
    __LG1 + z * (__LG2 + z * (__LG3 + z * (__LG4 + z * (__LG5 + z * (__LG6 + z * __LG7)))))
}

// log(1 + f) = f - h + r for the f of __log_split; returns (h, r) with h = f^2 / 2
fn __log1p_k(f f64) (f64, f64) {
    s := f / (2.0 + f)
    z := s * s
    h := 0.5 * f * f
    (h, s * (h + __CP * (z + z * z * __lg(z))))
}

// log(x) for finite x > 0 as hi + lo, about 70 bits; the low 32 bits of hi are clear
fn __log_dd(x f64) (f64, f64) {
    k, f := __log_split(x)
    // s = f / (2 + f) as sh + sl
    m := f + 1.0
    d := m + 1.0
    v := 1.0 / d
    s := f * v
    sh := __trunc32(s)
    dh := __trunc32(d)
    dl := m - (dh - 1.0)
    sl := v * ((f - sh * dh) - sh * dl)
    // log(1 + f) = 2/3 * s * (3 + s^2 + s^4 * LG(s^2))
    z := s * s
    r := z * z * __lg(z) + sl * (sh + s)
    z2 := sh * sh
    th := __trunc32(3.0 + z2 + r)
    tl := r - ((th - 3.0) - z2)
    u := sh * th
    w := sl * th + tl * s
    ph := __trunc32(u + w)
    pl := w - (ph - u)
    zh := __CP_H * ph
    zl := __CP_L * ph + pl * __CP
    // + k * ln 2
    t := f64(k) * __LN2_HI
    hi := __trunc32((zh + zl) + t)
    (hi, zl - ((hi - t) - zh) + f64(k) * __LN2_LO)
}

// e^(x + xlo) where xlo is a small correction to x
fn __exp_k(x f64, xlo f64) f64 {
    if x != x {
        return x
    }
    if x > 710.0 {
        return INF
    }
    if x < -746.0 {
        return 0.0
    }
    k := i64(x * __INV_LN2 + (if x < 0.0 { -0.5 } else { 0.5 }))
    hi := x - f64(k) * __LN2_HI
    lo := f64(k) * __LN2_LO - xlo
    r := hi - lo
    t := r * r
    c := r - t * (__EP1 + t * (__EP2 + t * (__EP3 + t * (__EP4 + t * __EP5))))
    y := 1.0 - ((lo - r * c / (2.0 - c)) - hi)
    // scale by 2^k in exact steps so that the result is rounded once
    if k > 1023 {
        return y * 8.98846567431158e307 * __pow2(k - 1023)
    }
    if k < -1022 {
        return y * 2.004168360008973e-292 * __pow2(k + 969)
    }
    y * __pow2(k)
}

// The special cases of pow(x, y). Returns (result, true) when x, y are one of them,
// otherwise (sign of the result, false).
fn __pow_special[T](x T, y T) (T, bool) {
    var one T = 1.0
    var zero T
    if y == 0.0 || x == 1.0 {
        return (one, true)
    }
    if x != x || y != y {
        return (x + y, true)
    }
    ax := fabs(x)
    ay := fabs(y)
    whole := floor(ay) == ay
    odd := whole && floor(ay * 0.5) != ay * 0.5
    if (x < 0.0 || one / x < 0.0) && odd {
        one = -1.0
    }
    if ay == INF {
        if ax == 1.0 {
            return (ax, true)
        }
        return (if (ax > 1.0) == (y > 0.0) { ay } else { zero }, true)
    }
    if ax == 0.0 || ax == INF {
        return (if y < 0.0 { one / ax } else { one * ax }, true)
    }
    if x < 0.0 && !whole {
        return (NAN, true)
    }
    (one, false)
}

// ---------- f64 functions ----------

// sine of x (radians)
fn sin(x f64) f64 {
    if fabs(x) <= __PIO4 {
        return __sin_k(x, 0.0)
    }
    if !(fabs(x) < INF) {
        return x - x
    }
    n, r, t := __rem_pio2(x)
    match n & 3 {
        0 => __sin_k(r, t)
        1 => __cos_k(r, t)
        2 => -__sin_k(r, t)
        _ => -__cos_k(r, t)
    }
}

// cosine of x (radians)
fn cos(x f64) f64 {
    if fabs(x) <= __PIO4 {
        return __cos_k(x, 0.0)
    }
    if !(fabs(x) < INF) {
        return x - x
    }
    n, r, t := __rem_pio2(x)
    match n & 3 {
        0 => __cos_k(r, t)
        1 => -__sin_k(r, t)
        2 => -__cos_k(r, t)
        _ => __sin_k(r, t)
    }
}

// (sin(x), cos(x)) with one argument reduction
fn sin_cos(x f64) (f64, f64) {
    if !(fabs(x) < INF) {
        return (x - x, x - x)
    }
    n := 0
    r := x
    t := 0.0
    if fabs(x) > __PIO4 {
        n, r, t = __rem_pio2(x)
    }
    s := __sin_k(r, t)
    c := __cos_k(r, t)
    match n & 3 {
        0 => (s, c)
        1 => (c, -s)
        2 => (-s, -c)
        _ => (-c, s)
    }
}

// tangent of x (radians)
fn tan(x f64) f64 {
    s, c := sin_cos(x)
    s / c
}

// arc sine in [-PI/2, PI/2]; NaN outside [-1, 1]
fn asin(x f64) f64 {
    a := fabs(x)
    if a < 0.5 {
        return x + x * __asin_r(x * x)
    }
    if !(a <= 1.0) {
        return NAN
    }
    // asin(a) = pi/2 - 2 * asin(sqrt((1 - a) / 2))
    z := (1.0 - a) * 0.5
    s := sqrt(z)
    r := __asin_r(z)
    t := 0.0
    if a >= 0.975 {
        t = __PIO2_HI - (2.0 * (s + s * r) - __PIO2_LO)
    } else {
        f := __trunc32(s)
        c := (z - f * f) / (s + f)
        t = __PIO4 - ((2.0 * s * r - (__PIO2_LO - 2.0 * c)) - (__PIO4 - 2.0 * f))
    }
    if x < 0.0 { -t } else { t }
}

// arc cosine in [0, PI]; NaN outside [-1, 1]
fn acos(x f64) f64 {
    a := fabs(x)
    if a < 0.5 {
        return __PIO2_HI - (x - (__PIO2_LO - x * __asin_r(x * x)))
    }
    if !(a < 1.0) {
        if a != 1.0 {
            return NAN
        }
        return if x > 0.0 { 0.0 } else { PI }
    }
    z := (1.0 - a) * 0.5
    s := sqrt(z)
    r := __asin_r(z)
    if x < 0.0 {
        return PI - 2.0 * (s + (r * s - __PIO2_LO))
    }
    f := __trunc32(s)
    c := (z - f * f) / (s + f)
    2.0 * (f + (r * s + c))
}

// arc tangent in [-PI/2, PI/2]
fn atan(x f64) f64 {
    a := fabs(x)
    if a < 0.4375 {
        return x + x * __atan_r(x * x)
    }
    if x != x {
        return x
    }
    // atan(a) = atan(c) + atan((a - c) / (1 + a * c)) for c = 0.5, 1, 1.5, infinity
    id := 3
    t := -1.0 / a
    if a < 0.6875 {
        id = 0
        t = (2.0 * a - 1.0) / (2.0 + a)
    } else if a < 1.1875 {
        id = 1
        t = (a - 1.0) / (a + 1.0)
    } else if a < 2.4375 {
        id = 2
        t = (a - 1.5) / (1.0 + 1.5 * a)
    }
    r := __ATAN_HI[id] + (t + (t * __atan_r(t * t) + __ATAN_LO[id]))
    if x < 0.0 { -r } else { r }
}

// angle of the point (x, y) in [-PI, PI] (note the argument order: y first)
fn atan2(y f64, x f64) f64 {
    if x != x || y != y {
        return x + y
    }
    ax := fabs(x)
    ay := fabs(y)
    z := 0.0
    if ay != 0.0 {
        z = if ax == INF && ay == INF { __PIO4 } else { atan(ay / ax) }
    }
    if cast[u64](x) >> 63 != 0 {
        z = PI - (z - __PI_LO)
    }
    if cast[u64](y) >> 63 != 0 { -z } else { z }
}

// e^x
fn exp(x f64) f64 {
    __exp_k(x, 0.0)
}

// natural logarithm; -INF for 0, NaN for x < 0
fn log(x f64) f64 {
    if !(x > 0.0) {
        return if x == 0.0 { -INF } else { NAN }
    }
    if x == INF {
        return x
    }
    k, f := __log_split(x)
    h, r := __log1p_k(f)
    f64(k) * __LN2_HI - ((h - (r + f64(k) * __LN2_LO)) - f)
}

// base 2 logarithm (exact for powers of two); -INF for 0, NaN for x < 0
fn log2(x f64) f64 {
    if !(x > 0.0) {
        return if x == 0.0 { -INF } else { NAN }
    }
    if x == INF {
        return x
    }
    k, f := __log_split(x)
    h, r := __log1p_k(f)
    hi := __trunc32(f - h)
    lo := (f - hi) - h + r
    vh := hi * __IVLN2_HI
    vl := (lo + hi) * __IVLN2_LO + lo * __IVLN2_HI
    w := f64(k) + vh
    vl + ((f64(k) - w) + vh) + w
}

// x raised to the power y (C99 rules: pow(x, 0) = 1, negative x needs a whole y, ...)
fn pow(x f64, y f64) f64 {
    s, done := __pow_special(x, y)
    if done {
        return s
    }
    hi, lo := __log_dd(fabs(x))
    yh := __trunc32(y)
    s * __exp_k(yh * hi, (y - yh) * hi + y * lo)
}

// finite a > 0 as m * 2^e with 2^52 <= m < 2^53; returns (m, e)
fn __mant_exp(a f64) (u64, i64) {
    bits := cast[u64](a)
    e := i64(bits >> 52)
    m := bits & 0x000FFFFFFFFFFFFF
    if e == 0 {
        z := u64(clz(m)) - 11
        return (m << z, -1074 - i64(z))
    }
    (m | 0x0010000000000000, e - 1075)
}

// remainder of x / y with the sign of x (exact); NaN if y is 0 or x is infinite
fn fmod(x f64, y f64) f64 {
    ax := fabs(x)
    ay := fabs(y)
    if !(ax < INF) || !(ay > 0.0) {
        return NAN
    }
    if ax < ay {
        return x
    }
    mx, ex := __mant_exp(ax)
    my, ey := __mant_exp(ay)
    // long division, 11 quotient bits per step
    r := mx % my
    n := ex - ey
    while n > 0 {
        s := min(n, 11)
        r = (r << u64(s)) % my
        n -= s
    }
    v := f64(i64(r))
    v = if ey < -1000 { v * __pow2(ey + 600) * 2.409919865102884e-181 } else { v * __pow2(ey) }
    if x < 0.0 { -v } else { v }
}

// ---------- f32 kernels ----------

// 25 bits of pi/2 (n * piece is exact in f64 for n < 2^28) and the rest
const __PIO2F_1 = 1.5707963109016418
const __PIO2F_1T = 1.5893254773528196e-08
const __PIO2F_HI = 1.5707963705062866
const __PIO2F_LO = -4.371138828673793e-08
const __PIO4F = 0.7853981852531433
const __PIF_LO = -8.742277657347586e-08
// ln 2: 16 bits (k * hi is exact) and the rest
const __LN2F_HI = 0.693145751953125
const __LN2F_LO = 1.428606765330187e-06
const __IVLN2F_HI = 1.4423828125
const __IVLN2F_LO = 0.00031222839606925845
var __ATANF_HI = [4]f32{0.46364760398864746, 0.7853981852531433, 0.9827937483787537, 1.5707963705062866}
var __ATANF_LO = [4]f32{5.01215868808913e-09, -2.1855694143368964e-08, -2.5131424052915463e-08, -4.371138828673793e-08}

// the single-precision counterparts of the fits above (coefficients are exact f32 values)
const __SF1 = -0.1666666716337204
const __SF2 = 0.008333379402756691
const __SF3 = -0.00019853064441122115
const __SF4 = 2.8325100629444933e-06
const __CF1 = 0.04166664555668831
const __CF2 = -0.0013887309469282627
const __CF3 = 2.4432327336398885e-05
const __ATF1 = -0.3333330452442169
const __ATF2 = 0.1999778151512146
const __ATF3 = -0.14230172336101532
const __ATF4 = 0.10494108498096466
const __ATF5 = -0.05825638398528099
const __ASFP1 = 0.1666666716337204
const __ASFP2 = -0.1203669011592865
const __ASFP3 = 0.0056250994093716145
const __ASFQ1 = -1.1721992492675781
const __ASFQ2 = 0.29334113001823425
const __EPF1 = 0.166666179895401
const __EPF2 = -0.0027660115156322718
// 2 * atanh(s) = 2s + s^3 * LGF(s^2)
const __LGF1 = 0.6666677594184875
const __LGF2 = 0.3997756540775299
const __LGF3 = 0.2987159490585327
// tan(x) = x + x^3 * TF(x^2) on |x| <= pi/4, to f32 accuracy, evaluated in f64
const __TF1 = 0.3333334992996423
const __TF2 = 0.13332657089350944
const __TF3 = 0.054060649034842846
const __TF4 = 0.021278282810232724
const __TF5 = 0.010846238569136477
const __TF6 = 7.594712900399639e-05
const __TF7 = 0.004383155848503015

// 2^e for -126 <= e <= 127
inline fn __pow2f(e i64) f32 {
    cast[f32](u32(e + 127) << 23)
}

// x with the low 12 bits of its representation cleared (12 significant bits remain)
inline fn __trunc12(x f32) f32 {
    cast[f32](cast[u32](x) & 0xFFFFF000)
}

// finite x = n * pi/2 + r with |r| <= pi/4; returns (n, r), n exact mod 4, r in double precision
fn __rem_pio2f(x f32) (i64, f64) {
    d := f64(x)
    if fabs(x) >= 4.0e8 {
        q, hi, _ := __rem_pio2_big(d)
        return (q, hi)
    }
    n := (d * __INV_PIO2 + 6755399441055744.0) - 6755399441055744.0
    (i64(n), (d - n * __PIO2F_1) - n * __PIO2F_1T)
}

// sin(x + y) for |x| <= pi/4, y the tail of x
fn __sin_kf(x f32, y f32) f32 {
    z := x * x
    v := z * x
    r := __SF2 + z * (__SF3 + z * __SF4)
    x - ((z * (0.5 * y - v * r) - y) - v * __SF1)
}

// cos(x + y) for |x| <= pi/4, y the tail of x
fn __cos_kf(x f32, y f32) f32 {
    z := x * x
    hz := 0.5 * z
    w := 1.0 - hz
    r := z * (__CF1 + z * (__CF2 + z * __CF3))
    w + (((1.0 - w) - hz) + (z * r - x * y))
}

// (asin(x) - x) / x^3 as a function of z = x^2 <= 1/4, times z
fn __asin_rf(z f32) f32 {
    z * (__ASFP1 + z * (__ASFP2 + z * __ASFP3)) / (1.0 + z * (__ASFQ1 + z * __ASFQ2))
}

// (atan(x) - x) / x as a function of z = x^2
fn __atan_rf(z f32) f32 {
    z * (__ATF1 + z * (__ATF2 + z * (__ATF3 + z * (__ATF4 + z * __ATF5))))
}

// finite x > 0 as 2^k * (1 + f) with sqrt(2)/2 <= 1 + f < sqrt(2); returns (k, f)
fn __log_splitf(x f32) (i64, f32) {
    bits := cast[u32](x)
    k := 0
    if bits < 0x00800000 {
        bits = cast[u32](x * 33554432.0)
        k = -25
    }
    bits += 0x004AFB0D
    k += i64(bits >> 23) - 127
    bits = (bits & 0x007FFFFF) + 0x3F3504F3
    (k, cast[f32](bits) - 1.0)
}

// log(1 + f) = f - h + r for the f of __log_splitf; returns (h, r) with h = f^2 / 2
fn __log1p_kf(f f32) (f32, f32) {
    s := f / (2.0 + f)
    z := s * s
    h := 0.5 * f * f
    (h, s * (h + z * (__LGF1 + z * (__LGF2 + z * __LGF3))))
}

// ---------- f32 functions ----------

// sine of x (radians)
fn sin(x f32) f32 {
    if fabs(x) <= __PIO4F {
        return __sin_kf(x, 0.0)
    }
    if !(fabs(x) < INF) {
        return x - x
    }
    n, r := __rem_pio2f(x)
    h := f32(r)
    t := f32(r - f64(h))
    match n & 3 {
        0 => __sin_kf(h, t)
        1 => __cos_kf(h, t)
        2 => -__sin_kf(h, t)
        _ => -__cos_kf(h, t)
    }
}

// cosine of x (radians)
fn cos(x f32) f32 {
    if fabs(x) <= __PIO4F {
        return __cos_kf(x, 0.0)
    }
    if !(fabs(x) < INF) {
        return x - x
    }
    n, r := __rem_pio2f(x)
    h := f32(r)
    t := f32(r - f64(h))
    match n & 3 {
        0 => __cos_kf(h, t)
        1 => -__sin_kf(h, t)
        2 => -__cos_kf(h, t)
        _ => __sin_kf(h, t)
    }
}

// (sin(x), cos(x)) with one argument reduction
fn sin_cos(x f32) (f32, f32) {
    if !(fabs(x) < INF) {
        return (x - x, x - x)
    }
    n := 0
    h := x
    var t f32
    if fabs(x) > __PIO4F {
        var r f64
        n, r = __rem_pio2f(x)
        h = f32(r)
        t = f32(r - f64(h))
    }
    s := __sin_kf(h, t)
    c := __cos_kf(h, t)
    match n & 3 {
        0 => (s, c)
        1 => (c, -s)
        2 => (-s, -c)
        _ => (-c, s)
    }
}

// tangent of x (radians)
fn tan(x f32) f32 {
    if !(fabs(x) < INF) {
        return x - x
    }
    n := 0
    r := f64(x)
    if fabs(x) > __PIO4F {
        n, r = __rem_pio2f(x)
    }
    z := r * r
    t := r + r * z * (__TF1 + z * (__TF2 + z * (__TF3 + z * (__TF4 + z * (__TF5 + z * (__TF6 + z * __TF7))))))
    f32(if n & 1 != 0 { -1.0 / t } else { t })
}

// arc sine in [-PI/2, PI/2]; NaN outside [-1, 1]
fn asin(x f32) f32 {
    a := fabs(x)
    if a < 0.5 {
        return x + x * __asin_rf(x * x)
    }
    if !(a <= 1.0) {
        return NAN
    }
    z := (1.0 - a) * 0.5
    s := sqrt(z)
    r := __asin_rf(z)
    var t f32
    if a >= 0.975 {
        t = __PIO2F_HI - (2.0 * (s + s * r) - __PIO2F_LO)
    } else {
        f := __trunc12(s)
        c := (z - f * f) / (s + f)
        t = __PIO4F - ((2.0 * s * r - (__PIO2F_LO - 2.0 * c)) - (__PIO4F - 2.0 * f))
    }
    if x < 0.0 { -t } else { t }
}

// arc cosine in [0, PI]; NaN outside [-1, 1]
fn acos(x f32) f32 {
    a := fabs(x)
    if a < 0.5 {
        return __PIO2F_HI - (x - (__PIO2F_LO - x * __asin_rf(x * x)))
    }
    if !(a < 1.0) {
        if a != 1.0 {
            return NAN
        }
        return if x > 0.0 { 0.0 } else { PI }
    }
    z := (1.0 - a) * 0.5
    s := sqrt(z)
    r := __asin_rf(z)
    if x < 0.0 {
        return PI - 2.0 * (s + (r * s - __PIO2F_LO))
    }
    f := __trunc12(s)
    c := (z - f * f) / (s + f)
    2.0 * (f + (r * s + c))
}

// arc tangent in [-PI/2, PI/2]
fn atan(x f32) f32 {
    a := fabs(x)
    if a < 0.4375 {
        return x + x * __atan_rf(x * x)
    }
    if x != x {
        return x
    }
    id := 3
    t := -1.0 / a
    if a < 0.6875 {
        id = 0
        t = (2.0 * a - 1.0) / (2.0 + a)
    } else if a < 1.1875 {
        id = 1
        t = (a - 1.0) / (a + 1.0)
    } else if a < 2.4375 {
        id = 2
        t = (a - 1.5) / (1.0 + 1.5 * a)
    }
    r := __ATANF_HI[id] + (t + (t * __atan_rf(t * t) + __ATANF_LO[id]))
    if x < 0.0 { -r } else { r }
}

// angle of the point (x, y) in [-PI, PI] (note the argument order: y first)
fn atan2(y f32, x f32) f32 {
    if x != x || y != y {
        return x + y
    }
    ax := fabs(x)
    ay := fabs(y)
    var z f32
    if ay != 0.0 {
        z = if ax == INF && ay == INF { __PIO4F } else { atan(ay / ax) }
    }
    if cast[u32](x) >> 31 != 0 {
        z = PI - (z - __PIF_LO)
    }
    if cast[u32](y) >> 31 != 0 { -z } else { z }
}

// e^x
fn exp(x f32) f32 {
    if x != x {
        return x
    }
    if x > 89.0 {
        return INF
    }
    if x < -104.0 {
        return 0.0
    }
    k := i64(x * __INV_LN2 + (if x < 0.0 { -0.5 } else { 0.5 }))
    hi := x - f32(k) * __LN2F_HI
    lo := f32(k) * __LN2F_LO
    r := hi - lo
    t := r * r
    c := r - t * (__EPF1 + t * __EPF2)
    y := 1.0 - ((lo - r * c / (2.0 - c)) - hi)
    if k > 127 {
        return y * 1.7014118346046923e38 * __pow2f(k - 127)
    }
    if k < -126 {
        return y * 7.888609052210118e-31 * __pow2f(k + 100)
    }
    y * __pow2f(k)
}

// natural logarithm; -INF for 0, NaN for x < 0
fn log(x f32) f32 {
    if !(x > 0.0) {
        return if x == 0.0 { -INF } else { NAN }
    }
    if x == INF {
        return x
    }
    k, f := __log_splitf(x)
    h, r := __log1p_kf(f)
    f32(k) * __LN2F_HI - ((h - (r + f32(k) * __LN2F_LO)) - f)
}

// base 2 logarithm (exact for powers of two); -INF for 0, NaN for x < 0
fn log2(x f32) f32 {
    if !(x > 0.0) {
        return if x == 0.0 { -INF } else { NAN }
    }
    if x == INF {
        return x
    }
    k, f := __log_splitf(x)
    h, r := __log1p_kf(f)
    hi := __trunc12(f - h)
    lo := (f - hi) - h + r
    (lo + hi) * __IVLN2F_LO + lo * __IVLN2F_HI + hi * __IVLN2F_HI + f32(k)
}

// x raised to the power y (C99 rules: pow(x, 0) = 1, negative x needs a whole y, ...)
fn pow(x f32, y f32) f32 {
    s, done := __pow_special(x, y)
    if done {
        return s
    }
    s * f32(exp(f64(y) * log(f64(fabs(x)))))
}

// remainder of x / y with the sign of x (exact); NaN if y is 0 or x is infinite
fn fmod(x f32, y f32) f32 {
    f32(fmod(f64(x), f64(y)))
}

// ---------- vectors ----------

// dot product
fn dot(a vec2, b vec2) f32 {
    m := a * b
    m.x + m.y
}

// dot product
fn dot(a vec3, b vec3) f32 {
    m := a * b
    m.x + m.y + m.z
}

// dot product
fn dot(a vec4, b vec4) f32 {
    m := a * b
    (m.x + m.y) + (m.z + m.w)
}

// cross product (right-handed)
fn cross(a vec3, b vec3) vec3 {
    a.yzx * b.zxy - a.zxy * b.yzx
}

// z of the 3D cross product: > 0 when b is counter-clockwise from a
fn cross(a vec2, b vec2) f32 {
    a.x * b.y - a.y * b.x
}

// squared length
fn length_sq(v vec2) f32 {
    dot(v, v)
}

// squared length
fn length_sq(v vec3) f32 {
    dot(v, v)
}

// squared length
fn length_sq(v vec4) f32 {
    dot(v, v)
}

// Euclidean length
fn length(v vec2) f32 {
    sqrt(dot(v, v))
}

// Euclidean length
fn length(v vec3) f32 {
    sqrt(dot(v, v))
}

// Euclidean length
fn length(v vec4) f32 {
    sqrt(dot(v, v))
}

// distance between two points
fn distance(a vec2, b vec2) f32 {
    length(a - b)
}

// distance between two points
fn distance(a vec3, b vec3) f32 {
    length(a - b)
}

// distance between two points
fn distance(a vec4, b vec4) f32 {
    length(a - b)
}

// v scaled to length 1; the zero vector stays zero
fn normalize(v vec2) vec2 {
    l := dot(v, v)
    if l > 0.0 { v / sqrt(l) } else { vec2(0.0) }
}

// v scaled to length 1; the zero vector stays zero
fn normalize(v vec3) vec3 {
    l := dot(v, v)
    if l > 0.0 { v / sqrt(l) } else { vec3(0.0) }
}

// v scaled to length 1; the zero vector stays zero
fn normalize(v vec4) vec4 {
    l := dot(v, v)
    if l > 0.0 { v / sqrt(l) } else { vec4(0.0) }
}

// a at t = 0, b at t = 1
fn lerp(a vec2, b vec2, t f32) vec2 {
    a + (b - a) * t
}

// a at t = 0, b at t = 1
fn lerp(a vec3, b vec3, t f32) vec3 {
    a + (b - a) * t
}

// a at t = 0, b at t = 1
fn lerp(a vec4, b vec4, t f32) vec4 {
    a + (b - a) * t
}

// lane-wise minimum
fn min(a vec2, b vec2) vec2 {
    fmin(a, b)
}

// lane-wise minimum
fn min(a vec3, b vec3) vec3 {
    fmin(a, b)
}

// lane-wise minimum
fn min(a vec4, b vec4) vec4 {
    fmin(a, b)
}

// lane-wise maximum
fn max(a vec2, b vec2) vec2 {
    fmax(a, b)
}

// lane-wise maximum
fn max(a vec3, b vec3) vec3 {
    fmax(a, b)
}

// lane-wise maximum
fn max(a vec4, b vec4) vec4 {
    fmax(a, b)
}

// every lane limited to [lo, hi]
fn clamp(v vec2, lo vec2, hi vec2) vec2 {
    fmin(fmax(v, lo), hi)
}

// every lane limited to [lo, hi]
fn clamp(v vec3, lo vec3, hi vec3) vec3 {
    fmin(fmax(v, lo), hi)
}

// every lane limited to [lo, hi]
fn clamp(v vec4, lo vec4, hi vec4) vec4 {
    fmin(fmax(v, lo), hi)
}

// lane-wise absolute value
fn abs(v vec2) vec2 {
    fabs(v)
}

// lane-wise absolute value
fn abs(v vec3) vec3 {
    fabs(v)
}

// lane-wise absolute value
fn abs(v vec4) vec4 {
    fabs(v)
}

// lane-wise floor
fn floor(v vec2) vec2 {
    vec2(floor(v.x), floor(v.y))
}

// lane-wise floor
fn floor(v vec3) vec3 {
    vec3(floor(v.x), floor(v.y), floor(v.z))
}

// lane-wise floor
fn floor(v vec4) vec4 {
    vec4(floor(v.x), floor(v.y), floor(v.z), floor(v.w))
}

// lane-wise ceil
fn ceil(v vec2) vec2 {
    vec2(ceil(v.x), ceil(v.y))
}

// lane-wise ceil
fn ceil(v vec3) vec3 {
    vec3(ceil(v.x), ceil(v.y), ceil(v.z))
}

// lane-wise ceil
fn ceil(v vec4) vec4 {
    vec4(ceil(v.x), ceil(v.y), ceil(v.z), ceil(v.w))
}

// lane-wise v - floor(v)
fn fract(v vec2) vec2 {
    v - floor(v)
}

// lane-wise v - floor(v)
fn fract(v vec3) vec3 {
    v - floor(v)
}

// lane-wise v - floor(v)
fn fract(v vec4) vec4 {
    v - floor(v)
}

// smallest lane
fn min_component(v vec2) f32 {
    fmin(v.x, v.y)
}

// smallest lane
fn min_component(v vec3) f32 {
    fmin(fmin(v.x, v.y), v.z)
}

// smallest lane
fn min_component(v vec4) f32 {
    m := fmin(v.xy, v.zw)
    fmin(m.x, m.y)
}

// largest lane
fn max_component(v vec2) f32 {
    fmax(v.x, v.y)
}

// largest lane
fn max_component(v vec3) f32 {
    fmax(fmax(v.x, v.y), v.z)
}

// largest lane
fn max_component(v vec4) f32 {
    m := fmax(v.xy, v.zw)
    fmax(m.x, m.y)
}

// v mirrored at the plane with unit normal n
fn reflect(v vec2, n vec2) vec2 {
    v - n * (2.0 * dot(v, n))
}

// v mirrored at the plane with unit normal n
fn reflect(v vec3, n vec3) vec3 {
    v - n * (2.0 * dot(v, n))
}

// unit v refracted at the surface with unit normal n, eta = ratio of refraction indices; zero on total internal reflection
fn refract(v vec2, n vec2, eta f32) vec2 {
    d := dot(n, v)
    k := 1.0 - eta * eta * (1.0 - d * d)
    if k < 0.0 { vec2(0.0) } else { v * eta - n * (eta * d + sqrt(k)) }
}

// unit v refracted at the surface with unit normal n, eta = ratio of refraction indices; zero on total internal reflection
fn refract(v vec3, n vec3, eta f32) vec3 {
    d := dot(n, v)
    k := 1.0 - eta * eta * (1.0 - d * d)
    if k < 0.0 { vec3(0.0) } else { v * eta - n * (eta * d + sqrt(k)) }
}

// the part of a that points along b (zero if b is zero)
fn project(a vec2, b vec2) vec2 {
    l := dot(b, b)
    if l > 0.0 { b * (dot(a, b) / l) } else { vec2(0.0) }
}

// the part of a that points along b (zero if b is zero)
fn project(a vec3, b vec3) vec3 {
    l := dot(b, b)
    if l > 0.0 { b * (dot(a, b) / l) } else { vec3(0.0) }
}

// unsigned angle between a and b in [0, PI]
fn angle_between(a vec2, b vec2) f32 {
    atan2(fabs(cross(a, b)), dot(a, b))
}

// unsigned angle between a and b in [0, PI]
fn angle_between(a vec3, b vec3) f32 {
    atan2(length(cross(a, b)), dot(a, b))
}

// v turned 90 degrees counter-clockwise
fn perp(v vec2) vec2 {
    vec2(-v.y, v.x)
}

// v turned counter-clockwise by angle
fn rotate(v vec2, angle f32) vec2 {
    s, c := sin_cos(angle)
    v * c + perp(v) * s
}

// every lane within EPSILON * max(1, largest magnitude)
fn approx_eq(a vec2, b vec2) bool {
    max_component(fabs(a - b)) <= EPSILON * fmax(1.0, max_component(fmax(fabs(a), fabs(b))))
}

// every lane within EPSILON * max(1, largest magnitude)
fn approx_eq(a vec3, b vec3) bool {
    max_component(fabs(a - b)) <= EPSILON * fmax(1.0, max_component(fmax(fabs(a), fabs(b))))
}

// every lane within EPSILON * max(1, largest magnitude)
fn approx_eq(a vec4, b vec4) bool {
    max_component(fabs(a - b)) <= EPSILON * fmax(1.0, max_component(fmax(fabs(a), fabs(b))))
}

// every lane within eps
fn approx_eq(a vec2, b vec2, eps f32) bool {
    max_component(fabs(a - b)) <= eps
}

// every lane within eps
fn approx_eq(a vec3, b vec3, eps f32) bool {
    max_component(fabs(a - b)) <= eps
}

// every lane within eps
fn approx_eq(a vec4, b vec4, eps f32) bool {
    max_component(fabs(a - b)) <= eps
}

// ---------- quaternions (rotate a vector with q * v, compose with a * b: b first) ----------

// the rotation that does nothing
fn quat_identity() quat {
    quat(0.0, 0.0, 0.0, 1.0)
}

// rotation by angle around axis (right-hand rule; axis need not be normalised)
fn quat_axis_angle(axis vec3, angle f32) quat {
    s, c := sin_cos(angle * 0.5)
    quat(normalize(axis) * s, c)
}

// rotation from Euler angles: roll around Z first, then pitch around X, then yaw around Y
fn quat_euler(pitch f32, yaw f32, roll f32) quat {
    sx, cx := sin_cos(pitch * 0.5)
    sy, cy := sin_cos(yaw * 0.5)
    sz, cz := sin_cos(roll * 0.5)
    quat(cy * sx * cz + sy * cx * sz, sy * cx * cz - cy * sx * sz, cy * cx * sz - sy * sx * cz, cy * cx * cz + sy * sx * sz)
}

// four-component dot product
fn dot(a quat, b quat) f32 {
    dot(vec4(a), vec4(b))
}

// q scaled to unit length; the zero quaternion becomes the identity
fn normalize(q quat) quat {
    l := dot(q, q)
    if l > 0.0 { quat(vec4(q) / sqrt(l)) } else { quat_identity() }
}

// the opposite rotation of a unit quaternion
fn conjugate(q quat) quat {
    quat(-q.xyz, q.w)
}

// the opposite rotation (q need not be normalised)
fn inverse(q quat) quat {
    quat(vec4(-q.xyz, q.w) / dot(q, q))
}

// normalised linear interpolation along the shorter arc: cheap, not constant speed
fn nlerp(a quat, b quat, t f32) quat {
    va := vec4(a)
    vb := vec4(b)
    if dot(va, vb) < 0.0 {
        vb = -vb
    }
    normalize(quat(va + (vb - va) * t))
}

// spherical interpolation along the shorter arc at constant angular speed
fn slerp(a quat, b quat, t f32) quat {
    va := vec4(a)
    vb := vec4(b)
    d := dot(va, vb)
    if d < 0.0 {
        vb = -vb
        d = -d
    }
    if d > 0.9995 {
        return normalize(quat(va + (vb - va) * t))
    }
    th := acos(d)
    quat((va * sin((1.0 - t) * th) + vb * sin(t * th)) / sin(th))
}

// the rotation whose matrix has the orthonormal columns x, y, z
fn __quat_from_axes(x vec3, y vec3, z vec3) quat {
    tr := x.x + y.y + z.z
    if tr > 0.0 {
        s := sqrt(tr + 1.0) * 2.0
        return quat((y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, 0.25 * s)
    }
    if x.x > y.y && x.x > z.z {
        s := sqrt(1.0 + x.x - y.y - z.z) * 2.0
        return quat(0.25 * s, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s)
    }
    if y.y > z.z {
        s := sqrt(1.0 + y.y - x.x - z.z) * 2.0
        return quat((y.x + x.y) / s, 0.25 * s, (z.y + y.z) / s, (z.x - x.z) / s)
    }
    s := sqrt(1.0 + z.z - x.x - y.y) * 2.0
    quat((z.x + x.z) / s, (z.y + y.z) / s, 0.25 * s, (x.y - y.x) / s)
}

// the rotation that turns -Z into forward and keeps +Y as close to up as possible
fn quat_look_rotation(forward vec3, up vec3) quat {
    f := normalize(forward)
    r := cross(f, up)
    if length_sq(r) < 1e-12 {
        // forward is parallel to up: any roll will do
        r = cross(f, if fabs(f.y) < 0.9 { vec3(0.0, 1.0, 0.0) } else { vec3(1.0, 0.0, 0.0) })
    }
    r = normalize(r)
    __quat_from_axes(r, cross(r, f), -f)
}

// (pitch, yaw, roll) of a unit quaternion, the inverse of quat_euler; pitch is in [-PI/2, PI/2]
fn to_euler(q quat) vec3 {
    sp := 2.0 * (q.w * q.x - q.y * q.z)
    if fabs(sp) > 0.99999 {
        // looking straight up or down: yaw and roll turn around the same axis, report it as yaw
        return vec3(if sp > 0.0 { HALF_PI } else { -HALF_PI }, atan2(2.0 * (q.w * q.y - q.x * q.z), 1.0 - 2.0 * (q.y * q.y + q.z * q.z)), 0.0)
    }
    vec3(asin(sp), atan2(2.0 * (q.x * q.z + q.w * q.y), 1.0 - 2.0 * (q.x * q.x + q.y * q.y)), atan2(2.0 * (q.x * q.y + q.w * q.z), 1.0 - 2.0 * (q.x * q.x + q.z * q.z)))
}

// (axis, angle) of a unit quaternion, angle in [0, TAU]; the identity gives the X axis and 0
fn axis_angle(q quat) (vec3, f32) {
    l := length(q.xyz)
    if l == 0.0 {
        return (vec3(1.0, 0.0, 0.0), 0.0)
    }
    (q.xyz / l, 2.0 * atan2(l, q.w))
}

// every component within EPSILON (q and -q, the same rotation, are not considered equal)
fn approx_eq(a quat, b quat) bool {
    approx_eq(vec4(a), vec4(b))
}

// every component within eps
fn approx_eq(a quat, b quat, eps f32) bool {
    approx_eq(vec4(a), vec4(b), eps)
}

// ---------- matrices ----------

// the matrix that changes nothing
fn mat4_identity() mat4 {
    mat4(1.0)
}

// translation by v
fn translate(v vec3) mat4 {
    m := mat4(1.0)
    m[3] = vec4(v, 1.0)
    m
}

// scaling by v.x, v.y, v.z along the axes
fn scale(v vec3) mat4 {
    mat4(vec4(v.x, 0.0, 0.0, 0.0), vec4(0.0, v.y, 0.0, 0.0), vec4(0.0, 0.0, v.z, 0.0), vec4(0.0, 0.0, 0.0, 1.0))
}

// rotation around the X axis
fn rotate_x(angle f32) mat4 {
    s, c := sin_cos(angle)
    mat4(vec4(1.0, 0.0, 0.0, 0.0), vec4(0.0, c, s, 0.0), vec4(0.0, -s, c, 0.0), vec4(0.0, 0.0, 0.0, 1.0))
}

// rotation around the Y axis
fn rotate_y(angle f32) mat4 {
    s, c := sin_cos(angle)
    mat4(vec4(c, 0.0, -s, 0.0), vec4(0.0, 1.0, 0.0, 0.0), vec4(s, 0.0, c, 0.0), vec4(0.0, 0.0, 0.0, 1.0))
}

// rotation around the Z axis
fn rotate_z(angle f32) mat4 {
    s, c := sin_cos(angle)
    mat4(vec4(c, s, 0.0, 0.0), vec4(-s, c, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0))
}

// rotation matrix of a unit quaternion
fn mat4_from_quat(q quat) mat4 {
    d := q.xyz * 2.0
    a := d * q.x
    b := d * q.y
    c := d * q.z
    w := d * q.w
    mat4(vec4(1.0 - (b.y + c.z), a.y + w.z, a.z - w.y, 0.0), vec4(a.y - w.z, 1.0 - (a.x + c.z), b.z + w.x, 0.0), vec4(a.z + w.y, b.z - w.x, 1.0 - (a.x + b.y), 0.0), vec4(0.0, 0.0, 0.0, 1.0))
}

// rotation by angle around axis
fn rotate_axis(axis vec3, angle f32) mat4 {
    mat4_from_quat(quat_axis_angle(axis, angle))
}

// translation * rotation * scale: the usual object-to-world matrix
fn mat4_trs(t vec3, r quat, s vec3) mat4 {
    m := mat4_from_quat(r)
    mat4(m[0] * s.x, m[1] * s.y, m[2] * s.z, vec4(t, 1.0))
}

// rows and columns exchanged
fn transpose(m mat4) mat4 {
    a := m[0]
    b := m[1]
    c := m[2]
    d := m[3]
    mat4(vec4(a.x, b.x, c.x, d.x), vec4(a.y, b.y, c.y, d.y), vec4(a.z, b.z, c.z, d.z), vec4(a.w, b.w, c.w, d.w))
}

// 2x2 minors of the rows (x, y) of the columns a, b, c, d: ab ac ad in the first vector, bc bd cd in the second
fn __minors(a vec2, b vec2, c vec2, d vec2) (vec3, vec3) {
    (vec3(cross(a, b), cross(a, c), cross(a, d)), vec3(cross(b, c), cross(b, d), cross(c, d)))
}

// determinant
fn determinant(m mat4) f32 {
    s, t := __minors(m[0].xy, m[1].xy, m[2].xy, m[3].xy)
    c, e := __minors(m[0].zw, m[1].zw, m[2].zw, m[3].zw)
    dot(s, e.zyx) - 2.0 * s.y * e.y + dot(t, c.zyx) - 2.0 * t.y * c.y
}

// one column of the adjugate from a row of the matrix and the minors of the two rows that are neither it nor its partner
fn __adj_col(r vec4, k0 vec4, k1 vec4, k2 vec4) vec4 {
    r.yxxx * k0 + r.zzyy * k1 + r.wwwz * k2
}

// inverse of any invertible matrix; a singular matrix (determinant 0) gives the zero matrix
fn inverse(m mat4) mat4 {
    s, t := __minors(m[0].xy, m[1].xy, m[2].xy, m[3].xy)
    c, e := __minors(m[0].zw, m[1].zw, m[2].zw, m[3].zw)
    det := dot(s, e.zyx) - 2.0 * s.y * e.y + dot(t, c.zyx) - 2.0 * t.y * c.y
    if det == 0.0 {
        return mat4(0.0)
    }
    r := transpose(m)
    k0 := vec4(e.z, -e.z, e.y, -e.x)
    k1 := vec4(-e.y, c.z, -c.z, c.y)
    k2 := vec4(e.x, -c.y, c.x, -c.x)
    j0 := vec4(t.z, -t.z, t.y, -t.x)
    j1 := vec4(-t.y, s.z, -s.z, s.y)
    j2 := vec4(t.x, -s.y, s.x, -s.x)
    i := 1.0 / det
    mat4(__adj_col(r[1], k0, k1, k2) * i, __adj_col(r[0], k0, k1, k2) * -i, __adj_col(r[3], j0, j1, j2) * i, __adj_col(r[2], j0, j1, j2) * -i)
}

// inverse of an affine matrix (last row 0 0 0 1: any mix of rotation, scale, shear and translation); cheaper than inverse
fn inverse_affine(m mat4) mat4 {
    a := m[0].xyz
    b := m[1].xyz
    c := m[2].xyz
    t := m[3].xyz
    i := 1.0 / dot(a, cross(b, c))
    r0 := cross(b, c) * i
    r1 := cross(c, a) * i
    r2 := cross(a, b) * i
    mat4(vec4(r0.x, r1.x, r2.x, 0.0), vec4(r0.y, r1.y, r2.y, 0.0), vec4(r0.z, r1.z, r2.z, 0.0), vec4(-dot(r0, t), -dot(r1, t), -dot(r2, t), 1.0))
}

// view matrix of a camera at eye looking at target (view space: +X right, +Y up, -Z forward)
fn look_at(eye vec3, target vec3, up vec3) mat4 {
    f := normalize(target - eye)
    s := normalize(cross(f, up))
    u := cross(s, f)
    mat4(vec4(s.x, u.x, -f.x, 0.0), vec4(s.y, u.y, -f.y, 0.0), vec4(s.z, u.z, -f.z, 0.0), vec4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1.0))
}

// perspective projection: vertical field of view fovy (radians), aspect = width / height, clip depth 0 at near and 1 at far, +Y up (D3D, Metal)
fn perspective(fovy f32, aspect f32, near f32, far f32) mat4 {
    f := 1.0 / tan(fovy * 0.5)
    mat4(vec4(f / aspect, 0.0, 0.0, 0.0), vec4(0.0, f, 0.0, 0.0), vec4(0.0, 0.0, far / (near - far), -1.0), vec4(0.0, 0.0, near * far / (near - far), 0.0))
}

// perspective with Y flipped, for Vulkan (whose clip space has +Y pointing down)
fn perspective_vk(fovy f32, aspect f32, near f32, far f32) mat4 {
    m := perspective(fovy, aspect, near, far)
    m[1] = -m[1]
    m
}

// orthographic projection of the box left..right, bottom..top, near..far (distances along -Z), clip depth 0..1
fn ortho(left f32, right f32, bottom f32, top f32, near f32, far f32) mat4 {
    mat4(vec4(2.0 / (right - left), 0.0, 0.0, 0.0), vec4(0.0, 2.0 / (top - bottom), 0.0, 0.0), vec4(0.0, 0.0, 1.0 / (near - far), 0.0), vec4((left + right) / (left - right), (bottom + top) / (bottom - top), near / (near - far), 1.0))
}

// m applied to the point p (w = 1, no perspective divide)
fn transform_point(m mat4, p vec3) vec3 {
    (m * vec4(p, 1.0)).xyz
}

// m applied to the point p followed by the perspective divide (world to clip-space coordinates)
fn project_point(m mat4, p vec3) vec3 {
    c := m * vec4(p, 1.0)
    c.xyz / c.w
}

// m applied to the direction d (w = 0: translation is ignored)
fn transform_dir(m mat4, d vec3) vec3 {
    (m * vec4(d, 0.0)).xyz
}

// every element within EPSILON * max(1, largest magnitude of its column)
fn approx_eq(a mat4, b mat4) bool {
    approx_eq(a[0], b[0]) && approx_eq(a[1], b[1]) && approx_eq(a[2], b[2]) && approx_eq(a[3], b[3])
}

// every element within eps
fn approx_eq(a mat4, b mat4, eps f32) bool {
    approx_eq(a[0], b[0], eps) && approx_eq(a[1], b[1], eps) && approx_eq(a[2], b[2], eps) && approx_eq(a[3], b[3], eps)
}

// ---------- geometry ----------

// axis-aligned box
struct Aabb { min vec3, max vec3 }

// half-line: the points origin + dir * t for t >= 0
struct Ray { origin vec3, dir vec3 }

// the points p with dot(normal, p) == d; normal has unit length
struct Plane { normal vec3, d f32 }

struct Sphere { center vec3, radius f32 }

// smallest box around both
fn aabb_union(a Aabb, b Aabb) Aabb {
    Aabb{fmin(a.min, b.min), fmax(a.max, b.max)}
}

// is p inside or on the box?
fn contains(b Aabb, p vec3) bool {
    min_component(fmin(p - b.min, b.max - p)) >= 0.0
}

// is p inside or on the sphere?
fn contains(s Sphere, p vec3) bool {
    length_sq(p - s.center) <= s.radius * s.radius
}

// do the boxes overlap or touch?
fn intersects(a Aabb, b Aabb) bool {
    min_component(fmin(a.max - b.min, b.max - a.min)) >= 0.0
}

// do the spheres overlap or touch?
fn intersects(a Sphere, b Sphere) bool {
    r := a.radius + b.radius
    length_sq(a.center - b.center) <= r * r
}

// the point of the box nearest to p (p itself when inside)
fn closest_point(b Aabb, p vec3) vec3 {
    fmin(fmax(p, b.min), b.max)
}

// the point of the sphere's surface nearest to p (the center when p is the center)
fn closest_point(s Sphere, p vec3) vec3 {
    s.center + normalize(p - s.center) * s.radius
}

// the point of the plane nearest to p
fn closest_point(pl Plane, p vec3) vec3 {
    p - pl.normal * (dot(pl.normal, p) - pl.d)
}

// the point of the ray nearest to p
fn closest_point(r Ray, p vec3) vec3 {
    r.origin + r.dir * fmax(dot(p - r.origin, r.dir) / dot(r.dir, r.dir), 0.0)
}

// where the ray enters the box: (t, true) with the hit at origin + dir * t, t = 0 if it starts inside; (_, false) on a miss
fn ray_hit(r Ray, b Aabb) (f32, bool) {
    inv := vec3(1.0) / r.dir
    t0 := (b.min - r.origin) * inv
    t1 := (b.max - r.origin) * inv
    near := fmax(max_component(fmin(t0, t1)), 0.0)
    (near, min_component(fmax(t0, t1)) >= near)
}

// first point where the ray meets the sphere's surface: (t, true) with the hit at origin + dir * t; (_, false) on a miss
fn ray_hit(r Ray, s Sphere) (f32, bool) {
    oc := r.origin - s.center
    a := dot(r.dir, r.dir)
    b := dot(oc, r.dir)
    disc := b * b - a * (dot(oc, oc) - s.radius * s.radius)
    if disc < 0.0 {
        return (0.0, false)
    }
    q := sqrt(disc)
    t := (-b - q) / a
    if t < 0.0 {
        // the origin is inside: the exit point
        t = (q - b) / a
    }
    (t, t >= 0.0)
}

// where the ray crosses the plane: (t, true) with the hit at origin + dir * t; (_, false) if it is parallel or points away
fn ray_hit(r Ray, pl Plane) (f32, bool) {
    dn := dot(pl.normal, r.dir)
    if dn == 0.0 {
        return (0.0, false)
    }
    t := (pl.d - dot(pl.normal, r.origin)) / dn
    (t, t >= 0.0)
}

// ---------- easing: t in [0, 1] -> [0, 1], f(0) = 0, f(1) = 1 ----------

// slow start
fn ease_in_quad(t f32) f32 {
    t * t
}

// slow end
fn ease_out_quad(t f32) f32 {
    t * (2.0 - t)
}

// slow start and end
fn ease_in_out_quad(t f32) f32 {
    if t < 0.5 {
        return 2.0 * t * t
    }
    u := 1.0 - t
    1.0 - 2.0 * u * u
}

// slower start
fn ease_in_cubic(t f32) f32 {
    t * t * t
}

// slower end
fn ease_out_cubic(t f32) f32 {
    u := 1.0 - t
    1.0 - u * u * u
}

// slower start and end
fn ease_in_out_cubic(t f32) f32 {
    if t < 0.5 {
        return 4.0 * t * t * t
    }
    u := 1.0 - t
    1.0 - 4.0 * u * u * u
}

// overshoots and oscillates around 1 before settling
fn ease_out_elastic(t f32) f32 {
    if t <= 0.0 || t >= 1.0 {
        return saturate(t)
    }
    exp(t * -6.931472) * sin((t * 10.0 - 0.75) * 2.0943952) + 1.0
}

// bounces off 1 three times, like a dropped ball
fn ease_out_bounce(t f32) f32 {
    if t < 0.36363637 {
        return 7.5625 * t * t
    }
    if t < 0.72727275 {
        u := t - 0.54545456
        return 7.5625 * u * u + 0.75
    }
    if t < 0.90909094 {
        u := t - 0.8181818
        return 7.5625 * u * u + 0.9375
    }
    u := t - 0.95454544
    7.5625 * u * u + 0.984375
}

// overshoots 1 by about 10% and comes back
fn ease_out_back(t f32) f32 {
    u := t - 1.0
    1.0 + u * u * (2.70158 * u + 1.70158)
}

// ---------- colour (rgb / rgba lanes in 0..1) ----------

// rgb to (hue, saturation, value), all in 0..1 (hue 0 = red, 1/3 = green, 2/3 = blue)
fn rgb_to_hsv(c vec3) vec3 {
    v := max_component(c)
    d := v - min_component(c)
    if d <= 0.0 {
        return vec3(0.0, 0.0, v)
    }
    h := (c.x - c.y) / d + 4.0
    if v == c.x {
        h = (c.y - c.z) / d
        if h < 0.0 {
            h += 6.0
        }
    } else if v == c.y {
        h = (c.z - c.x) / d + 2.0
    }
    vec3(h / 6.0, d / v, v)
}

// (hue, saturation, value) to rgb; hue wraps around
fn hsv_to_rgb(c vec3) vec3 {
    p := fabs(fract(vec3(c.x) + vec3(1.0, 0.6666667, 0.33333334)) * 6.0 - 3.0)
    k := fmin(fmax(p - 1.0, vec3(0.0)), vec3(1.0))
    (vec3(1.0) + (k - 1.0) * c.y) * c.z
}

// one sRGB-encoded channel to linear light
fn srgb_to_linear(x f32) f32 {
    if x <= 0.04045 { x / 12.92 } else { pow((x + 0.055) / 1.055, 2.4) }
}

// one linear-light channel to sRGB encoding
fn linear_to_srgb(x f32) f32 {
    if x <= 0.0031308 { x * 12.92 } else { 1.055 * pow(x, 0.41666666) - 0.055 }
}

// sRGB-encoded colour to linear light (do lighting and blending in linear)
fn srgb_to_linear(c vec3) vec3 {
    vec3(srgb_to_linear(c.x), srgb_to_linear(c.y), srgb_to_linear(c.z))
}

// linear-light colour to sRGB encoding (for display or 8-bit storage)
fn linear_to_srgb(c vec3) vec3 {
    vec3(linear_to_srgb(c.x), linear_to_srgb(c.y), linear_to_srgb(c.z))
}

// rgba packed as RGBA8 with red in the lowest byte (R8G8B8A8 in memory); lanes are clamped to 0..1 and rounded
fn color_u32(c vec4) u32 {
    b := fmin(fmax(c, vec4(0.0)), vec4(1.0)) * 255.0 + 0.5
    u32(b.x) | u32(b.y) << 8 | u32(b.z) << 16 | u32(b.w) << 24
}

// the inverse of color_u32
fn color_vec4(c u32) vec4 {
    vec4(f32(c & 0xFF), f32((c >> 8) & 0xFF), f32((c >> 16) & 0xFF), f32(c >> 24)) * 0.003921569
}
