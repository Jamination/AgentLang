// portable bit idioms: loop popcount, SWAR popcount, rotate by a variable, byte swap by shifts,
// count trailing / leading zeros by loops, lowest set bit, bit reversal by masks
fn pop_loop(v: u64) -> u64 {
    x := v
    c: u64 = 0
    while x != 0 {
        x &= x - 1
        c += 1
    }
    c
}

fn pop_swar(v: u64) -> u64 {
    x := v - ((v >> 1) & 0x5555555555555555)
    x = (x & 0x3333333333333333) + ((x >> 2) & 0x3333333333333333)
    x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0F
    (x * 0x0101010101010101) >> 56
}

fn rotl64(x: u64, r: u64) -> u64 {
    (x << (r & 63)) | (x >> ((64 - r) & 63))
}

fn bswap64(x: u64) -> u64 {
    (x >> 56) | ((x >> 40) & 0xFF00) | ((x >> 24) & 0xFF0000) | ((x >> 8) & 0xFF000000) |
        ((x << 8) & 0xFF00000000) | ((x << 24) & 0xFF0000000000) | ((x << 40) & 0xFF000000000000) | (x << 56)
}

fn ctz_loop(v: u64) -> u64 {
    if v == 0 { return 64 }
    x := v
    n: u64 = 0
    while x & 1 == 0 {
        x >>= 1
        n += 1
    }
    n
}

fn clz_loop(v: u64) -> u64 {
    if v == 0 { return 64 }
    x := v
    n: u64 = 0
    while x & 0x8000000000000000 == 0 {
        x <<= 1
        n += 1
    }
    n
}

fn rev64(v: u64) -> u64 {
    x := ((v >> 1) & 0x5555555555555555) | ((v & 0x5555555555555555) << 1)
    x = ((x >> 2) & 0x3333333333333333) | ((x & 0x3333333333333333) << 2)
    x = ((x >> 4) & 0x0F0F0F0F0F0F0F0F) | ((x & 0x0F0F0F0F0F0F0F0F) << 4)
    bswap64(x)
}

fn main() {
    s: u64 = 0x123456789ABCDEF1
    acc: u64 = 0
    for i in 0..12000000 {
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        x := s
        acc += pop_loop(x & 0x00FF_00FF_00FF_00FF)
        acc += pop_swar(x)
        acc ^= rotl64(x, acc)
        acc += bswap64(x) >> 3
        acc += ctz_loop(x & 0xFFFF_FFFF_FFFF_FF00) + clz_loop(x >> (x & 31))
        acc ^= x & (0 - x)
        acc += rev64(x) >> 7
    }
    put(acc, "\n")
}
