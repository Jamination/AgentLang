fn get4(p []u8) u32 {
    u32(p[0]) | (u32(p[1]) << 8) | (u32(p[2]) << 16) | (u32(p[3]) << 24)
}
fn main() {
    b := []u8{1, 2, 3, 4, 5}
    print(get4(b), get4(b[1..]))
    print(get4(b[2..]))
}
