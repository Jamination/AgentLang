K := [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

rotr :: (x: u32, n: u32) -> u32 {
    (x >> n) | (x << (32 - n))
}

sha256_block :: (st: []u32, p: []u8) {
    w: [64]u32
    for i in 0..16 {
        w[i] = (u32(p[4 * i]) << 24) | (u32(p[4 * i + 1]) << 16) | (u32(p[4 * i + 2]) << 8) | u32(p[4 * i + 3])
    }
    for i in 16..64 {
        s0 := rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        s1 := rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    a := st[0]
    b := st[1]
    c := st[2]
    d := st[3]
    e := st[4]
    f := st[5]
    g := st[6]
    h := st[7]
    for i in 0..64 {
        s1 := rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        ch := (e & f) ^ (~e & g)
        t1 := h + s1 + ch + K[i] + w[i]
        s0 := rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        maj := (a & b) ^ (a & c) ^ (b & c)
        t2 := s0 + maj
        h = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    }
    st[0] += a
    st[1] += b
    st[2] += c
    st[3] += d
    st[4] += e
    st[5] += f
    st[6] += g
    st[7] += h
}

// hash of a message whose length is a multiple of 64 bytes
sha256 :: (data: []u8, out: []u8) {
    st := [8]u32{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
    n := len(data)
    for off in 0..n by 64 {
        sha256_block(st[..], data[off..off + 64])
    }
    pad: [64]u8
    pad[0] = 0x80
    bits := u64(n) * 8
    for i in 0..8 {
        pad[63 - i] = u8(bits >> u64(8 * i))
    }
    sha256_block(st[..], pad[..])
    for i in 0..8 {
        out[4 * i] = u8(st[i] >> 24)
        out[4 * i + 1] = u8(st[i] >> 16)
        out[4 * i + 2] = u8(st[i] >> 8)
        out[4 * i + 3] = u8(st[i])
    }
}

hex :: (d: u8) -> u8 {
    if d < 10 { d + '0' } else { d - 10 + 'a' }
}

main :: () {
    n := 1 << 20
    buf := alloc[u8](n)
    seed: u32 = 12345
    for i in 0..n {
        seed = seed * 1664525 + 1013904223
        buf[i] = u8(seed >> 24)
    }
    digest: [32]u8
    for round in 0..200 {
        sha256(buf, digest[..])
        for i in 0..32 {
            buf[i] = buf[i] ^ digest[i]
        }
    }
    for i in 0..32 {
        putc(hex(digest[i] >> 4))
        putc(hex(digest[i] & 15))
    }
    putc('\n')
}
