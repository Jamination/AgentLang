// [codegen] UTF-8 encode of random code points, then strict validation + decoding (same loops in C)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn encode(out: []u8, k: i64, cp: u32) -> i64 {
    if cp < 0x80 {
        out[k] = u8(cp)
        return k + 1
    }
    if cp < 0x800 {
        out[k] = u8(0xC0 | (cp >> 6))
        out[k + 1] = u8(0x80 | (cp & 0x3F))
        return k + 2
    }
    if cp < 0x10000 {
        out[k] = u8(0xE0 | (cp >> 12))
        out[k + 1] = u8(0x80 | ((cp >> 6) & 0x3F))
        out[k + 2] = u8(0x80 | (cp & 0x3F))
        return k + 3
    }
    out[k] = u8(0xF0 | (cp >> 18))
    out[k + 1] = u8(0x80 | ((cp >> 12) & 0x3F))
    out[k + 2] = u8(0x80 | ((cp >> 6) & 0x3F))
    out[k + 3] = u8(0x80 | (cp & 0x3F))
    k + 4
}

fn gen(ncp: i64) -> []u8 {
    out := alloc[u8](ncp * 4)
    seed: u64 = 4242
    k := 0
    for i in 0..ncp {
        seed = lcg(seed)
        r := (seed >> 33) % 100
        x := u32((seed >> 12) & 0x1FFFFF)
        cp: u32 = 0
        if r < 60 {
            cp = 32 + x % 95
        } else if r < 80 {
            cp = 0x80 + x % (0x800 - 0x80)
        } else if r < 95 {
            cp = 0x800 + x % (0xD800 - 0x800)
        } else {
            cp = 0x10000 + x % (0x110000 - 0x10000)
        }
        k = encode(out, k, cp)
    }
    out[..k]
}

// number of code points and sum of them, or (-1, position) on invalid input
fn decode(s: []u8) -> (i64, i64) {
    n := len(s)
    i := 0
    count := 0
    sum := 0
    while i < n {
        c := u32(s[i])
        if c < 0x80 {
            sum += i64(c)
            i += 1
        } else if c < 0xC2 {
            return (-1, i)
        } else if c < 0xE0 {
            if i + 1 >= n { return (-1, i) }
            c1 := u32(s[i + 1])
            if (c1 & 0xC0) != 0x80 { return (-1, i) }
            sum += i64(((c & 0x1F) << 6) | (c1 & 0x3F))
            i += 2
        } else if c < 0xF0 {
            if i + 2 >= n { return (-1, i) }
            c1 := u32(s[i + 1])
            c2 := u32(s[i + 2])
            if (c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80 { return (-1, i) }
            cp := ((c & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F)
            if cp < 0x800 || (cp >= 0xD800 && cp < 0xE000) { return (-1, i) }
            sum += i64(cp)
            i += 3
        } else if c < 0xF5 {
            if i + 3 >= n { return (-1, i) }
            c1 := u32(s[i + 1])
            c2 := u32(s[i + 2])
            c3 := u32(s[i + 3])
            if (c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80 { return (-1, i) }
            cp := ((c & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F)
            if cp < 0x10000 || cp > 0x10FFFF { return (-1, i) }
            sum += i64(cp)
            i += 4
        } else {
            return (-1, i)
        }
        count += 1
    }
    (count, sum)
}

fn main() {
    s := gen(4000000)
    tc := 0
    ts := 0
    for r in 0..20 {
        c, sm := decode(s)
        tc += c
        ts += sm
    }
    s[len(s) / 2] = 0xFF
    bad, at := decode(s)
    print(len(s), tc, ts, bad, at > 0)
}
