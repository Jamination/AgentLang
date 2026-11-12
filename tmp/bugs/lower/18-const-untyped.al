// untyped constants: an f32 use rounds the literal once; typed u64; hex bit patterns
const H = 1.00000005960464477539062500000001
const NH = -1.00000005960464477539062500000001
const B: u64 = 18446744073709551615
const M = 0xFF
const W = 0xFFFFFFFFFFFFFFFF
fn main() {
    x: f32 = H
    y: f32 = NH
    z: i8 = M
    w: u64 = W
    print(x, y, H, B, z, w, u64(-1), u8(-1))
}
