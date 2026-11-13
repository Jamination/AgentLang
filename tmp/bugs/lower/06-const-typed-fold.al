// expected (2nd line, run time): 18446744073709552000.0 15000000000000000000 9223372036854775807 true 9223372036854775807 2 56 55 -128 -64 0 0
// was: -1.0 9223372036854775807 0 false -1 -2 -200 -201 128 -1 0 255
const A: u64 = 0xFFFFFFFFFFFFFFFF
const B = f64(A)
const C = u64(1.5e19)
const I = A / 2
const J = A > 5
const K = A >> 1
const L: u64 = 0x8000000000000000
const M = L % 3
const G: u8 = 200
const NG = -G
const BG = ~G
const S8: i8 = -128
const SD = S8 / -1
const SH8 = S8 >> 9
const U32: u32 = 0x80000000
const U32S = U32 << 33
const CF = u8(1.0e30)
noinline fn id[T](x: T) -> T { x }
fn main() {
    print(B, C, I, J, K, M, NG, BG, SD, SH8, U32S, CF)
    a := id(A)
    g := id(G)
    s := id(S8)
    u := id(U32)
    print(f64(a), u64(id(f64(1.5e19))), a / 2, a > 5, a >> 1, id(L) % 3, -g, ~g, s / id(i8(-1)), s >> id(9), u << id(33), u8(id(f64(1.0e30))))
}
