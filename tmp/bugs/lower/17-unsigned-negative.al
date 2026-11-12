// a negative literal for an unsigned type, and an untyped decimal constant beyond i64
const B = 18446744073709551615
const C = 200
const N = -1
fn main() {
    a: u8 = -1
    b: u64 = -5
    c: i8 = C
    d: u32 = N
    ok1 := u64(-1)
    ok2: u8 = 0xFF
    ok3 := u8(-1)
    print(a, b, c, d, ok1, ok2, ok3, B)
}
