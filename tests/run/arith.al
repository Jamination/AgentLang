main :: () {
    a := 17
    b := 5
    print(a + b, a - b, a * b, a / b, a % b)
    print(-a / b, -a % b)
    print(a & b, a | b, a ^ b, ~a, a << 2, a >> 1)
    x: u8 = 250
    x += 10
    print(x)
    y: i8 = 127
    y += 1
    print(y)
    z: u32 = 0xFFFFFFFF
    z += 1
    print(z)
    w: i64 = 0x7FFFFFFFFFFFFFFF
    w += 1
    print(w)
    print(u64(w))
    print(7 / 2, -7 / 2, 7 % -2, u64(7) / 2)
    print(1 << 40, i32(1) << 31, u8(1) << 9)
    f := 1.5
    print(f * 2.0, f / 4.0, f - 2.0, -f)
    print(i64(3.99), i64(-3.99), f64(7) / 2.0)
    print(10 > 3, 3 >= 3, 2 == 3, 2 != 3, !true)
    print(a > 10 && b < 3, a > 10 || b < 3)
    s: i16 = -300
    print(s / 7, s % 7, u16(s), i8(s), u8(s))
    big: u64 = 18446744073709551615
    print(big, big / 3, big % 10, big >> 60, i64(big))
    print(u32(big) >> 4, i32(-16) >> 2, u32(0x80000000) >> 31)
}
