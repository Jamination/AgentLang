// Instruction combining of bit idioms: rotations with masked or complemented counts, byte
// swaps by shifts and masks, values put together from loaded bytes, the sign of a value with
// a known-zero top bit. Every function is noinline so that its argument is not a constant;
// the near misses must keep their meaning (they are not rotations / byte swaps / loads).

noinline fn rotl64m(x: u64, r: u64) -> u64 { (x << (r & 63)) | (x >> ((64 - r) & 63)) }
noinline fn rotl64n(x: u64, r: u64) -> u64 { (x << (r & 63)) | (x >> ((0 - r) & 63)) }
noinline fn rotr64(x: u64, r: u64) -> u64 { (x >> r) | (x << (64 - r)) }
noinline fn rotl64k(x: u64, r: u64) -> u64 { (x << (r & 0xFF)) | (x >> ((128 - r) & 0x3F)) }
noinline fn rotl32m(x: u32, r: u32) -> u32 { (x << (r & 31)) | (x >> ((32 - r) & 31)) }
noinline fn rotr32n(x: u32, r: u32) -> u32 { (x >> (r & 31)) | (x << ((0 - r) & 31)) }
noinline fn rotl16(x: u16, r: u16) -> u16 { (x << (r & 15)) | (x >> ((16 - r) & 15)) }
noinline fn rotl8(x: u8, r: u8) -> u8 { (x << (r & 7)) | (x >> ((8 - r) & 7)) }
// with ^ or + a count of 0 gives 0 or 2x: not a rotation
noinline fn xrot64(x: u64, r: u64) -> u64 { (x << (r & 63)) ^ (x >> ((64 - r) & 63)) }
noinline fn arot64(x: u64, r: u64) -> u64 { (x << r) + (x >> (64 - r)) }
noinline fn xrot32(x: u32, r: u32) -> u32 { (x << r) ^ (x >> (0 - r)) }
// near misses: a mask that drops a count bit, a complement that is not 0 modulo 64
noinline fn miss_mask(x: u64, r: u64) -> u64 { (x << (r & 62)) | (x >> ((64 - r) & 63)) }
noinline fn miss_comp(x: u64, r: u64) -> u64 { (x << (r & 63)) | (x >> ((65 - r) & 63)) }
noinline fn miss_32(x: u64, r: u64) -> u64 { (x << (r & 31)) | (x >> ((32 - r) & 31)) }
// counts: (n + 64) is n, (n + 32) is not, a mask of 3 on an 8-bit shift drops a bit
noinline fn sh_add64(x: u64, r: u64) -> u64 { (x >> (r + 64)) ^ (x << (r + 128)) }
noinline fn sh_add32(x: u64, r: u64) -> u64 { x >> (r + 32) }
noinline fn sh8(x: u8, r: u8) -> u8 { (x << (r & 63)) ^ (x >> (r & 3)) }
noinline fn sar64(x: i64, r: i64) -> i64 { x >> (r & 127) }

noinline fn bswap64(x: u64) -> u64 {
    (x >> 56) | ((x >> 40) & 0xFF00) | ((x >> 24) & 0xFF0000) | ((x >> 8) & 0xFF000000) |
        ((x << 8) & 0xFF00000000) | ((x << 24) & 0xFF0000000000) | ((x << 40) & 0xFF000000000000) | (x << 56)
}
noinline fn bswap64x(x: u64) -> u64 {
    (x << 56) ^ ((x << 40) & 0xFF000000000000) ^ ((x << 24) & 0xFF0000000000) ^ ((x << 8) & 0xFF00000000) +
        ((x >> 8) & 0xFF000000) + ((x >> 24) & 0xFF0000) + ((x >> 40) & 0xFF00) + (x >> 56)
}
noinline fn bswap32(x: u32) -> u32 { (x >> 24) | ((x >> 8) & 0xFF00) | ((x << 8) & 0xFF0000) | (x << 24) }
noinline fn bswap32in64(x: u64) -> u64 {
    ((x >> 24) & 0xFF) | ((x >> 8) & 0xFF00) | ((x << 8) & 0xFF0000) | ((x << 24) & 0xFF000000)
}
noinline fn bswap16in32(x: u32) -> u32 { ((x >> 8) & 0xFF) | ((x << 8) & 0xFF00) }
noinline fn bswap16(x: u16) -> u16 { (x >> 8) | (x << 8) }
// byte swaps by ladders of swaps (the last step is a rotation by half), and a near miss
noinline fn bs_ladder64(v: u64) -> u64 {
    x := ((v >> 8) & 0x00FF00FF00FF00FF) | ((v & 0x00FF00FF00FF00FF) << 8)
    x = ((x >> 16) & 0x0000FFFF0000FFFF) | ((x & 0x0000FFFF0000FFFF) << 16)
    (x >> 32) | (x << 32)
}
noinline fn bs_ladder32(v: u32) -> u32 {
    x := ((v >> 8) & 0x00FF00FF) | ((v & 0x00FF00FF) << 8)
    (x >> 16) | (x << 16)
}
noinline fn miss_ladder(v: u32) -> u32 {
    x := ((v >> 8) & 0x00FF00FF) | ((v & 0x00FF00FF) << 8)
    (x >> 8) | (x << 24)
}
// bit reversal: three swap steps, then the bytes
noinline fn rev64(v: u64) -> u64 {
    x := ((v >> 1) & 0x5555555555555555) | ((v & 0x5555555555555555) << 1)
    x = ((x >> 2) & 0x3333333333333333) | ((x & 0x3333333333333333) << 2)
    x = ((x >> 4) & 0x0F0F0F0F0F0F0F0F) | ((x & 0x0F0F0F0F0F0F0F0F) << 4)
    bswap64(x)
}
// near misses: one mask off by a bit, a shift off by one byte, an overlap
noinline fn miss_bs1(x: u32) -> u32 { (x >> 24) | ((x >> 8) & 0xFE00) | ((x << 8) & 0xFF0000) | (x << 24) }
noinline fn miss_bs2(x: u32) -> u32 { (x >> 24) | ((x >> 8) & 0xFF00) | ((x << 16) & 0xFF0000) | (x << 24) }
noinline fn miss_bs3(x: u32) -> u32 { (x >> 24) + ((x >> 8) & 0xFFFF00) + ((x << 8) & 0xFF0000) + (x << 24) }

noinline fn be32(p: []u8) -> u32 { (u32(p[0]) << 24) | (u32(p[1]) << 16) | (u32(p[2]) << 8) | u32(p[3]) }
noinline fn le32(p: []u8) -> u32 { u32(p[0]) | (u32(p[1]) << 8) | (u32(p[2]) << 16) | (u32(p[3]) << 24) }
noinline fn le32at(p: []u8, i: i64) -> u32 {
    u32(p[i + 3]) << 24 | u32(p[i + 2]) << 16 | u32(p[i + 1]) << 8 | u32(p[i])
}
noinline fn le64(p: []u8) -> u64 {
    assert len(p) >= 8
    u64(p[0]) | (u64(p[1]) << 8) | (u64(p[2]) << 16) | (u64(p[3]) << 24) | (u64(p[4]) << 32) |
        (u64(p[5]) << 40) | (u64(p[6]) << 48) | (u64(p[7]) << 56)
}
noinline fn be64(p: []u8) -> u64 {
    if len(p) < 8 { return 0 }
    (u64(p[0]) << 56) + (u64(p[1]) << 48) + (u64(p[2]) << 40) + (u64(p[3]) << 32) +
        (u64(p[4]) << 24) + (u64(p[5]) << 16) + (u64(p[6]) << 8) + u64(p[7])
}
noinline fn be16(p: []u8) -> u32 { (u32(p[0]) << 8) | u32(p[1]) }
noinline fn le16(p: []u8) -> u16 { u16(p[0]) | (u16(p[1]) << 8) }
// near misses: a gap, two arrays, a store between the loads, one byte twice
noinline fn miss_gap(p: []u8) -> u32 { u32(p[0]) | (u32(p[2]) << 8) | (u32(p[3]) << 16) | (u32(p[4]) << 24) }
noinline fn miss_two(p: []u8, q: []u8) -> u32 { u32(p[0]) | (u32(p[1]) << 8) | (u32(q[2]) << 16) | (u32(q[3]) << 24) }
noinline fn miss_store(p: []u8) -> u32 {
    a := u32(p[0]) | (u32(p[1]) << 8)
    p[2] = p[2] + 1
    a | (u32(p[2]) << 16) | (u32(p[3]) << 24)
}
noinline fn miss_twice(p: []u8) -> u32 { u32(p[0]) | (u32(p[1]) << 8) | (u32(p[1]) << 16) | (u32(p[3]) << 24) }

// the sign of a value whose top bit is 0
noinline fn tofloat(x: u64) -> f64 { f64(x >> 11) }
noinline fn nonneg(x: u64) -> bool { i64(x >> 1) >= 0 }
noinline fn neg(x: u64) -> bool { i64(x >> 1) < 0 }
noinline fn neg0(x: u64) -> bool { i64(x >> 0) < 0 }
noinline fn neg32(x: u32) -> bool { i32(x & 0x7FFFFFFF) <= -1 }

fn main() {
    xs := []u64{0, 1, 0x8000000000000001, 0xFFFFFFFFFFFFFFFF, 0x0123456789ABCDEF, 0xFEDCBA9876543210}
    rs := []u64{0, 1, 7, 31, 32, 33, 63, 64, 65, 127, 128, 0xFFFFFFFFFFFFFFFF, 0x8000000000000000}
    for x in xs {
        for r in rs {
            put(rotl64m(x, r), " ", rotl64n(x, r), " ", rotr64(x, r), " ", rotl64k(x, r), " ")
            put(xrot64(x, r), " ", arot64(x, r), " ", miss_mask(x, r), " ", miss_comp(x, r), " ", miss_32(x, r), " ")
            put(sh_add64(x, r), " ", sh_add32(x, r), " ", sar64(i64(x), i64(r)), "\n")
            put("  ", rotl32m(u32(x), u32(r)), " ", rotr32n(u32(x), u32(r)), " ", xrot32(u32(x), u32(r)), " ")
            put(rotl16(u16(x), u16(r)), " ", rotl8(u8(x), u8(r)), " ", sh8(u8(x), u8(r)), "\n")
        }
        put(bswap64(x), " ", bswap64x(x), " ", bswap32(u32(x)), " ", bswap32in64(x), " ", bswap16in32(u32(x)), " ", bswap16(u16(x)), "\n")
        put(miss_bs1(u32(x)), " ", miss_bs2(u32(x)), " ", miss_bs3(u32(x)), "\n")
        put(bs_ladder64(x), " ", bs_ladder32(u32(x)), " ", miss_ladder(u32(x)), " ", rev64(x), "\n")
        put(tofloat(x), " ", nonneg(x), " ", neg(x), " ", neg0(x), " ", neg32(u32(x)), "\n")
    }
    p := []u8{0x01, 0x82, 0x03, 0xF4, 0x05, 0x06, 0xA7, 0x08, 0xFF, 0x0A}
    q := []u8{0x11, 0x22, 0x33, 0x44}
    put(be32(p), " ", le32(p), " ", le32at(p, 3), " ", le32at(p, 6), " ", le64(p), " ", be64(p[1..]), " ", be64(p[3..]), "\n")
    put(be16(p[7..]), " ", le16(p[8..]), " ", miss_gap(p), " ", miss_two(p, q), " ", miss_twice(p), "\n")
    put(miss_store(p), " ", miss_store(p), " ", p[2], "\n")
}
