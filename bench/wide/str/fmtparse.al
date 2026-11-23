// [library] the language's own formatting and parsing: fmt / parse_i64 / fmtf / parse_f64
// (C: snprintf %lld / strtoll / snprintf %.3f / strtod)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn main() {
    seed: u64 = 77
    isum := 0
    lens := 0
    fsum: f64 = 0.0
    for i in 0..2000000 {
        mk := mark()
        seed = lcg(seed)
        x := i64(seed) >> i64((seed >> 20) % 63)
        s := fmt(x)
        lens += len(s)
        v, ok := parse_i64(s)
        if ok { isum += v ^ i }
        // a float with 3 exact decimals: k / 8 (k up to ~2^30), printed with 3 digits
        f := f64(i64(seed >> 34) - (1 << 29)) / 8.0
        t := fmtf(f, 3)
        lens += len(t)
        g, ok2 := parse_f64(t)
        if ok2 { fsum += g }
        release(mk)
    }
    print(lens, isum, i64(fsum * 8.0))
}
