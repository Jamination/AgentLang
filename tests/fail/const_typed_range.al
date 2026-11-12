// typed constants and constant initialisers are checked like literals in functions
// (regression: silently truncated)
const U1: u8 = 256
const U2: i8 = -129
const U3: u32 = 1 << 32
const U4 = [2]u8{1, 300}
U5: u8 = 256
const N: i64 = 3
const U6 = [2]u8{N, 1}
const U7: f64 = N
const U8 = [2]f64{N, 1.0}
fn main() {
    print(U1, U2, U3, U4, U5, U6, U7, U8)
}
