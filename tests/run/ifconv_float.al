// if-conversion of float values: min / max shapes (minsd / maxsd keep the operand order: NaN
// and the signed zeros come out exactly as the source writes them), x against zero choosing x
// or -x, and the general select (a compare mask and a blend), for f64 and f32, with float and
// integer conditions. The bits are printed, so -0.0 and the NaN's sign show.
noinline fn lt_a(x: f64, y: f64) -> f64 { if x < y { x } else { y } }
noinline fn lt_b(x: f64, y: f64) -> f64 { if x < y { y } else { x } }
noinline fn gt_a(x: f64, y: f64) -> f64 { if x > y { x } else { y } }
noinline fn gt_b(x: f64, y: f64) -> f64 { if x > y { y } else { x } }
// not min / max: <= and >= differ from them for NaN or for equal zeros
noinline fn le_a(x: f64, y: f64) -> f64 { if x <= y { x } else { y } }
noinline fn ge_a(x: f64, y: f64) -> f64 { if x >= y { x } else { y } }
noinline fn eq_a(x: f64, y: f64) -> f64 { if x == y { 1.5 } else { y } }
noinline fn ne_a(x: f64, y: f64) -> f64 { if x != y { x } else { -2.5 } }
noinline fn clamp(x: f64, lo: f64, hi: f64) -> f64 { if x < lo { lo } else if x > hi { hi } else { x } }
// x against zero
noinline fn abs1(x: f64) -> f64 { if x < 0.0 { -x } else { x } }
noinline fn abs2(x: f64) -> f64 { if x > 0.0 { x } else { -x } }
noinline fn nabs1(x: f64) -> f64 { if x > 0.0 { -x } else { x } }
noinline fn nabs2(x: f64) -> f64 { if x < 0.0 { x } else { -x } }
noinline fn abs3(x: f64) -> f64 { if 0.0 > x { -x } else { x } }
noinline fn abs4(x: f64) -> f64 { if x < -0.0 { -x } else { x } }
noinline fn negsel(x: f64, y: f64) -> f64 { if x < y { -x } else { x } }
noinline fn sign(x: f64) -> f64 { if x > 0.0 { 1.0 } else if x < 0.0 { -1.0 } else { 0.0 } }
noinline fn zero_t(x: f64, y: f64) -> f64 { if x < y { 0.0 } else { y } }
noinline fn zero_e(x: f64, y: f64) -> f64 { if x < y { x } else { 0.0 } }
noinline fn mzero_e(x: f64, y: f64) -> f64 { if x < y { x } else { -0.0 } }
noinline fn arith(x: f64, y: f64) -> f64 { if x > y { x - y } else { y * 2.0 + x } }
// an integer condition choosing floats; an f32 compare choosing f64 values
noinline fn intc(i: i64, x: f64, y: f64) -> f64 { if i & 1 == 0 { x } else { y } }
noinline fn mixed(a: f32, b: f32, x: f64, y: f64) -> f64 { if a < b { x } else { y } }
// f32
noinline fn lt32(x: f32, y: f32) -> f32 { if x < y { x } else { y } }
noinline fn gt32(x: f32, y: f32) -> f32 { if x > y { y } else { x } }
noinline fn abs32(x: f32) -> f32 { if x < 0.0 { -x } else { x } }
noinline fn sel32(x: f32, y: f32) -> f32 { if x >= y { x + 1.0 } else { y } }
noinline fn nabs32(x: f32) -> f32 { if x > 0.0 { x } else { -x } }

fn b(x: f64) -> u64 { cast[u64](x) }
fn b32(x: f32) -> u32 { cast[u32](x) }

fn main() {
    nan: f64 = 0.0 / 0.0
    mnan := -nan
    vals := [8]f64{1.0, -2.0, 0.0, -0.0, nan, mnan, 3.5, -0.5}
    for x in vals {
        for y in vals {
            print(b(lt_a(x, y)), b(lt_b(x, y)), b(gt_a(x, y)), b(gt_b(x, y)), b(le_a(x, y)), b(ge_a(x, y)), b(eq_a(x, y)), b(ne_a(x, y)))
            print(b(negsel(x, y)), b(zero_t(x, y)), b(zero_e(x, y)), b(mzero_e(x, y)), b(arith(x, y)), b(clamp(x, y, 2.0)), b(clamp(x, -1.0, y)))
        }
        print(b(abs1(x)), b(abs2(x)), b(nabs1(x)), b(nabs2(x)), b(abs3(x)), b(abs4(x)), b(sign(x)))
    }
    for i in 0..4 {
        print(b(intc(i, 1.25, -0.0)), b(intc(i, nan, 2.0)), b(mixed(f32(i), 1.5, 7.0, -0.0)), b(mixed(f32(nan), f32(i), 7.0, 8.0)))
    }
    v32 := [6]f32{1.0, -2.0, 0.0, -0.0, f32(nan), f32(mnan)}
    for x in v32 {
        for y in v32 {
            print(b32(lt32(x, y)), b32(gt32(x, y)), b32(sel32(x, y)))
        }
        print(b32(abs32(x)), b32(nabs32(x)))
    }
}
