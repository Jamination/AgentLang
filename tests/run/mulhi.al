// mulhi(a, b): the high half of the full product, signed or unsigned, for every integer width
fn ref_u64(a u64, b u64) u64 {
    a0 := a & 0xFFFFFFFF
    a1 := a >> 32
    b0 := b & 0xFFFFFFFF
    b1 := b >> 32
    t := a1 * b0 + ((a0 * b0) >> 32)
    u := a0 * b1 + (t & 0xFFFFFFFF)
    a1 * b1 + (t >> 32) + (u >> 32)
}

fn ref_i64(a i64, b i64) i64 {
    h := i64(ref_u64(u64(a), u64(b)))
    if a < 0 {
        h -= b
    }
    if b < 0 {
        h -= a
    }
    h
}

var seed u64 = 0x9E3779B97F4A7C15

fn rnd() u64 {
    seed ^= seed << 13
    seed ^= seed >> 7
    seed ^= seed << 17
    seed
}

fn hi_generic[T](a T, b T) T { mulhi(a, b) }

struct Fx { v i32 }
fn scale(f Fx, k i32) i32 { mulhi(f.v, k) }

const C64 = 0x123456789ABCDEF
const BIG u64 = 0xFFFFFFFFFFFFFFFF

fn main() {
    // constant operands (folded) and typical values
    print(mulhi(u64(1) << 63, u64(4)), mulhi(BIG, BIG), mulhi(i64(-1), i64(-1)), mulhi(i64(-1), i64(1)), mulhi(C64, C64))
    print(mulhi(u8(200), u8(200)), mulhi(i8(-100), i8(100)), mulhi(u16(65535), u16(65535)), mulhi(i16(-32768), i16(-32768)))
    print(mulhi(u32(0xFFFFFFFF), u32(0xFFFFFFFF)), mulhi(i32(-2147483648), i32(2147483647)), mulhi(i32(-2147483648), i32(-2147483648)))
    // an untyped literal takes the type of the other operand, or of the destination
    var x u32 = 3000000000
    var y u8 = mulhi(200, 3)
    var z i16 = mulhi(-300, 300)
    print(mulhi(x, 4), mulhi(4, x), y, z, mulhi(1 << 40, 1 << 40))
    // division by 10 through a multiplication
    n := u64(1234567890123456789)
    print(mulhi(n, 0xCCCCCCCCCCCCCCCD) >> 3, n / 10)
    // generics, methods, values from memory
    arr := [3]i64{-7, 9223372036854775807, -9223372036854775807 - 1}
    print(hi_generic(arr[1], arr[1]), hi_generic(arr[2], arr[2]), hi_generic(arr[0], arr[1]), hi_generic(u16(40000), u16(3)), Fx{v: 1 << 30}.scale(12), mulhi(x, x).hi_generic(x))
    // against a reference, all widths, random operands
    bad := 0
    for i in 0..20000 {
        a := rnd()
        b := rnd()
        if i % 7 == 0 { a = BIG - (a & 3) }
        if i % 11 == 0 { b = b & 7 }
        if i % 13 == 0 { a = u64(1) << 63 }
        if mulhi(a, b) != ref_u64(a, b) { bad += 1 }
        if mulhi(i64(a), i64(b)) != ref_i64(i64(a), i64(b)) { bad += 1 }
        if mulhi(u32(a), u32(b)) != u32((u64(u32(a)) * u64(u32(b))) >> 32) { bad += 1 }
        if mulhi(i32(a), i32(b)) != i32((i64(i32(a)) * i64(i32(b))) >> 32) { bad += 1 }
        if mulhi(u16(a), u16(b)) != u16((u64(u16(a)) * u64(u16(b))) >> 16) { bad += 1 }
        if mulhi(i16(a), i16(b)) != i16((i64(i16(a)) * i64(i16(b))) >> 16) { bad += 1 }
        if mulhi(u8(a), u8(b)) != u8((u64(u8(a)) * u64(u8(b))) >> 8) { bad += 1 }
        if mulhi(i8(a), i8(b)) != i8((i64(i8(a)) * i64(i8(b))) >> 8) { bad += 1 }
    }
    print("mismatches:", bad)
}
