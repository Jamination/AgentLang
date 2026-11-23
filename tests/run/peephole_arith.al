// Instruction selection of arithmetic idioms: the carry out of an addition taken from its
// flags, multiplications by 2^n +- 1, narrow loads folded into narrow operations. Boundary
// values of every width, and near misses that are not carries.

// multi-limb addition, the carry as a select and as a conversion of the compare
noinline fn add_limbs(a: []u64, b: []u64, r: []u64) -> u64 {
    carry: u64 = 0
    for i in 0..len(a) {
        s := a[i] + carry
        c1: u64 = if s < carry { 1 } else { 0 }
        s2 := s + b[i]
        c2 := u64(s2 < s)
        r[i] = s2
        carry = c1 + c2
    }
    carry
}

noinline fn add_limbs32(a: []u32, b: []u32, r: []u32) -> u32 {
    carry: u32 = 0
    for i in 0..len(a) {
        s := a[i] + b[i]
        c1: u32 = if b[i] > s { 1 } else { 0 }
        s2 := s + carry
        c2: u32 = if s2 < carry { 1 } else { 0 }
        r[i] = s2
        carry = c1 | c2
    }
    carry
}

noinline fn carry64(a: u64, b: u64) -> u64 {
    s := a + b
    if s < a { 1 } else { 0 }
}
noinline fn carry64s(a: u64, b: u64) -> (u64, u64) {
    s := a + b
    (s, u64(s < b))
}
noinline fn carry32(a: u32, b: u32) -> u32 {
    s := a + b
    if a > s { 1 } else { 0 }
}
// near misses: <= is not a carry, the compare against another value, a signed compare,
// the arms swapped
noinline fn miss_le(a: u64, b: u64) -> u64 {
    s := a + b
    if s <= a { 1 } else { 0 }
}
noinline fn miss_other(a: u64, b: u64, c: u64) -> u64 {
    s := a + b
    if s < c { 1 } else { 0 }
}
noinline fn miss_signed(a: i64, b: i64) -> i64 {
    s := a + b
    if s < a { 1 } else { 0 }
}
noinline fn miss_swapped(a: u64, b: u64) -> u64 {
    s := a + b
    if s < a { 0 } else { 1 }
}
noinline fn miss_sub(a: u64, b: u64) -> u64 {
    s := a - b
    if s < a { 1 } else { 0 }
}

noinline fn muls64(x: i64) -> i64 {
    x * 7 + x * 15 * 3 + x * 17 - x * 31 + x * 33 * 5 - x * 63 + x * 65 + x * 127 - x * 129 + x * 1073741823 + x * 536870913
}
noinline fn mul_parts64(x: i64) -> []i64 {
    return []i64{x * 7, x * 15, x * 17, x * 31, x * 33, x * 63, x * 65, x * 1073741823, x * 536870913, x * 4294967297}
}
noinline fn mul_parts32(x: i32) -> []i32 {
    return []i32{x * 7, x * 15, x * 17, x * 31, x * 33, x * 63, x * 65, x * 1073741823, x * 536870913}
}
noinline fn mul_parts16(x: u16) -> []u16 { return []u16{x * 7, x * 15, x * 17, x * 31, x * 255, x * 257} }
noinline fn mul_parts8(x: i8) -> []i8 { return []i8{x * 7, x * 15, x * 17, x * 31, x * 63, x * 65} }
noinline fn hash31(s: []u8) -> i32 {
    h: i32 = 17
    for c in s { h = h * 31 + i32(c) }
    h
}

// narrow loads in narrow operations
noinline fn sum8(p: []u8, i: i64) -> u8 { p[i - 1] + p[i] + p[i + 1] + p[i + 2] - p[i + 3] }
noinline fn ops8(p: []u8, i: i64) -> u8 { (p[i] & p[i + 1]) | (p[i + 2] ^ p[i + 3]) }
noinline fn sum16(p: []u16, i: i64) -> u16 { p[i] + p[i + 1] - p[i + 2] + (p[i + 3] ^ p[i]) }
noinline fn sumi8(p: []i8, i: i64) -> i64 { i64(p[i] + p[i + 1]) + i64(p[i + 2] - p[i + 3]) }
noinline fn count3(p: []u8, i: i64) -> bool { p[i] + p[i + 1] + p[i + 2] == 3 }

fn main() {
    vals := []u64{0, 1, 2, 0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFE, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF, 0x100000000}
    for a in vals {
        for b in vals {
            s, c := carry64s(a, b)
            put(carry64(a, b), c, s == a + b, carry32(u32(a), u32(b)), " ")
            put(miss_le(a, b), miss_other(a, b, 5), miss_signed(i64(a), i64(b)), miss_swapped(a, b), miss_sub(a, b), " ")
        }
        put("\n")
    }
    a := []u64{0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF, 0, 1, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF}
    b := []u64{1, 0, 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFE, 0x8000000000000000, 0}
    r := alloc[u64](6)
    put(add_limbs(a, b, r), " ", r, "\n")
    put(add_limbs(b, a, r), " ", r, "\n")
    a32 := []u32{0xFFFFFFFF, 0xFFFFFFFF, 0, 0x80000000, 1}
    b32 := []u32{1, 0, 0xFFFFFFFF, 0x80000000, 0xFFFFFFFF}
    r32 := alloc[u32](5)
    put(add_limbs32(a32, b32, r32), " ", r32, "\n")
    xs := []i64{0, 1, -1, 2, 0x7FFFFFFFFFFFFFFF, -0x7FFFFFFFFFFFFFFF - 1, 0x12345678, -0x12345678, 0x7FFF, 0x80, 0xFFFF}
    for x in xs {
        put(muls64(x), " ", mul_parts64(x), "\n")
        put("  ", mul_parts32(i32(x)), " ", mul_parts16(u16(x)), " ", mul_parts8(i8(x)), "\n")
    }
    put(hash31("the quick brown fox jumps over the lazy dog"), "\n")
    p := []u8{0, 1, 0xFF, 0x80, 0x7F, 3, 0xFE, 1, 1, 1, 200, 100}
    for i in 1..len(p) - 3 {
        put(sum8(p, i), " ", ops8(p, i), " ", count3(p, i), " ")
    }
    put("\n")
    w := []u16{0xFFFF, 1, 0x8000, 0x7FFF, 2, 0}
    put(sum16(w, 0), " ", sum16(w, 1), " ", sum16(w, 2), "\n")
    sb := []i8{-128, -1, 127, 1, 0, -128}
    put(sumi8(sb, 0), " ", sumi8(sb, 1), " ", sumi8(sb, 2), "\n")
}
