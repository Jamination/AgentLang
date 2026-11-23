// [library] count occurrences of words with the library find(s, sub, from) (C: strstr on a
// NUL-terminated buffer)
inline fn lcg(s: u64) -> u64 { s * 6364136223846793005 + 1442695040888963407 }

fn main() {
    n := 8 << 20
    s := alloc[u8](n)
    seed: u64 = 3
    for i in 0..n {
        seed = lcg(seed)
        r := seed >> 58
        s[i] = if r < 10 { ' ' } else { u8(97 + (seed >> 33) % 20) }
    }
    total := 0
    for q in 0..120 {
        seed = lcg(seed)
        m := 4 + q % 6
        at := i64((seed >> 33) % u64(n - m))
        p := clone(s[at..at + m])
        c := 0
        i := find(s, p, 0)
        while i >= 0 {
            c += 1
            i = find(s, p, i + 1)
        }
        total = total * 31 + c
    }
    print(total)
}
