// A 32-bit shift or rotation by a count that is 0 (mod 32) leaves the register unchanged,
// upper half included; widening the result assumed the upper half was zero (-O0 printed
// 18446744073709551615 for the first line).
noinline fn shl_by(a: u32, n: u32) -> u64 { u64(a << n) }
noinline fn wide(a64: i64, n: i64) -> u64 { a := u32(a64); u64(rotl(a, n)) + u64(a >> n) }
fn main() {
    a := u32(4294967295)
    b := u32(0)
    print(a << b, a >> b, rotl(a, b), rotr(a, i64(b) + 32))
    c := i32(-1)
    print(u32(c << b), i64(u32(c >> b)))
    print(shl_by(4294967295, 0), shl_by(4294967295, 32), wide(-1, 0), wide(-1, 64))
}
