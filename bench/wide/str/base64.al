// [codegen] base64 encode and decode with lookup tables (same loops in C)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

const ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

fn encode(src: []u8, dst: []u8) -> i64 {
    n := len(src)
    k := 0
    i := 0
    while i + 3 <= n {
        v := (u32(src[i]) << 16) | (u32(src[i + 1]) << 8) | u32(src[i + 2])
        dst[k] = ALPHA[v >> 18]
        dst[k + 1] = ALPHA[(v >> 12) & 63]
        dst[k + 2] = ALPHA[(v >> 6) & 63]
        dst[k + 3] = ALPHA[v & 63]
        k += 4
        i += 3
    }
    rest := n - i
    if rest > 0 {
        v := u32(src[i]) << 16
        if rest == 2 { v = v | (u32(src[i + 1]) << 8) }
        dst[k] = ALPHA[v >> 18]
        dst[k + 1] = ALPHA[(v >> 12) & 63]
        dst[k + 2] = if rest == 2 { ALPHA[(v >> 6) & 63] } else { '=' }
        dst[k + 3] = '='
        k += 4
    }
    k
}

// returns the decoded length, or -1 on a bad character
fn decode(src: []u8, dst: []u8, rev: []i32) -> i64 {
    n := len(src)
    k := 0
    i := 0
    while i + 4 <= n {
        a := rev[src[i]]
        b := rev[src[i + 1]]
        c := rev[src[i + 2]]
        d := rev[src[i + 3]]
        if (a | b | c | d) < 0 {
            if src[i + 3] == '=' && i + 4 == n { break }
            return -1
        }
        v := (a << 18) | (b << 12) | (c << 6) | d
        dst[k] = u8(v >> 16)
        dst[k + 1] = u8(v >> 8)
        dst[k + 2] = u8(v)
        k += 3
        i += 4
    }
    if i < n {
        a := rev[src[i]]
        b := rev[src[i + 1]]
        if a < 0 || b < 0 { return -1 }
        dst[k] = u8((a << 2) | (b >> 4))
        k += 1
        if src[i + 2] != '=' {
            c := rev[src[i + 2]]
            if c < 0 { return -1 }
            dst[k] = u8((b << 4) | (c >> 2))
            k += 1
        }
    }
    k
}

fn main() {
    n := 12000001
    src := alloc[u8](n)
    seed: u64 = 11
    for i in 0..n {
        seed = lcg(seed)
        src[i] = u8(seed >> 56)
    }
    rev := alloc[i32](256)
    fill(rev, -1)
    for i in 0..64 { rev[ALPHA[i]] = i32(i) }
    enc := alloc[u8](n / 3 * 4 + 8)
    dec := alloc[u8](n + 8)
    h: u64 = 0
    tot := 0
    for r in 0..16 {
        src[r] = u8(r)
        k := encode(src, enc)
        m := decode(enc[..k], dec, rev)
        tot += k + m
        for j in 0..1000 { h = h * 31 + u64(enc[j * 997]) + u64(dec[j * 991]) }
        h = h * 31 + u64(dec[m - 1])
    }
    print(tot, h)
}
