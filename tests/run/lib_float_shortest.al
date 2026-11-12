// Powers of two have a closer neighbour below: the shortest text may lie above the value
// even when a nearer text of the same length lies below it, outside the rounding interval.
fn main() {
    print(cast[f64](u64(0x0060000000000000)), cast[f64](u64(0x2800000000000000)), cast[f64](u64(0x0010000000000000)))
    print(cast[f32](u32(0x0f800000)), cast[f32](u32(0x6b000000)), cast[f32](u32(0x6c800000)))
    // fixed notation keeps every requested digit (exact up to 1074 places, zeros after them)
    a := fmtf(5e-324, 1080)
    print(len(a), a[1060..], len(fmtf(-1.5, 1500)), fmtf(1.0 / 0.0, 2000))
}
