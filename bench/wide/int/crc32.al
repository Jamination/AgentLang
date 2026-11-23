// CRC-32 (IEEE, reflected): table-driven byte at a time, slicing-by-4, and bitwise
fn make_table(t: []u32) {
    for i in 0..256 {
        c := u32(i)
        for _ in 0..8 {
            c = if c & 1 != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }
        }
        t[i] = c
    }
}

fn crc_table(t: []u32, crc0: u32, buf: []u8) -> u32 {
    c := ~crc0
    for b in buf {
        c = t[(c ^ u32(b)) & 0xFF] ^ (c >> 8)
    }
    ~c
}

fn crc_bitwise(crc0: u32, buf: []u8) -> u32 {
    c := ~crc0
    for b in buf {
        c ^= u32(b)
        for _ in 0..8 {
            mask := 0 - (c & 1)
            c = (c >> 1) ^ (0xEDB88320 & mask)
        }
    }
    ~c
}

fn main() {
    n := 1 << 20
    buf := alloc[u8](n)
    seed: u32 = 12345
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        buf[i] = u8(seed >> 24)
    }
    t := alloc[u32](256)
    make_table(t)
    acc: u32 = 0
    for r in 0..160 {
        buf[r] ^= u8(acc)
        acc ^= crc_table(t, acc, buf)
    }
    for r in 0..12 {
        buf[r] ^= u8(acc)
        acc ^= crc_bitwise(acc, buf)
    }
    put(acc, "\n")
}
