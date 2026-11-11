noinline id8 :: (x: i8) -> i8 { x }
noinline idu8 :: (x: u8) -> u8 { x }
noinline id16 :: (x: i16) -> i16 { x }
noinline idu16 :: (x: u16) -> u16 { x }
noinline id32 :: (x: i32) -> i32 { x }
noinline idu32 :: (x: u32) -> u32 { x }
noinline id64 :: (x: i64) -> i64 { x }
noinline idu64 :: (x: u64) -> u64 { x }

main :: () {
    // wrap-around in every width (values pass through calls so nothing is folded)
    a8 := id8(100)
    b8 := id8(50)
    print(a8 + b8, a8 - b8 - b8 - b8 - b8, a8 * b8, a8 / id8(7), a8 % id8(7), -a8 / id8(7), -a8 % id8(7))
    au8 := idu8(200)
    bu8 := idu8(100)
    print(au8 + bu8, bu8 - au8, au8 * bu8, au8 / idu8(7), au8 % idu8(7), au8 >> 3, au8 << 3)
    a16 := id16(30000)
    print(a16 + id16(5000), a16 * id16(3), idu16(60000) + idu16(6000), idu16(1) - idu16(2), a16 >> 4, id16(-30000) >> 4)
    a32 := id32(2000000000)
    print(a32 + a32, a32 * id32(3), idu32(4000000000) + idu32(500000000), idu32(3) - idu32(5), id32(-8) / id32(3), id32(-8) % id32(3))
    a64 := id64(9000000000000000000)
    print(a64 + a64, a64 * id64(3), idu64(1) - idu64(2), id64(-9) / id64(2), id64(-9) % id64(2), idu64(18446744073709551615) / idu64(10))
    // comparisons are signed or unsigned by type
    print(id8(-1) < id8(1), idu8(255) < idu8(1), id32(-1) < id32(1), idu32(4294967295) < idu32(1), id64(-1) < id64(1), idu64(18446744073709551615) > idu64(1))
    // conversions
    x := id64(-2)
    print(u8(x), u16(x), u32(x), u64(x), i8(id64(200)), i16(id64(40000)), i32(id64(3000000000)), i64(idu8(200)), i64(id8(-56)), u64(id8(-56)), i64(idu32(4000000000)), i64(id32(-5)))
    // shifts: count is taken modulo the bit width
    s := id64(1)
    print(s << id64(63), s << id64(64), s << id64(65), id64(-16) >> id64(2), idu64(16) >> idu64(66), idu8(1) << idu8(9), id32(1) << id32(33), id8(-128) >> id8(7), idu16(0x8000) >> idu16(15))
    // bit operations
    v := idu64(0xF0F0F0F00F0F0F0F)
    print(popcnt(v), ctz(idu64(0x1000)), clz(idu64(0x1000)), bswap(idu64(0x0102030405060708)), rotl(idu32(0x80000001), idu32(4)), rotr(idu32(0x80000001), idu32(4)), popcnt(idu8(255)), ctz(idu32(0)), clz(idu16(1)), bswap(idu32(0x11223344)), bswap(idu16(0x1122)))
    print(v & 0xFF, v | 1, v ^ v, ~v, !(v == 0), ~id8(5), ~idu8(5))
    // mixed-width arithmetic needs explicit conversion
    w := i64(a8) * i64(a16) + i64(a32)
    print(w, i64(au8) + 1, f64(a8) / 3.0)
    // constants adapt to the other operand
    m: u8 = 3
    m = m * 100 + 50
    n: i16 = 300
    n = n * 200 - 1
    print(m, n, 0x7F + 1, 0b1010, 0o17, 1_000_000, 'A' + 1, '\n', '\x41')
}
