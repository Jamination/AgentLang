// std.crypto: SHA-256, HMAC-SHA256, constant-time comparison, Hex and Base64 codecs, and
// OS cryptographic random bytes. `use std.crypto`.
// Pure AL with zero libc dependency on Linux (uses getrandom syscall directly).

// ---------- SHA-256 (FIPS 180-4) ----------

// Incremental SHA-256 hasher.
struct Sha256 {
    h: [8]u32
    buf: [64]u8
    buf_len: i64
    total: u64
}

priv const SHA_K = [64]u32{
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

priv fn sha_compress(h: *[8]u32, blk: []u8) {
    w: [64]u32
    for i in 0..16 {
        j := i * 4
        w[i] = u32(blk[j]) << 24 | u32(blk[j + 1]) << 16 | u32(blk[j + 2]) << 8 | u32(blk[j + 3])
    }
    for i in 16..64 {
        s0 := rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        s1 := rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] + s0 + w[i - 7] + s1
    }
    a := h[0]
    b := h[1]
    c := h[2]
    d := h[3]
    e := h[4]
    f := h[5]
    g := h[6]
    hv := h[7]
    for i in 0..64 {
        s1 := rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        ch := (e & f) ^ ((~e) & g)
        t1 := hv + s1 + ch + SHA_K[i] + w[i]
        s0 := rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        maj := (a & b) ^ (a & c) ^ (b & c)
        t2 := s0 + maj
        hv = g
        g = f
        f = e
        e = d + t1
        d = c
        c = b
        b = a
        a = t1 + t2
    }
    h[0] += a
    h[1] += b
    h[2] += c
    h[3] += d
    h[4] += e
    h[5] += f
    h[6] += g
    h[7] += hv
}

// Creates a new incremental SHA-256 hasher.
fn sha256_new() -> Sha256 {
    s: Sha256
    s.h = [8]u32{0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19}
    return s
}

// Feeds bytes into an incremental SHA-256 hasher.
fn sha256_update(s: *Sha256, data: []u8) {
    n := len(data)
    s.total += u64(n)
    at := 0
    if s.buf_len > 0 {
        need := 64 - s.buf_len
        take := min(need, n)
        for i in 0..take {
            s.buf[s.buf_len + i] = data[i]
        }
        s.buf_len += take
        at += take
        if s.buf_len == 64 {
            sha_compress(&s.h, s.buf[..])
            s.buf_len = 0
        }
    }
    while at + 64 <= n {
        sha_compress(&s.h, data[at..at + 64])
        at += 64
    }
    while at < n {
        s.buf[s.buf_len] = data[at]
        s.buf_len += 1
        at += 1
    }
}

// Finalizes a SHA-256 hasher and returns the 32-byte digest.
fn sha256_final(s: *Sha256) -> [32]u8 {
    bits := s.total * 8
    s.buf[s.buf_len] = 0x80
    s.buf_len += 1
    if s.buf_len > 56 {
        while s.buf_len < 64 {
            s.buf[s.buf_len] = 0
            s.buf_len += 1
        }
        sha_compress(&s.h, s.buf[..])
        s.buf_len = 0
    }
    while s.buf_len < 56 {
        s.buf[s.buf_len] = 0
        s.buf_len += 1
    }
    for i in 0..8 {
        s.buf[56 + i] = u8(bits >> u64(56 - i * 8))
    }
    sha_compress(&s.h, s.buf[..])
    out: [32]u8
    for i in 0..8 {
        w := s.h[i]
        out[i * 4] = u8(w >> 24)
        out[i * 4 + 1] = u8(w >> 16)
        out[i * 4 + 2] = u8(w >> 8)
        out[i * 4 + 3] = u8(w)
    }
    return out
}

// Computes the 32-byte SHA-256 digest of `data`.
fn sha256(data: []u8) -> [32]u8 {
    s := sha256_new()
    sha256_update(&s, data)
    return sha256_final(&s)
}

// Computes the lowercase 64-character hex SHA-256 digest of `data`.
fn sha256_hex(data: []u8) -> str {
    d := sha256(data)
    return hex_encode(d[..])
}

// ---------- HMAC-SHA256 (RFC 2104) ----------

// Computes the 32-byte HMAC-SHA256 of `msg` with `key`.
fn hmac_sha256(key: []u8, msg: []u8) -> [32]u8 {
    kblk: [64]u8
    if len(key) > 64 {
        kd := sha256(key)
        for i in 0..32 {
            kblk[i] = kd[i]
        }
    } else {
        for i in 0..len(key) {
            kblk[i] = key[i]
        }
    }
    ipad: [64]u8
    opad: [64]u8
    for i in 0..64 {
        ipad[i] = kblk[i] ^ 0x36
        opad[i] = kblk[i] ^ 0x5c
    }
    inner := sha256_new()
    sha256_update(&inner, ipad[..])
    sha256_update(&inner, msg)
    idig := sha256_final(&inner)
    outer := sha256_new()
    sha256_update(&outer, opad[..])
    sha256_update(&outer, idig[..])
    return sha256_final(&outer)
}

// Computes the lowercase hex HMAC-SHA256 of `msg` with `key`.
fn hmac_sha256_hex(key: []u8, msg: []u8) -> str {
    d := hmac_sha256(key, msg)
    return hex_encode(d[..])
}

// Constant-time byte-slice equality (returns false immediately only if lengths differ).
noinline fn const_time_eq(a: []u8, b: []u8) -> bool {
    if len(a) != len(b) {
        return false
    }
    diff: u8 = 0
    for i in 0..len(a) {
        diff |= a[i] ^ b[i]
    }
    return diff == 0
}

// ---------- Hex encoding ----------

priv const HEX_DIGITS = "0123456789abcdef"

// Encodes bytes as lowercase hexadecimal text.
fn hex_encode(data: []u8) -> str {
    n := len(data)
    out := alloc[u8](n * 2)
    for i in 0..n {
        b := i64(data[i])
        out[i * 2] = HEX_DIGITS[b >> 4]
        out[i * 2 + 1] = HEX_DIGITS[b & 15]
    }
    return out
}

priv fn hex_val(c: u8) -> i64 {
    if c >= '0' && c <= '9' {
        return i64(c - '0')
    }
    if c >= 'a' && c <= 'f' {
        return i64(c - 'a') + 10
    }
    if c >= 'A' && c <= 'F' {
        return i64(c - 'A') + 10
    }
    return -1
}

// Decodes hexadecimal text (upper or lower case, even length) into bytes.
fn hex_decode(s: str) -> ([]u8, bool) {
    n := len(s)
    if n & 1 != 0 {
        return (nil, false)
    }
    out := alloc[u8](n / 2)
    for i in 0..n / 2 {
        hi := hex_val(s[i * 2])
        lo := hex_val(s[i * 2 + 1])
        if hi < 0 || lo < 0 {
            return (nil, false)
        }
        out[i] = u8((hi << 4) | lo)
    }
    return (out, true)
}

// ---------- Base64 / Base64URL (RFC 4648) ----------

priv const B64_STD = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
priv const B64_URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

priv fn b64_enc(data: []u8, alpha: str, pad: bool) -> str {
    n := len(data)
    out := vec[u8]()
    out.reserve((n + 2) / 3 * 4)
    i := 0
    while i + 3 <= n {
        v := u32(data[i]) << 16 | u32(data[i + 1]) << 8 | u32(data[i + 2])
        out.push(alpha[i64((v >> 18) & 63)])
        out.push(alpha[i64((v >> 12) & 63)])
        out.push(alpha[i64((v >> 6) & 63)])
        out.push(alpha[i64(v & 63)])
        i += 3
    }
    rem := n - i
    if rem == 1 {
        v := u32(data[i]) << 16
        out.push(alpha[i64((v >> 18) & 63)])
        out.push(alpha[i64((v >> 12) & 63)])
        if pad {
            out.push('=')
            out.push('=')
        }
    } else if rem == 2 {
        v := u32(data[i]) << 16 | u32(data[i + 1]) << 8
        out.push(alpha[i64((v >> 18) & 63)])
        out.push(alpha[i64((v >> 12) & 63)])
        out.push(alpha[i64((v >> 6) & 63)])
        if pad {
            out.push('=')
        }
    }
    return out.items()
}

priv fn b64_val(c: u8, url: bool) -> i64 {
    if c >= 'A' && c <= 'Z' { return i64(c - 'A') }
    if c >= 'a' && c <= 'z' { return i64(c - 'a') + 26 }
    if c >= '0' && c <= '9' { return i64(c - '0') + 52 }
    if url {
        if c == '-' { return 62 }
        if c == '_' { return 63 }
    } else {
        if c == '+' { return 62 }
        if c == '/' { return 63 }
    }
    return -1
}

priv fn b64_dec(s: str, url: bool) -> ([]u8, bool) {
    n := len(s)
    // strip optional trailing '=' padding (at most 2)
    pads := 0
    while pads < 2 && n > 0 && s[n - 1] == '=' {
        n -= 1
        pads += 1
    }
    if pads > 0 && (n + pads) % 4 != 0 {
        return (nil, false)
    }
    rem := n % 4
    if rem == 1 {
        return (nil, false)
    }
    out := vec[u8]()
    out.reserve(n / 4 * 3 + 2)
    i := 0
    while i + 4 <= n {
        a := b64_val(s[i], url)
        b := b64_val(s[i + 1], url)
        c := b64_val(s[i + 2], url)
        d := b64_val(s[i + 3], url)
        if a < 0 || b < 0 || c < 0 || d < 0 {
            return (nil, false)
        }
        v := (a << 18) | (b << 12) | (c << 6) | d
        out.push(u8((v >> 16) & 255))
        out.push(u8((v >> 8) & 255))
        out.push(u8(v & 255))
        i += 4
    }
    if rem == 2 {
        a := b64_val(s[i], url)
        b := b64_val(s[i + 1], url)
        if a < 0 || b < 0 || (b & 15) != 0 {
            return (nil, false)
        }
        out.push(u8((a << 2) | (b >> 4)))
    } else if rem == 3 {
        a := b64_val(s[i], url)
        b := b64_val(s[i + 1], url)
        c := b64_val(s[i + 2], url)
        if a < 0 || b < 0 || c < 0 || (c & 3) != 0 {
            return (nil, false)
        }
        v := (a << 10) | (b << 4) | (c >> 2)
        out.push(u8((v >> 8) & 255))
        out.push(u8(v & 255))
    }
    return (out.items(), true)
}

// Encodes bytes using standard Base64 with '=' padding.
fn base64_encode(data: []u8) -> str {
    return b64_enc(data, B64_STD, true)
}

// Decodes standard Base64 (with or without '=' padding).
fn base64_decode(s: str) -> ([]u8, bool) {
    return b64_dec(s, false)
}

// Encodes bytes using URL-safe Base64 ('-', '_') without padding.
fn base64url_encode(data: []u8) -> str {
    return b64_enc(data, B64_URL, false)
}

// Decodes URL-safe Base64 (with or without '=' padding).
fn base64url_decode(s: str) -> ([]u8, bool) {
    return b64_dec(s, true)
}

// ---------- OS cryptographic random bytes ----------

when TARGET_OS == Windows {
    priv extern "advapi32.dll" fn SystemFunction036(buf: *u8, n: u32) -> u8

    // Fills `out` with cryptographically secure random bytes from the operating system.
    fn random_bytes(out: []u8) -> bool {
        at := 0
        n := len(out)
        while at < n {
            chunk := min(n - at, 1 << 30)
            if SystemFunction036(ptr(out[at..]), u32(chunk)) == 0 {
                return false
            }
            at += chunk
        }
        return true
    }
} else when TARGET_OS == MacOS {
    priv extern "/usr/lib/libSystem.B.dylib" fn arc4random_buf(buf: *u8, n: u64)

    // Fills `out` with cryptographically secure random bytes from the operating system.
    fn random_bytes(out: []u8) -> bool {
        if len(out) > 0 {
            arc4random_buf(ptr(out), u64(len(out)))
        }
        return true
    }
} else {
    when TARGET_ARCH == Arm64 {
        priv const SYS_GETRANDOM = 278
    } else {
        priv const SYS_GETRANDOM = 318
    }

    // Fills `out` with cryptographically secure random bytes from Linux getrandom(2).
    fn random_bytes(out: []u8) -> bool {
        at := 0
        n := len(out)
        while at < n {
            r := syscall(SYS_GETRANDOM, ptr(out[at..]), n - at, 0)
            if r == -4 {
                continue
            }
            if r <= 0 {
                return false
            }
            at += r
        }
        return true
    }
}

// Returns a cryptographically secure random u64 from the operating system.
fn random_u64() -> (u64, bool) {
    buf: [8]u8
    if !random_bytes(buf[..]) {
        return (0, false)
    }
    v: u64 = 0
    for i in 0..8 {
        v |= u64(buf[i]) << u64(i * 8)
    }
    return (v, true)
}
