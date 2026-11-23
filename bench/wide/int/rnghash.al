// PRNGs and hash mixers: PCG32, xorshift64*, splitmix64, murmur3 fmix64, FNV-1a over bytes
fn pcg32(state: *u64) -> u32 {
    old := *state
    *state = old * 6364136223846793005 + 1442695040888963407
    xorshifted := u32(((old >> 18) ^ old) >> 27)
    rot := u32(old >> 59)
    (xorshifted >> rot) | (xorshifted << ((0 - rot) & 31))
}

fn xorshift64s(s: *u64) -> u64 {
    x := *s
    x ^= x >> 12
    x ^= x << 25
    x ^= x >> 27
    *s = x
    x * 0x2545F4914F6CDD1D
}

fn splitmix64(s: *u64) -> u64 {
    *s += 0x9E3779B97F4A7C15
    z := *s
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) * 0x94D049BB133111EB
    z ^ (z >> 31)
}

fn fmix64(k0: u64) -> u64 {
    k := k0
    k ^= k >> 33
    k *= 0xff51afd7ed558ccd
    k ^= k >> 33
    k *= 0xc4ceb9fe1a85ec53
    k ^ (k >> 33)
}

fn fnv1a_u64(h0: u64, v: u64) -> u64 {
    h := h0
    for i in 0..8 {
        h ^= (v >> u64(8 * i)) & 0xFF
        h *= 0x100000001B3
    }
    h
}

fn main() {
    ps: u64 = 42
    xs: u64 = 88172645463325252
    ss: u64 = 7
    h: u64 = 0xcbf29ce484222325
    acc: u64 = 0
    acc32: u32 = 0
    for i in 0..45000000 {
        a := pcg32(&ps)
        b := xorshift64s(&xs)
        c := splitmix64(&ss)
        acc32 += a
        acc += fmix64(b ^ u64(a)) + c
        h = fnv1a_u64(h, c ^ b)
    }
    put(acc, " ", acc32, " ", h, "\n")
}
