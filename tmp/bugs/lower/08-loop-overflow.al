// range loops whose last value is at the top (bottom) of the type, or whose step jumps past it, never ended (the step overflowed); `by 256` on a u8 loop was a step of 0
// expected: a 3, b 3, c 4, d 6, e 1, f 3, g 2, h 3, i 4
noinline fn id[T](x: T) -> T { x }
fn main() {
    n := 0
    for i in id(0x7FFFFFFFFFFFFFFD)..=0x7FFFFFFFFFFFFFFF { n += 1; if n > 10 { break } }
    print("a", n)
    n = 0
    for i in id(0x7FFFFFFFFFFFFFF0)..0x7FFFFFFFFFFFFFFF by 7 { n += 1; if n > 10 { break } }
    print("b", n)
    n = 0
    for i in id(-0x7FFFFFFFFFFFFFFD)..=(-0x7FFFFFFFFFFFFFFF - 1) by -1 { n += 1; if n > 10 { break } }
    print("c", n)
    n = 0
    for i in id(u8(250))..=255 { n += 1; if n > 10 { break } }
    print("d", n)
    n = 0
    for i in id(u8(0))..=0 by -1 { n += 1; if n > 300 { break } }
    print("e", n)
    n = 0
    for i in id(i8(120))..=127 by 3 { n += 1; if n > 10 { break } }
    print("f", n)
    n = 0
    for i in id(u64(0xFFFFFFFFFFFFFFF0))..=0xFFFFFFFFFFFFFFFF by 8 { n += 1; if n > 10 { break } }
    print("g", n)
    n = 0
    for i in id(5)..=0 by -2 { put(i, " "); n += 1; if n > 10 { break } }
    print("h", n)
    n = 0
    for i in id(u8(3))..=0 by -1 { put(i, " "); n += 1; if n > 10 { break } }
    print("i", n)
    for i in id(10)..5 { print("never") }
    n = 0
    for i in id(0)..id(10) by id(3) { put(i, " ") }
    print()
    for i in id(i8(-128))..=-126 { put(i, " ") }
    print()
}
