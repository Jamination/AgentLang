// min / max with a NaN argument give NaN in either position (min(1.0, nan) used to be 1.0)
fn main() {
    nan := 0.0 / 0.0
    print(min(nan, 1.0), min(1.0, nan), max(nan, 1.0), max(1.0, nan))
    print(min(f32(nan), f32(2.0)), max(f32(2.0), f32(nan)), min(2.5, 1.5), max(-1.0, 3.0), min(2, -3), max(u8(2), 3))
}
