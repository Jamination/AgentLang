// [library] string building: Vec[u8] push/extend in a loop, then Vec[str] + join
// (C: realloc-doubling byte buffer with memcpy; join = sum lengths + memcpy)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

const WORDS = [8]str{"alpha", "be", "gamma", "delta-epsilon", "z", "theta", "iota kappa", "lambda"}

fn checksum(s: []u8) -> u64 {
    h: u64 = 0
    for c in s { h = h * 31 + u64(c) }
    h
}

fn main() {
    seed: u64 = 5
    total := 0
    h: u64 = 0
    for r in 0..6 {
        b := vec[u8]()
        for i in 0..3000000 {
            seed = lcg(seed)
            b.extend(WORDS[i64(seed >> 61)])
            b.push(' ')
            // a small number written digit by digit
            v := (seed >> 40) % 1000
            if v >= 100 { b.push(u8(48 + v / 100)) }
            if v >= 10 { b.push(u8(48 + v / 10 % 10)) }
            b.push(u8(48 + v % 10))
            b.push(';')
        }
        total += b.len
        h = h ^ checksum(b.items())
        parts := vec[str]()
        for i in 0..1000000 {
            seed = lcg(seed)
            parts.push(WORDS[i64(seed >> 61)])
        }
        j := join(parts.items(), ", ")
        total += len(j)
        h = h ^ checksum(j)
    }
    print(total, h)
}
