// trunc / round / f32 floor and ceil keep the sign of a zero result and atan(-0.0) is -0.0, as
// in C (they used to return +0.0)
fn main() {
    x := -0.5
    y: f32 = -0.25
    nz := -0.0
    nz32: f32 = -0.0
    print(trunc(x), round(-0.4), trunc(nz), round(nz), atan(nz), atan2(nz, 1.0))
    print(trunc(y), round(y), ceil(y), floor(nz32), ceil(nz32), atan(nz32), fract(nz32))
    print(trunc(0.5), round(0.4), ceil(f32(-1.5)), floor(f32(-0.5)), round(f32(-0.5)), trunc(-7.9))
}
