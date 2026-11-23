// The byte routines that work 8 bytes at a time (find, count, split, replace, ==, cmp,
// hash of strings, index_of of bytes) against plain byte-by-byte references: every length
// 0..40 around the word boundaries, starts at every offset of a word, matches at the very
// end, overlapping matches, all byte values (0x80 and above compare as unsigned).
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn ref_find(s: str, sub: str) -> i64 {
    i := 0
    while i + len(sub) <= len(s) {
        ok := true
        for j in 0..len(sub) {
            if s[i + j] != sub[j] {
                ok = false
                break
            }
        }
        if ok {
            return i
        }
        i += 1
    }
    return -1
}

fn ref_count(s: str, sub: str) -> i64 {
    n := 0
    i := 0
    loop {
        k := ref_find(s[i..], sub)
        if k < 0 {
            return n
        }
        n += 1
        i += k + len(sub)
    }
}

fn ref_eq(a: str, b: str) -> bool {
    if len(a) != len(b) {
        return false
    }
    for i in 0..len(a) {
        if a[i] != b[i] {
            return false
        }
    }
    return true
}

fn ref_cmp(a: str, b: str) -> i64 {
    for i in 0..min(len(a), len(b)) {
        if a[i] != b[i] {
            return i64(a[i]) - i64(b[i])
        }
    }
    return len(a) - len(b)
}

fn ref_index(s: []u8, c: u8) -> i64 {
    for i in 0..len(s) {
        if s[i] == c {
            return i
        }
    }
    return -1
}

// strings of the bytes `alpha` at an offset of a larger buffer
fn rand_str(seed: *u64, buf: []u8, off: i64, n: i64, alpha: str) -> str {
    for i in 0..n {
        *seed = lcg(*seed)
        buf[off + i] = alpha[i64((*seed >> 33) % u64(len(alpha)))]
    }
    return buf[off..off + n]
}

fn test_find() {
    seed: u64 = 1
    hb := alloc[u8](64)
    nb := alloc[u8](64)
    bad := 0
    checks := 0
    for alpha in ([]str{"ab", "abc", "a\x00\xff", "abcdefghijklmnopqrstuvwxyz"}) {
        for n in 0..41 {
            for off in 0..8 {
                for rep in 0..6 {
                    s := rand_str(&seed, hb, off, n, alpha)
                    for m in 0..12 {
                        // a needle from s (also at its very end) or a random one
                        sub := ""
                        if m <= n && rep % 2 == 0 {
                            seed = lcg(seed)
                            at := if rep == 0 { n - m } else { i64((seed >> 33) % u64(n - m + 1)) }
                            copy(nb[(off + 3) & 7..], s[at..at + m])
                            sub = nb[(off + 3) & 7..((off + 3) & 7) + m]
                        } else {
                            sub = rand_str(&seed, nb, (off + 5) & 7, m, alpha)
                        }
                        checks += 1
                        if find(s, sub) != ref_find(s, sub) {
                            bad += 1
                            if bad < 5 {
                                print("find", s, sub, find(s, sub), ref_find(s, sub))
                            }
                        }
                        if m > 0 {
                            if count(s, sub) != ref_count(s, sub) {
                                bad += 1
                            }
                            for from in 0..n + 1 {
                                r := ref_find(s[from..], sub)
                                if find(s, sub, from) != (if r < 0 { -1 } else { from + r }) {
                                    bad += 1
                                }
                            }
                            parts := split(s, sub)
                            if len(parts) != ref_count(s, sub) + 1 || join(parts, sub) != s {
                                bad += 1
                            }
                            if replace(s, sub, "") != join(parts, "") {
                                bad += 1
                            }
                        }
                    }
                }
            }
        }
    }
    print("find checks:", checks, "wrong:", bad)
}

fn test_eq_cmp() {
    seed: u64 = 2
    ab := alloc[u8](64)
    bb := alloc[u8](64)
    bad := 0
    for n in 0..41 {
        for off in 0..8 {
            for rep in 0..40 {
                a := rand_str(&seed, ab, off, n, "\x00\x01\x7f\x80\xfe\xff")
                copy(bb[7 - off..], a)
                b := bb[7 - off..7 - off + n]
                // equal, then one byte changed anywhere, then a prefix
                if !(a == b) || a != b || cmp(a, b) != 0 || hash(a) != hash(b) {
                    bad += 1
                }
                if n > 0 {
                    seed = lcg(seed)
                    k := i64((seed >> 33) % u64(n))
                    bb[7 - off + k] = u8(i64(bb[7 - off + k]) + 1 + rep % 255)
                    if (a == b) != ref_eq(a, b) || cmp(a, b) != ref_cmp(a, b) || cmp(b, a) != ref_cmp(b, a) {
                        bad += 1
                    }
                    p := b[..k]
                    if cmp(a, p) != ref_cmp(a, p) || cmp(p, a) != ref_cmp(p, a) || (a[..k] == p) != true {
                        bad += 1
                    }
                    if starts_with(a, p) != true || ends_with(a, a[k..]) != true || starts_with(a, b) != ref_eq(a, b) {
                        bad += 1
                    }
                }
            }
        }
    }
    print("== cmp hash wrong:", bad)
    // the order of all byte values is unsigned
    print(cmp("\xff", "\x01"), cmp("abcdefgh\x80", "abcdefgh\x7f"), cmp("abcdefghij", "abcdefgh"), cmp("", "x"))
    // strings that differ in one byte hash differently (here: every position, every length)
    same := 0
    for n in 1..41 {
        s := alloc[u8](n)
        h0 := hash(s)
        for i in 0..n {
            s[i] = 1
            if hash(s) == h0 {
                same += 1
            }
            s[i] = 0
        }
    }
    print("hash collisions:", same)
}

fn test_bytes() {
    seed: u64 = 3
    buf := alloc[u8](64)
    bad := 0
    for n in 0..41 {
        for off in 0..8 {
            s := rand_str(&seed, buf, off, n, "\x00\x80\xffab ")
            for c in ([]u8{0, 0x80, 0xff, 'a', 'b', ' ', 'z'}) {
                if index_of(s, c) != ref_index(s, c) || contains(s, c) != (ref_index(s, c) >= 0) {
                    bad += 1
                }
                parts := split(s, c)
                n1 := 1
                for x in s {
                    if x == c {
                        n1 += 1
                    }
                }
                if len(parts) != n1 || join(parts, s[..0]) != replace(s, ([1]u8{c})[..], "") {
                    bad += 1
                }
                if find_any(s, ([1]u8{c})[..], 0) != ref_index(s, c) {
                    bad += 1
                }
            }
        }
    }
    flags := alloc[bool](40)
    flags[37] = true
    print("bytes wrong:", bad, index_of(flags, true), index_of(flags[..37], true), index_of(cast[[]i8](buf[..40]), i8(-1)) == ref_index(buf[..40], 0xff))
}

// pathological needles stay linear (the filter on the first and last byte passes everywhere)
fn test_linear() {
    s := repeat("a", 4_000_000)
    pat := fmt(repeat("a", 1000), "b", repeat("a", 1000))
    print(find(s, pat), count(s, pat), find(fmt(s, pat), pat), len(split(fmt(s, pat, s), pat)))
}

fn main() {
    test_find()
    test_eq_cmp()
    test_bytes()
    test_linear()
}
